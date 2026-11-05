//! `examples/openrouter-camunda.toml` (#169): a regional OpenRouter workspace
//! with a curated model list and per-model hosts. The offline tests run in CI;
//! the live ones need a workspace key and run with
//! `OPENROUTER_API_KEY=… cargo test --test openrouter_example -- --ignored`.

use std::io::Write;
use std::process::{Command, Output, Stdio};

const EXAMPLE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/examples/openrouter-camunda.toml");

fn run(args: &[&str], stdin: Option<&str>) -> Output {
    let home = tempfile::tempdir().unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_nano-coder"))
        .args(["--config", EXAMPLE])
        .args(args)
        .current_dir(home.path())
        .env("NO_COLOR", "1")
        .env("NANO_CODER_NO_UPDATE_CHECK", "1")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn nano-coder");
    {
        let mut pipe = child.stdin.take().unwrap();
        if let Some(text) = stdin {
            pipe.write_all(text.as_bytes()).unwrap();
        }
    }
    child.wait_with_output().expect("wait for nano-coder")
}

#[test]
fn the_example_lists_its_curated_models_without_a_request() {
    // No key: a configured list never touches the endpoint.
    let out = run(&["--list-models", "openrouter-camunda"], None);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let listed = String::from_utf8_lossy(&out.stdout);
    let models: Vec<&str> = listed.lines().collect();
    assert!(models.len() >= 10, "{listed}");
    assert!(models.contains(&"openrouter-camunda/moonshotai/kimi-k3"), "{listed}");
    assert!(models.contains(&"openrouter-camunda/amazon/nova-lite-v1"), "{listed}");
    assert!(models.iter().all(|m| m.starts_with("openrouter-camunda/")), "{listed}");
}

#[test]
fn the_example_refuses_the_global_openrouter_preset() {
    let out = run(&["--list-models", "openrouter"], None);
    assert!(!out.status.success());
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("\"openrouter\" is disabled"), "{err}");
}

fn live(model: &str) {
    if std::env::var("OPENROUTER_API_KEY").map_or(true, |k| k.is_empty()) {
        panic!("set OPENROUTER_API_KEY (a regional workspace key) to run the live tests");
    }
    let out = run(&["--model", model], Some("Reply with just the word: ok\n"));
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!stderr.contains("Error"), "{model}: {stderr}");
    assert!(stdout.to_lowercase().contains("ok"), "{model}: {stdout}");
}

#[test]
#[ignore = "live: needs OPENROUTER_API_KEY for a regional workspace"]
fn a_us_model_answers_on_the_us_host() {
    live("openrouter-camunda/moonshotai/kimi-k3");
}

#[test]
#[ignore = "live: needs OPENROUTER_API_KEY for a regional workspace"]
fn an_eu_model_answers_on_its_own_eu_host() {
    live("openrouter-camunda/openai/gpt-oss-120b");
}
