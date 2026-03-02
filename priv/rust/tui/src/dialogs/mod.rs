pub mod command_palette;
pub mod file_picker;
pub mod model_picker;
pub mod onboarding;
pub mod permissions;
pub mod picker;
pub mod plan_review;
pub mod quit_confirm;
pub mod reasoning;
pub mod sessions;

/// Actions produced by dialog event handling that bubble up to the app layer.
#[derive(Debug, Clone)]
pub enum DialogAction {
    /// Dialog was dismissed without a meaningful selection.
    Dismissed,
    /// User confirmed the quit dialog.
    QuitConfirmed,
    /// User selected and executed a command from the palette.
    PaletteExecute(String),
    /// User approved the plan.
    PlanApprove,
    /// User rejected the plan.
    PlanReject,
    /// User wants to edit the plan.
    PlanEdit,
    /// User granted the tool permission for this invocation.
    PermissionAllow,
    /// User granted the tool permission for the remainder of the session.
    PermissionAllowSession,
    /// User denied the tool permission.
    PermissionDeny,
    /// User selected an item from a generic picker.
    PickerSelect { index: usize, label: String },
    /// User cancelled a generic picker without selecting.
    PickerCancel,
}
