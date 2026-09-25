//! Compiles the small C boundary over llama.cpp's chat library. The sources and
//! the `llama-common` library come from the locked `llama-cpp-sys-2` package;
//! Fritz vendors no llama.cpp code.
use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-changed=src/local/chat_bridge.cpp");
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap()).join("Cargo.toml");
    let cargo = env::var("CARGO").unwrap_or_else(|_| "cargo".into());
    // Filter to this build's platform: offline metadata must not need packages
    // (Android, Windows, ...) that this build never downloads.
    let target = env::var("TARGET").unwrap();
    let output = Command::new(cargo)
        .args(["metadata", "--format-version", "1", "--locked", "--offline"])
        .args(["--filter-platform", &target])
        .arg("--manifest-path")
        .arg(&manifest)
        .output()
        .expect("run cargo metadata");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let metadata: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("parse cargo metadata");
    let sys = metadata["packages"]
        .as_array()
        .and_then(|packages| {
            packages
                .iter()
                .find(|package| package["name"] == "llama-cpp-sys-2")
        })
        .and_then(|package| package["manifest_path"].as_str())
        .map(|path| PathBuf::from(path).parent().unwrap().join("llama.cpp"))
        .expect("locked llama-cpp-sys-2 package");
    cc::Build::new()
        .cpp(true)
        .std("c++17")
        .file("src/local/chat_bridge.cpp")
        .include(&sys)
        .include(sys.join("common"))
        .include(sys.join("include"))
        .include(sys.join("ggml/include"))
        .include(sys.join("vendor"))
        .warnings(false)
        .compile("fritz_chat_bridge");
}
