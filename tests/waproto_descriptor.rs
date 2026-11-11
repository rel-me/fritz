//! Cargo must not treat the generated descriptor as a newer source input.
#[path = "../vendor/waproto/build/descriptor.rs"]
mod descriptor;

use std::{
    fs,
    path::Path,
    time::{Duration, SystemTime},
};

fn modified(path: &Path) -> SystemTime {
    fs::metadata(path).unwrap().modified().unwrap()
}

#[test]
fn generated_descriptor_tracks_its_source_without_hiding_changes() {
    let directory = tempfile::tempdir().unwrap();
    let source = directory.path().join("source.desc");
    let output = directory.path().join("generated.desc");
    fs::write(&source, b"source").unwrap();
    let now = SystemTime::now();
    let past = now - Duration::from_secs(60);
    let future = now + Duration::from_secs(3600);
    let set_time = |path: &Path, time| {
        fs::File::options()
            .write(true)
            .open(path)
            .unwrap()
            .set_modified(time)
            .unwrap();
    };
    set_time(&source, past);
    descriptor::write(&output, b"first", &source).unwrap();
    assert_eq!(fs::read(&output).unwrap(), b"first");
    assert_eq!(modified(&output), modified(&source));

    // Repair already-cached output without rewriting identical contents.
    set_time(&output, future);
    descriptor::write(&output, b"first", &source).unwrap();
    assert_eq!(modified(&output), modified(&source));
    let stable = modified(&output);
    descriptor::write(&output, b"first", &source).unwrap();
    assert_eq!(modified(&output), stable);

    // Future source timestamps must remain visible to Cargo's freshness check.
    set_time(&source, future);
    descriptor::write(&output, b"first", &source).unwrap();
    assert_eq!(modified(&output), modified(&source));
    assert!(modified(&output) > now);

    // Encoded changes still replace the output when source timestamps match.
    descriptor::write(&output, b"second", &source).unwrap();
    assert_eq!(fs::read(&output).unwrap(), b"second");
    assert_eq!(modified(&output), modified(&source));
    set_time(&source, past);
    descriptor::write(&output, b"third", &source).unwrap();
    assert_eq!(fs::read(&output).unwrap(), b"third");
    assert_eq!(modified(&output), modified(&source));
}
