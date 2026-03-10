// src-tauri/src/sidecar.rs
// Elixir sidecar lifecycle: spawn, health-check, graceful shutdown.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

pub const BACKEND_PORT: u16 = 8089;
pub const HEALTH_URL: &str = "http://127.0.0.1:8089/health";

/// Global flag so tray/commands can query sidecar status.
pub static SIDECAR_RUNNING: AtomicBool = AtomicBool::new(false);

/// Managed state holding the live sidecar child process.
pub struct SidecarState(pub Mutex<Option<CommandChild>>);

/// Checks if something is already listening on port 8089.
async fn port_in_use() -> bool {
    reqwest::get(HEALTH_URL)
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false)
}

/// Exponential backoff health check.
async fn wait_for_healthy(timeout_secs: u64) -> Result<(), String> {
    let deadline = std::time::Instant::now() + Duration::from_secs(timeout_secs);
    let mut delay_ms: u64 = 100;
    let client = reqwest::Client::new();

    while std::time::Instant::now() < deadline {
        match client
            .get(HEALTH_URL)
            .timeout(Duration::from_secs(1))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => {
                SIDECAR_RUNNING.store(true, Ordering::Relaxed);
                return Ok(());
            }
            _ => {}
        }
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        delay_ms = (delay_ms * 2).min(2000);
    }

    Err(format!(
        "Backend did not become healthy within {}s",
        timeout_secs
    ))
}

/// Spawns the Elixir sidecar and waits for it to be healthy.
pub async fn start_sidecar(app: &AppHandle) -> Result<(), String> {
    // Dev mode: if backend already running, skip sidecar spawn
    if port_in_use().await {
        log::info!("Port 8089 already in use — connecting to existing backend");
        SIDECAR_RUNNING.store(true, Ordering::Relaxed);
        show_main_window(app);
        return Ok(());
    }

    log::info!("Spawning osagent sidecar...");

    let shell = app.shell();

    let env = vec![
        ("OSA_PORT", "8089"),
        ("OSA_LOG_LEVEL", "warn"),
        ("OSA_HEADLESS", "true"),
    ];

    let (rx, child) = shell
        .sidecar("osagent")
        .map_err(|e| format!("Failed to create sidecar command: {}", e))?
        .envs(env)
        .args(["serve", "--port", "8089"])
        .spawn()
        .map_err(|e| format!("Failed to spawn sidecar: {}", e))?;

    // Store child handle for graceful shutdown
    if let Some(state) = app.try_state::<SidecarState>() {
        if let Ok(mut guard) = state.0.lock() {
            *guard = Some(child);
        }
    }

    // Log stdout/stderr in background — must spawn before any awaits
    // since rx is not Send
    spawn_log_monitor(app.clone(), rx);

    // Wait for healthy response
    wait_for_healthy(30).await?;

    log::info!("Sidecar healthy at http://127.0.0.1:{}", BACKEND_PORT);
    app.emit("backend-ready", ()).ok();
    show_main_window(app);

    Ok(())
}

/// Spawns a background thread to monitor sidecar output.
/// Uses std::thread because the receiver is not Send.
fn spawn_log_monitor(
    app: AppHandle,
    mut rx: tokio::sync::mpsc::Receiver<tauri_plugin_shell::process::CommandEvent>,
) {
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        rt.block_on(async move {
            use tauri_plugin_shell::process::CommandEvent;
            while let Some(event) = rx.recv().await {
                match event {
                    CommandEvent::Stdout(line) => {
                        log::debug!("[osagent] {}", String::from_utf8_lossy(&line));
                    }
                    CommandEvent::Stderr(line) => {
                        log::warn!("[osagent stderr] {}", String::from_utf8_lossy(&line));
                    }
                    CommandEvent::Terminated(status) => {
                        log::error!("[osagent] terminated with status: {:?}", status);
                        SIDECAR_RUNNING.store(false, Ordering::Relaxed);
                        let _ = app.emit("backend-crashed", ());
                        break;
                    }
                    _ => {}
                }
            }
        });
    });
}

fn show_main_window(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        window.show().ok();
        window.set_focus().ok();
    }
}
