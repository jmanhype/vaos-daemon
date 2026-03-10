// src-tauri/src/commands.rs
// Tauri IPC commands exposed to the SvelteKit frontend.

use crate::sidecar::{BACKEND_PORT, HEALTH_URL, SIDECAR_RUNNING};
use serde::Serialize;
use std::sync::atomic::Ordering;

// ── Backend Commands ─────────────────────────────────────────────────────────

#[tauri::command]
pub fn get_backend_url() -> String {
    format!("http://127.0.0.1:{}", BACKEND_PORT)
}

#[tauri::command]
pub async fn check_backend_health() -> Result<bool, String> {
    let client = reqwest::Client::new();
    let healthy = client
        .get(HEALTH_URL)
        .timeout(std::time::Duration::from_secs(2))
        .send()
        .await
        .map(|r| r.status().is_success())
        .unwrap_or(false);

    SIDECAR_RUNNING.store(healthy, Ordering::Relaxed);
    Ok(healthy)
}

#[tauri::command]
pub async fn restart_backend(app: tauri::AppHandle) -> Result<(), String> {
    crate::sidecar::start_sidecar(&app).await
}

// ── Hardware / Platform Commands ─────────────────────────────────────────────

#[derive(Serialize)]
pub struct HardwareInfo {
    pub cpu_brand: String,
    pub cpu_cores: usize,
    pub ram_total_bytes: u64,
    pub gpu: String,
}

#[tauri::command]
pub fn detect_hardware() -> Result<HardwareInfo, String> {
    // CPU info via std — core count is reliably available.
    // Brand string requires reading /proc/cpuinfo or sysctl on macOS.
    let cpu_cores = std::thread::available_parallelism()
        .map(|p| p.get())
        .unwrap_or(1);

    let cpu_brand = get_cpu_brand().unwrap_or_else(|| "Unknown CPU".to_string());
    let ram_total_bytes = get_total_memory().unwrap_or(0);
    let gpu = get_gpu_info().unwrap_or_else(|| "Unknown GPU".to_string());

    Ok(HardwareInfo {
        cpu_brand,
        cpu_cores,
        ram_total_bytes,
        gpu,
    })
}

#[derive(Serialize)]
pub struct PlatformInfo {
    pub os: String,
    pub arch: String,
}

#[tauri::command]
pub fn get_platform() -> PlatformInfo {
    PlatformInfo {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
    }
}

#[tauri::command]
pub fn open_terminal(app: tauri::AppHandle) -> Result<(), String> {
    launch_terminal_inner(&app)
}

/// Shared implementation used by both the IPC command and the tray menu item.
pub fn launch_terminal_inner(app: &tauri::AppHandle) -> Result<(), String> {
    use tauri_plugin_shell::ShellExt;

    let shell = app.shell();

    // Attempt to launch the Rust TUI binary (osa-tui) in a new terminal window.
    // macOS: open -a Terminal with the binary path.
    // Linux: x-terminal-emulator or fallback to xterm.
    // Windows: cmd /c start.

    let os = std::env::consts::OS;
    match os {
        "macos" => {
            shell
                .command("open")
                .args(["-a", "Terminal", "--args", "osa-tui"])
                .spawn()
                .map_err(|e| format!("Failed to open Terminal.app: {}", e))?;
        }
        "linux" => {
            // Try common terminal emulators in order of preference
            let result = shell
                .command("x-terminal-emulator")
                .args(["-e", "osa-tui"])
                .spawn();
            if result.is_err() {
                shell
                    .command("xterm")
                    .args(["-e", "osa-tui"])
                    .spawn()
                    .map_err(|e| format!("Failed to open terminal: {}", e))?;
            }
        }
        "windows" => {
            shell
                .command("cmd")
                .args(["/c", "start", "osa-tui"])
                .spawn()
                .map_err(|e| format!("Failed to open cmd: {}", e))?;
        }
        _ => {
            return Err(format!("Unsupported platform: {}", os));
        }
    }

    Ok(())
}

#[tauri::command]
pub fn get_app_version() -> String {
    env!("CARGO_PKG_VERSION").to_string()
}

// ── Platform-specific helpers ────────────────────────────────────────────────

#[cfg(target_os = "macos")]
fn get_cpu_brand() -> Option<String> {
    use std::process::Command;
    let output = Command::new("sysctl")
        .args(["-n", "machdep.cpu.brand_string"])
        .output()
        .ok()?;
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

#[cfg(target_os = "linux")]
fn get_cpu_brand() -> Option<String> {
    use std::fs;
    let cpuinfo = fs::read_to_string("/proc/cpuinfo").ok()?;
    for line in cpuinfo.lines() {
        if line.starts_with("model name") {
            return line.split(':').nth(1).map(|s| s.trim().to_string());
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn get_cpu_brand() -> Option<String> {
    use std::process::Command;
    let output = Command::new("wmic")
        .args(["cpu", "get", "Name", "/value"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if let Some(name) = line.strip_prefix("Name=") {
            return Some(name.trim().to_string());
        }
    }
    None
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn get_cpu_brand() -> Option<String> {
    None
}

#[cfg(target_os = "macos")]
fn get_total_memory() -> Option<u64> {
    use std::process::Command;
    let output = Command::new("sysctl")
        .args(["-n", "hw.memsize"])
        .output()
        .ok()?;
    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse::<u64>()
        .ok()
}

#[cfg(target_os = "linux")]
fn get_total_memory() -> Option<u64> {
    use std::fs;
    let meminfo = fs::read_to_string("/proc/meminfo").ok()?;
    for line in meminfo.lines() {
        if line.starts_with("MemTotal:") {
            let kb: u64 = line
                .split_whitespace()
                .nth(1)?
                .parse()
                .ok()?;
            return Some(kb * 1024); // kB to bytes
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn get_total_memory() -> Option<u64> {
    use std::process::Command;
    let output = Command::new("wmic")
        .args(["os", "get", "TotalVisibleMemorySize", "/value"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if let Some(val) = line.strip_prefix("TotalVisibleMemorySize=") {
            return val.trim().parse::<u64>().ok().map(|kb| kb * 1024);
        }
    }
    None
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn get_total_memory() -> Option<u64> {
    None
}

#[cfg(target_os = "macos")]
fn get_gpu_info() -> Option<String> {
    use std::process::Command;
    let output = Command::new("system_profiler")
        .args(["SPDisplaysDataType", "-detailLevel", "mini"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("Chipset Model:") || trimmed.starts_with("Chip:") {
            return trimmed.split(':').nth(1).map(|s| s.trim().to_string());
        }
    }
    None
}

#[cfg(target_os = "linux")]
fn get_gpu_info() -> Option<String> {
    use std::process::Command;
    let output = Command::new("lspci")
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if line.contains("VGA") || line.contains("3D") {
            return Some(line.to_string());
        }
    }
    None
}

#[cfg(target_os = "windows")]
fn get_gpu_info() -> Option<String> {
    use std::process::Command;
    let output = Command::new("wmic")
        .args(["path", "win32_videocontroller", "get", "Name", "/value"])
        .output()
        .ok()?;
    let text = String::from_utf8_lossy(&output.stdout);
    for line in text.lines() {
        if let Some(name) = line.strip_prefix("Name=") {
            return Some(name.trim().to_string());
        }
    }
    None
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
fn get_gpu_info() -> Option<String> {
    None
}
