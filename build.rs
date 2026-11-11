use std::{
    env,
    hash::{DefaultHasher, Hash, Hasher},
    path::PathBuf,
    process::Command,
};

fn run(command: &mut Command) {
    assert!(
        command
            .status()
            .expect("could not start native build tool")
            .success(),
        "llama.cpp native build failed"
    );
}

fn main() {
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    assert!(
        std::path::Path::new("vendor/llama.cpp/CMakeLists.txt").is_file(),
        "llama.cpp sources are missing. Run make setup to initialize the pinned submodule."
    );
    println!("cargo:rerun-if-changed=native");
    println!("cargo:rerun-if-changed=vendor/llama.cpp");
    // Cargo can reuse OUT_DIR across worktrees. CMake caches absolute source
    // and compiler paths, so its writable tree must belong to one checkout.
    let mut native_key = DefaultHasher::new();
    env::var_os("CARGO_MANIFEST_DIR")
        .unwrap()
        .hash(&mut native_key);
    for name in [
        "CC",
        "CXX",
        "CFLAGS",
        "CXXFLAGS",
        "CPPFLAGS",
        "LDFLAGS",
        "DEVELOPER_DIR",
        "SDKROOT",
        "CMAKE_GENERATOR",
    ] {
        println!("cargo:rerun-if-env-changed={name}");
        env::var_os(name).hash(&mut native_key);
    }
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap())
        .join(format!("llama-{:016x}", native_key.finish()));
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        _ => panic!("unsupported macOS architecture"),
    };
    let profile = if env::var("PROFILE").unwrap() == "release" {
        "Release"
    } else {
        "RelWithDebInfo"
    };
    run(Command::new("cmake")
        .args(["-S", "native", "-B"])
        .arg(&out)
        .arg(format!("-DCMAKE_BUILD_TYPE={profile}"))
        .arg(format!("-DCMAKE_OSX_ARCHITECTURES={arch}"))
        .arg("-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0"));
    run(Command::new("cmake")
        .arg("--build")
        .arg(&out)
        .args(["--target", "fritz_llama", "--parallel"])
        .arg(env::var("NUM_JOBS").unwrap_or("4".into())));
    for dir in [
        "",
        "llama/common",
        "llama/src",
        "llama/ggml/src",
        "llama/ggml/src/ggml-cpu",
        "llama/ggml/src/ggml-metal",
    ] {
        println!("cargo:rustc-link-search=native={}", out.join(dir).display());
    }
    for lib in [
        "fritz_llama",
        "llama-common",
        "llama-common-base",
        "llama",
        "ggml",
        "ggml-cpu",
        "ggml-metal",
        "ggml-base",
    ] {
        println!("cargo:rustc-link-lib=static={lib}");
    }
    println!("cargo:rustc-link-lib=c++");
    for framework in ["Foundation", "Metal", "MetalKit", "Accelerate"] {
        println!("cargo:rustc-link-lib=framework={framework}");
    }
}
