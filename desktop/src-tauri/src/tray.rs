// src-tauri/src/tray.rs
// System tray: menu items, left-click toggle, status indicator.

use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, PredefinedMenuItem},
    tray::{TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};

pub fn setup_tray(app: &AppHandle) -> tauri::Result<()> {
    let open = MenuItemBuilder::with_id("open", "Open Dashboard").build(app)?;
    let open_terminal =
        MenuItemBuilder::with_id("open_terminal", "Open Terminal").build(app)?;
    let separator = PredefinedMenuItem::separator(app)?;
    let status = MenuItemBuilder::with_id("status", "Status: Starting...")
        .enabled(false)
        .build(app)?;
    let quit = MenuItemBuilder::with_id("quit", "Quit OSA").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&open)
        .item(&open_terminal)
        .item(&separator)
        .item(&status)
        .item(&quit)
        .build()?;

    let _tray = TrayIconBuilder::new()
        .menu(&menu)
        .icon(app.default_window_icon().cloned().unwrap())
        .icon_as_template(true) // macOS: adapts to dark/light menu bar
        .show_menu_on_left_click(false)
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => {
                if let Some(window) = app.get_webview_window("main") {
                    window.show().ok();
                    window.set_focus().ok();
                }
            }
            "open_terminal" => {
                // Launch the TUI binary in a new terminal window
                tauri::async_runtime::spawn({
                    let app = app.clone();
                    async move {
                        if let Err(e) = crate::commands::launch_terminal_inner(&app) {
                            log::error!("Failed to open terminal: {}", e);
                        }
                    }
                });
            }
            "quit" => {
                log::info!("Quit requested from tray");
                app.exit(0);
            }
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                // Left click: toggle main window visibility
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    if window.is_visible().unwrap_or(false) {
                        window.hide().ok();
                    } else {
                        window.show().ok();
                        window.set_focus().ok();
                    }
                }
            }
        })
        .build(app)?;

    Ok(())
}
