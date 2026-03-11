// src-tauri/src/lib.rs
// Module declarations and Tauri app builder.

mod commands;
mod sidecar;
mod tray;

use sidecar::SidecarState;
use std::sync::Mutex;
use tauri::Manager;
#[allow(unused_imports)]
use tauri::Emitter;

/// Registers all plugins, IPC commands, and lifecycle hooks, then runs the app.
pub fn run() {
    env_logger::init();

    tauri::Builder::default()
        // ── Plugins ──────────────────────────────────────────────────────
        .plugin(tauri_plugin_shell::init())
        // .plugin(tauri_plugin_updater::Builder::new().build()) // TODO: enable when signing key is configured
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_process::init())
        .plugin(tauri_plugin_os::init())
        .plugin(tauri_plugin_fs::init())
        // ── IPC Commands ─────────────────────────────────────────────────
        .invoke_handler(tauri::generate_handler![
            commands::get_backend_url,
            commands::check_backend_health,
            commands::restart_backend,
            commands::detect_hardware,
            commands::get_platform,
            commands::open_terminal,
            commands::get_app_version,
        ])
        // ── Managed State ────────────────────────────────────────────────
        .manage(SidecarState(Mutex::new(None)))
        // ── App Setup ────────────────────────────────────────────────────
        .setup(|app| {
            let handle = app.handle().clone();

            // Build system tray
            tray::setup_tray(&handle)?;

            // Spawn sidecar in background — non-blocking, app opens immediately
            let sidecar_handle = handle.clone();
            tauri::async_runtime::spawn(async move {
                match sidecar::start_sidecar(&sidecar_handle).await {
                    Ok(_) => log::info!("Sidecar lifecycle complete"),
                    Err(e) => log::warn!("Sidecar: {}", e),
                }
            });

            Ok(())
        })
        // ── Window Events ────────────────────────────────────────────────
        .on_window_event(|window, event| {
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                // Kill the sidecar before hiding/quitting
                if let Some(state) = window.try_state::<SidecarState>() {
                    if let Ok(mut guard) = state.0.lock() {
                        if let Some(child) = guard.take() {
                            let _ = child.kill();
                            log::info!("Sidecar killed on window close");
                        }
                    }
                }
                // Hide to tray instead of quitting
                api.prevent_close();
                window.hide().unwrap();
            }
        })
        .run(tauri::generate_context!())
        .expect("error running OSA application");
}
