use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_nano-coder"))
}

fn expected() -> String {
    format!("nano-coder {}", env!("CARGO_PKG_VERSION"))
}

#[test]
fn long_flag_prints_version_and_exits_zero() {
    let out = bin().arg("--version").output().expect("run --version");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), expected());
}

#[test]
fn short_flag_prints_version_and_exits_zero() {
    let out = bin().arg("-V").output().expect("run -V");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), expected());
}

#[test]
fn preceding_value_option_does_not_swallow_version() {
    // A value-taking option must not consume `--version` as its value; the
    // early-exit flag wins and the process still prints the version.
    let out = bin()
        .args(["--model", "--version"])
        .output()
        .expect("run --model --version");
    assert!(out.status.success());
    assert_eq!(String::from_utf8_lossy(&out.stdout).trim(), expected());
}
