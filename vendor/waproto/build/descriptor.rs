use std::path::Path;

pub fn write(path: &Path, encoded: &[u8], source: &Path) -> std::io::Result<()> {
    if !std::fs::read(path).is_ok_and(|current| current == encoded) {
        std::fs::write(path, encoded)?;
    }
    // Cargo watches this generated descriptor as an input. Date it like its
    // real source so the next invocation does not invalidate the completed run.
    // Keep future source timestamps visible and repair existing cached outputs.
    let source_time = std::fs::metadata(source)?.modified()?;
    let file = std::fs::File::options().write(true).open(path)?;
    if file.metadata()?.modified()? != source_time {
        file.set_modified(source_time)?;
    }
    Ok(())
}
