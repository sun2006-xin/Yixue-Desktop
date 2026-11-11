use std::path::PathBuf;

use serde_json::{Value, json};
use yixue_ffi::{BRIDGE_SCHEMA_VERSION, BridgeEngine};

fn send(engine: &BridgeEngine, command: &Value) -> Result<Value, Box<dyn std::error::Error>> {
    let response: Value = serde_json::from_str(&engine.process_json(&command.to_string()))?;
    if response.get("ok") != Some(&Value::Bool(true)) {
        return Err(format!("bridge command failed: {response}").into());
    }
    Ok(response)
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut arguments = std::env::args_os().skip(1);
    let worker = PathBuf::from(arguments.next().ok_or("worker path is required")?);
    let model = PathBuf::from(arguments.next().ok_or("model path is required")?);
    let text = arguments
        .next()
        .and_then(|value| value.into_string().ok())
        .ok_or("UTF-8 source text is required")?;
    let engine = BridgeEngine::open_in_memory()?;

    send(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "configure_local_translation",
            "payload": {"worker_path": worker, "model_path": model}
        }),
    )?;
    let response = send(
        &engine,
        &json!({
            "schema_version": BRIDGE_SCHEMA_VERSION,
            "command": "translate",
            "payload": {
                "id": "bridge-smoke",
                "source_language": "english",
                "target_language": "chinese",
                "text": text
            }
        }),
    )?;
    println!("TRANSLATION={}", response["data"]["translation"]["text"]);
    Ok(())
}
