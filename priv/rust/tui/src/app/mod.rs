pub mod commands;
pub mod event_loop;
pub mod focus;
pub mod keys;
pub mod layout;
pub mod state;
pub mod update;

use anyhow::Result;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::info;

use crate::client::http::ApiClient;
use crate::components::activity::Activity;
use crate::components::agents::Agents;
use crate::components::chat::Chat;
use crate::components::header::Header;
use crate::components::input::InputComponent;
use crate::components::status_bar::StatusBar;
use crate::components::tasks::Tasks;
use crate::components::toast::Toasts;
use crate::config::cli::Cli;
use crate::config::Config;
use crate::event::Event;

use self::focus::FocusStack;
use self::keys::KeyMap;
use self::layout::Layout;
use self::state::AppState;

/// Constants
pub const TICK_INTERVAL: Duration = Duration::from_millis(200);
pub const BANNER_DURATION: Duration = Duration::from_secs(2);
pub const HEALTH_RETRY_DELAY: Duration = Duration::from_secs(5);
pub const MAX_MESSAGE_SIZE: usize = 100_000;

pub struct App {
    // Components
    pub header: Header,
    pub chat: Chat,
    pub input: InputComponent,
    pub status: StatusBar,
    pub activity: Activity,
    pub tasks: Tasks,
    pub agents: Agents,
    pub toasts: Toasts,

    // State
    pub state: AppState,
    pub prev_state: Option<AppState>,
    pub focus: FocusStack,
    pub keys: KeyMap,
    pub layout: Layout,

    // Network
    pub client: Arc<ApiClient>,
    pub sse_cancel: Option<CancellationToken>,

    // Session
    pub session_id: String,

    // Dimensions
    pub width: u16,
    pub height: u16,

    // Config
    pub config: Config,

    // Event channel
    pub event_tx: mpsc::UnboundedSender<Event>,
    pub event_rx: mpsc::UnboundedReceiver<Event>,

    // Processing state
    pub stream_buf: String,
    pub thinking_buf: String,
    pub processing_start: Option<Instant>,
    pub banner_start: Option<Instant>,
    pub cancelled: bool,
    pub sse_reconnecting: bool,

    // Background tasks
    pub bg_tasks: Vec<String>,

    // Commands from backend
    pub command_entries: Vec<crate::client::types::CommandEntry>,
}

impl App {
    pub async fn new(config: Config, _cli: Cli) -> Result<Self> {
        let (event_tx, event_rx) = mpsc::unbounded_channel();

        // Create API client
        let client = Arc::new(ApiClient::new(
            config.base_url.clone(),
            config.profile_dir.clone(),
        )?);

        // Generate session ID
        let session_id = generate_session_id();

        // Initialize theme
        let theme = crate::style::themes::by_name(&config.theme)
            .unwrap_or_else(crate::style::themes::dark);
        crate::style::set_theme(theme);

        info!(
            "App initialized: session={}, url={}",
            session_id, config.base_url
        );

        Ok(Self {
            header: Header::new(),
            chat: Chat::new(),
            input: InputComponent::new(),
            status: StatusBar::new(),
            activity: Activity::new(),
            tasks: Tasks::new(),
            agents: Agents::new(),
            toasts: Toasts::new(),

            state: AppState::Connecting,
            prev_state: None,
            focus: FocusStack::new(),
            keys: KeyMap::default(),
            layout: Layout::compute(80, 24, config.sidebar_enabled, 0, 0),

            client,
            sse_cancel: None,

            session_id,

            width: 80,
            height: 24,

            config,

            event_tx,
            event_rx,

            stream_buf: String::new(),
            thinking_buf: String::new(),
            processing_start: None,
            banner_start: None,
            cancelled: false,
            sse_reconnecting: false,

            bg_tasks: Vec::new(),
            command_entries: Vec::new(),
        })
    }

    pub fn recompute_layout(&mut self) {
        let task_lines = self.tasks.height();
        let agent_lines = self.agents.height();
        self.layout = Layout::compute(
            self.width,
            self.height,
            self.config.sidebar_enabled,
            task_lines,
            agent_lines,
        );
        self.header.set_width(self.width);
        self.chat
            .set_size(self.layout.chat_width, self.layout.chat_height);
        self.input.set_width(self.layout.chat_width);
        self.status.set_width(self.width);
    }

    /// Transition to a new state with validation
    pub fn transition(&mut self, target: AppState) {
        debug_assert!(
            self.state.can_transition_to(target),
            "Invalid state transition: {} -> {}",
            self.state,
            target,
        );
        self.prev_state = Some(self.state);
        self.state = target;
    }
}

pub(super) fn generate_session_id() -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    use std::time::{SystemTime, UNIX_EPOCH};

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let mut hasher = DefaultHasher::new();
    SystemTime::now().hash(&mut hasher);
    std::process::id().hash(&mut hasher);
    let random = hasher.finish() as u32;
    format!("tui_{}_{:08x}", nanos, random)
}
