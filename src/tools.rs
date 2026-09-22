use anyhow::{Context, Result, bail};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    process::Stdio,
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncReadExt};

const FILE_LIMIT: usize = 512 * 1024;
pub const OUTPUT_LIMIT: usize = 32 * 1024;

pub fn bounded(text: &str, limit: usize) -> String {
    if text.len() <= limit {
        return text.to_owned();
    }
    let mut end = limit;
    while !text.is_char_boundary(end) {
        end -= 1;
    }
    format!("{}\n[output truncated]", &text[..end])
}

pub fn definitions() -> Vec<Value> {
    let string = json!({"type":"string"});
    let number = json!({"type":"integer","minimum":1});
    [
        ("list_files", "List one project directory, sorted by name. Use offset to page through large directories. Symlinks are labeled; .git is excluded.", json!({"path":string,"offset":{"type":"integer","minimum":0}}), json!(["path"])),
        ("read_file", "Read a UTF-8 project file with line numbers. start_line is one-based; max_lines defaults to 200 (maximum 1000). Read files before editing; output and file size are bounded.", json!({"path":string,"start_line":number,"max_lines":number}), json!(["path"])),
        ("create_file", "Create a new UTF-8 file without overwriting an existing file. The parent directory must exist; use run_command to create directories. Maximum 512 KiB.", json!({"path":string,"content":string}), json!(["path","content"])),
        ("edit_file", "Atomically replace exactly one occurrence of old_text in an existing UTF-8 file. Read first and include enough context for a unique match. An empty or ambiguous old_text fails without writing.", json!({"path":string,"old_text":string,"new_text":string}), json!(["path","old_text","new_text"])),
        ("run_command", "Run a noninteractive /bin/bash command in the project, with optional relative working directory. Commands run with the user's permissions, not in an OS sandbox. Use only for the user's task; do not access unrelated files or secrets. Timeout defaults to 30 seconds, maximum 120. Output is capped; background processes are terminated when the command finishes. No interactive stdin.", json!({"command":string,"working_directory":string,"timeout_seconds":{"type":"integer","minimum":1,"maximum":120}}), json!(["command"])),
    ].into_iter().map(|(name, description, properties, required)| json!({"name":name,"description":description,"parameters":{"type":"object","properties":properties,"required":required,"additionalProperties":false}})).collect()
}

pub struct Workspace {
    root: PathBuf,
}
impl Workspace {
    pub fn new(path: &str) -> Result<Self> {
        if !Path::new(path).is_absolute() {
            bail!("Project path must be absolute.");
        }
        let root = fs::canonicalize(path).context("The project folder is unavailable.")?;
        if !root.is_dir() {
            bail!("Choose an existing project directory.");
        }
        Ok(Self { root })
    }
    pub fn root(&self) -> &Path {
        &self.root
    }

    fn resolve(&self, path: &str, create: bool) -> Result<PathBuf> {
        let relative = Path::new(path);
        if relative.is_absolute()
            || relative
                .components()
                .any(|c| matches!(c, Component::ParentDir) || c.as_os_str() == ".git")
        {
            bail!("Use a relative project path without '..' or '.git'.");
        }
        let joined = self.root.join(relative);
        let resolved = if create {
            let parent = joined
                .parent()
                .context("Missing parent directory.")?
                .canonicalize()?;
            parent.join(joined.file_name().context("Missing filename.")?)
        } else {
            joined.canonicalize()?
        };
        if !resolved.starts_with(&self.root)
            || resolved
                .strip_prefix(&self.root)?
                .components()
                .any(|c| c.as_os_str() == ".git")
        {
            bail!("The path points outside the project or into .git.");
        }
        Ok(resolved)
    }
    fn read(&self, path: &Path) -> Result<String> {
        use std::os::unix::fs::OpenOptionsExt;
        let file = fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NONBLOCK | libc::O_NOFOLLOW)
            .open(path)?;
        if !file.metadata()?.is_file() {
            bail!("Choose a regular file.");
        }
        let mut bytes = Vec::new();
        file.take((FILE_LIMIT + 1) as u64).read_to_end(&mut bytes)?;
        if bytes.len() > FILE_LIMIT {
            bail!("File exceeds the 512 KiB limit; use a targeted command.");
        }
        String::from_utf8(bytes).context("This file is not UTF-8 text.")
    }
    pub fn instructions(&self) -> Result<Option<String>> {
        match self.resolve("AGENTS.md", false) {
            Ok(path) => Ok(Some(bounded(&self.read(&path)?, OUTPUT_LIMIT))),
            Err(_) if !self.root.join("AGENTS.md").exists() => Ok(None),
            Err(e) => Err(e),
        }
    }
    pub async fn execute(&self, name: &str, args: Value) -> Result<Value> {
        match name {
            "list_files" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Args {
                    path: String,
                    #[serde(default)]
                    offset: usize,
                }
                let a: Args = serde_json::from_value(args)?;
                let mut entries = vec![];
                for entry in fs::read_dir(self.resolve(&a.path, false)?)? {
                    let entry = entry?;
                    let name = entry.file_name().to_string_lossy().into_owned();
                    if name == ".git" {
                        continue;
                    }
                    let kind = entry.file_type()?;
                    entries.push(json!({"name":name,"kind":if kind.is_symlink() {"symlink"} else if kind.is_dir() {"directory"} else {"file"}}));
                    if entries.len() > 20_000 {
                        bail!("Directory exceeds 20,000 entries; use a targeted command.");
                    }
                }
                entries.sort_by(|a, b| a["name"].as_str().cmp(&b["name"].as_str()));
                let total = entries.len();
                let end = a.offset.saturating_add(200).min(total);
                let page = entries.get(a.offset..end).unwrap_or(&[]);
                Ok(
                    json!({"entries":page,"total":total,"next_offset":if end < total {Some(end)} else {None}}),
                )
            }
            "read_file" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Args {
                    path: String,
                    start_line: Option<usize>,
                    max_lines: Option<usize>,
                }
                let a: Args = serde_json::from_value(args)?;
                let start = a.start_line.unwrap_or(1);
                let count = a.max_lines.unwrap_or(200);
                if start == 0 || !(1..=1000).contains(&count) {
                    bail!("Use start_line >= 1 and max_lines between 1 and 1000.");
                }
                let content = self.read(&self.resolve(&a.path, false)?)?;
                let text = content
                    .lines()
                    .enumerate()
                    .skip(start - 1)
                    .take(count)
                    .map(|(i, l)| format!("{}: {l}", i + 1))
                    .collect::<Vec<_>>()
                    .join("\n");
                Ok(
                    json!({"text":bounded(&text, OUTPUT_LIMIT),"total_lines":content.lines().count(),"truncated":text.len()>OUTPUT_LIMIT}),
                )
            }
            "create_file" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Args {
                    path: String,
                    content: String,
                }
                let a: Args = serde_json::from_value(args)?;
                if a.content.len() > FILE_LIMIT {
                    bail!("File exceeds the 512 KiB limit.");
                }
                let path = self.resolve(&a.path, true)?;
                let mut file = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
                file.write_all(a.content.as_bytes())?;
                file.as_file().sync_all()?;
                file.persist_noclobber(path)
                    .context("Could not create file; an existing file will not be overwritten.")?;
                Ok(json!({"created":a.path,"bytes":a.content.len()}))
            }
            "edit_file" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Args {
                    path: String,
                    old_text: String,
                    new_text: String,
                }
                let a: Args = serde_json::from_value(args)?;
                if a.old_text.is_empty() {
                    bail!("old_text must not be empty.");
                }
                let path = self.resolve(&a.path, false)?;
                let before = self.read(&path)?;
                if before.matches(&a.old_text).count() != 1 {
                    bail!(
                        "old_text must match exactly once. Read the file again and include more context."
                    );
                }
                let after = before.replacen(&a.old_text, &a.new_text, 1);
                if after.len() > FILE_LIMIT {
                    bail!("Edited file exceeds the 512 KiB limit.");
                }
                let mut file = tempfile::NamedTempFile::new_in(path.parent().unwrap())?;
                file.as_file()
                    .set_permissions(fs::metadata(&path)?.permissions())?;
                file.write_all(after.as_bytes())?;
                file.as_file().sync_all()?;
                if self.read(&path)? != before {
                    bail!("File changed while editing. Read it again.");
                }
                file.persist(&path)?;
                Ok(
                    json!({"edited":a.path,"removed":bounded(&a.old_text,4096),"added":bounded(&a.new_text,4096)}),
                )
            }
            "run_command" => {
                #[derive(Deserialize)]
                #[serde(deny_unknown_fields)]
                struct Args {
                    command: String,
                    working_directory: Option<String>,
                    timeout_seconds: Option<u64>,
                }
                let a: Args = serde_json::from_value(args)?;
                let seconds = a.timeout_seconds.unwrap_or(30);
                if !(1..=120).contains(&seconds)
                    || a.command.trim().is_empty()
                    || a.command.len() > 32_768
                {
                    bail!("Use a nonempty command (up to 32 KiB) and a timeout of 1–120 seconds.");
                }
                let cwd = self.resolve(a.working_directory.as_deref().unwrap_or("."), false)?;
                run_command(&cwd, &a.command, seconds).await
            }
            _ => bail!("Unknown tool: {name}"),
        }
    }
}

// Each command owns a new process group. Dropping the future (Stop, EOF, deadline)
// kills that group, including ordinary child processes holding output pipes open.
struct ProcessGroup(u32);
impl Drop for ProcessGroup {
    fn drop(&mut self) {
        // SAFETY: this is the positive PID returned by our own spawn with process_group(0).
        unsafe {
            libc::kill(-(self.0 as i32), libc::SIGKILL);
        }
    }
}
async fn capture(mut stream: impl AsyncRead + Unpin) -> Result<(String, bool)> {
    let mut kept = Vec::new();
    let mut chunk = [0u8; 8192];
    let mut truncated = false;
    loop {
        let n = stream.read(&mut chunk).await?;
        if n == 0 {
            break;
        }
        let remaining = OUTPUT_LIMIT - kept.len();
        kept.extend_from_slice(&chunk[..n.min(remaining)]);
        truncated |= n > remaining;
    }
    Ok((String::from_utf8_lossy(&kept).into_owned(), truncated))
}
async fn run_command(cwd: &Path, command: &str, seconds: u64) -> Result<Value> {
    let mut process = tokio::process::Command::new("/bin/bash");
    process
        .arg("--noprofile")
        .arg("--norc")
        .arg("-c")
        .arg(command)
        .current_dir(cwd)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env_clear()
        .env(
            "PATH",
            "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        )
        .env("PWD", cwd)
        .process_group(0)
        .kill_on_drop(true);
    // Do not inherit API keys or arbitrary application environment into commands.
    for name in [
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "LANG",
        "DEVELOPER_DIR",
        "SDKROOT",
    ] {
        if let Some(value) = std::env::var_os(name) {
            process.env(name, value);
        }
    }
    let mut child = process.spawn().context("Could not start the command.")?;
    let group = ProcessGroup(child.id().context("Missing command process ID.")?);
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let wait = async {
        let result = tokio::time::timeout(Duration::from_secs(seconds), child.wait()).await;
        drop(group); // Also stop background descendants on a normal exit or timeout.
        match result {
            Ok(status) => Ok((Some(status?), false)),
            Err(_) => {
                let _ = child.wait().await;
                Ok::<_, anyhow::Error>((None, true))
            }
        }
    };
    let ((status, timed_out), (stdout, out_cut), (stderr, err_cut)) =
        tokio::try_join!(wait, capture(stdout), capture(stderr))?;
    Ok(
        json!({"exit_code":status.and_then(|s| s.code()),"timed_out":timed_out,"stdout":stdout,"stderr":stderr,"truncated":out_cut||err_cut}),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn scoped_edits_and_conflicts() {
        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::os::unix::fs::symlink(outside.path(), root.path().join("escape")).unwrap();
        let w = Workspace::new(root.path().to_str().unwrap()).unwrap();
        for path in ["../no", "/tmp/no", "escape/no", ".git/config"] {
            assert!(
                w.execute("create_file", json!({"path":path,"content":"no"}))
                    .await
                    .is_err()
            );
        }
        w.execute(
            "create_file",
            json!({"path":"a.txt","content":"one\none\n"}),
        )
        .await
        .unwrap();
        assert!(
            w.execute("create_file", json!({"path":"a.txt","content":"overwrite"}))
                .await
                .is_err()
        );
        assert!(
            w.execute(
                "edit_file",
                json!({"path":"a.txt","old_text":"one","new_text":"two"})
            )
            .await
            .is_err()
        );
        w.execute(
            "edit_file",
            json!({"path":"a.txt","old_text":"one\none","new_text":"two"}),
        )
        .await
        .unwrap();
        assert_eq!(
            fs::read_to_string(root.path().join("a.txt")).unwrap(),
            "two\n"
        );
    }
    #[tokio::test]
    async fn command_status_output_and_timeout() {
        let root = tempfile::tempdir().unwrap();
        let value = run_command(root.path(), "printf hello; printf problem >&2; exit 7", 5)
            .await
            .unwrap();
        assert_eq!(value["exit_code"], 7);
        assert_eq!(value["stdout"], "hello");
        assert_eq!(value["stderr"], "problem");
        let value = run_command(root.path(), "sleep 30 & wait", 1)
            .await
            .unwrap();
        assert_eq!(value["timed_out"], true);
        let value = run_command(root.path(), "yes x | head -c 100000", 5)
            .await
            .unwrap();
        assert_eq!(value["truncated"], true);
        assert!(value["stdout"].as_str().unwrap().len() <= OUTPUT_LIMIT);
    }
}
