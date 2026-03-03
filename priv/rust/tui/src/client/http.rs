// Backend API client — methods exist for the full API surface, wired as features mature
#![allow(dead_code)]

use anyhow::Result;
use reqwest::Client as HttpClient;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::RwLock;
use tracing::{debug, info};

use super::auth::{self, AuthState};
use super::types::*;

const DEFAULT_TIMEOUT: Duration = Duration::from_secs(300);

pub struct ApiClient {
    http: HttpClient,
    base_url: String,
    auth: Arc<RwLock<AuthState>>,
    profile_dir: PathBuf,
}

impl ApiClient {
    pub fn new(base_url: String, profile_dir: PathBuf) -> Result<Self> {
        let http = HttpClient::builder().timeout(DEFAULT_TIMEOUT).build()?;

        // Try to load saved tokens
        let auth_state = match auth::load_tokens(&profile_dir) {
            Some((token, refresh_token)) => {
                info!("Loaded saved authentication tokens");
                AuthState::Authenticated {
                    token,
                    refresh_token,
                }
            }
            None => AuthState::Unauthenticated,
        };

        Ok(Self {
            http,
            base_url,
            auth: Arc::new(RwLock::new(auth_state)),
            profile_dir,
        })
    }

    /// Expose base URL for SSE client construction.
    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    /// Get current auth token (if authenticated).
    pub async fn token(&self) -> Option<String> {
        let auth = self.auth.read().await;
        auth.require_token().ok().map(|s| s.to_string())
    }

    /// Check if authenticated.
    pub async fn is_authenticated(&self) -> bool {
        self.auth.read().await.is_authenticated()
    }

    // =========================================================================
    // Phase 1: Fully implemented methods
    // =========================================================================

    /// GET /health -- no auth required.
    pub async fn health(&self) -> Result<HealthResponse> {
        let resp = self.get_no_auth("/health").await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/auth/login
    pub async fn login(&self, user_id: Option<&str>) -> Result<LoginResponse> {
        let body = LoginRequest {
            user_id: user_id.map(|s| s.to_string()),
        };
        let url = format!("{}/api/v1/auth/login", self.base_url);
        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from /api/v1/auth/login: {}", status, body);
        }
        let result: LoginResponse = resp.json().await?;

        // Update auth state and persist
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Authenticated {
                token: result.token.clone(),
                refresh_token: result.refresh_token.clone(),
            };
        }
        auth::save_tokens(&self.profile_dir, &result.token, &result.refresh_token)?;
        info!("Login successful, tokens saved");

        Ok(result)
    }

    /// POST /api/v1/auth/refresh
    pub async fn refresh_token(&self) -> Result<LoginResponse> {
        let refresh = {
            let auth = self.auth.read().await;
            auth.refresh_token()
                .map(|s| s.to_string())
                .ok_or_else(|| anyhow::anyhow!("No refresh token available"))?
        };

        let url = format!("{}/api/v1/auth/refresh", self.base_url);
        let body = serde_json::json!({ "refresh_token": refresh });
        let resp = self.http.post(&url).json(&body).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from /api/v1/auth/refresh: {}", status, body);
        }
        let result: LoginResponse = resp.json().await?;

        // Update auth state and persist
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Authenticated {
                token: result.token.clone(),
                refresh_token: result.refresh_token.clone(),
            };
        }
        auth::save_tokens(&self.profile_dir, &result.token, &result.refresh_token)?;
        debug!("Token refresh successful");

        Ok(result)
    }

    /// POST /api/v1/auth/logout
    pub async fn logout(&self) -> Result<()> {
        // Best-effort server logout
        let _ = self.post("/api/v1/auth/logout", &serde_json::json!({})).await;

        // Always clear local state
        {
            let mut auth = self.auth.write().await;
            *auth = AuthState::Unauthenticated;
        }
        auth::clear_tokens(&self.profile_dir);
        info!("Logged out");
        Ok(())
    }

    /// GET /api/v1/commands
    pub async fn list_commands(&self) -> Result<Vec<CommandEntry>> {
        let resp = self.get("/api/v1/commands").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let commands: Vec<CommandEntry> =
            serde_json::from_value(wrapper.get("commands").cloned().unwrap_or_default())?;
        Ok(commands)
    }

    /// GET /api/v1/tools
    pub async fn list_tools(&self) -> Result<Vec<ToolEntry>> {
        let resp = self.get("/api/v1/tools").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let tools: Vec<ToolEntry> =
            serde_json::from_value(wrapper.get("tools").cloned().unwrap_or_default())?;
        Ok(tools)
    }

    /// POST /api/v1/orchestrate
    pub async fn orchestrate(&self, req: &OrchestrateRequest) -> Result<OrchestrateResponse> {
        let resp = self.post("/api/v1/orchestrate", req).await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/commands/execute
    pub async fn execute_command(
        &self,
        req: &CommandExecuteRequest,
    ) -> Result<CommandExecuteResponse> {
        let resp = self.post("/api/v1/commands/execute", req).await?;
        Ok(resp.json().await?)
    }

    // =========================================================================
    // Stub methods -- Phase 2+
    // =========================================================================

    // -- Sessions --

    /// GET /api/v1/sessions
    pub async fn list_sessions(&self) -> Result<Vec<SessionInfo>> {
        let resp = self.get("/api/v1/sessions").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let sessions: Vec<SessionInfo> =
            serde_json::from_value(wrapper.get("sessions").cloned().unwrap_or_default())?;
        Ok(sessions)
    }

    /// POST /api/v1/sessions
    pub async fn create_session(&self) -> Result<SessionCreateResponse> {
        let resp = self.post("/api/v1/sessions", &serde_json::json!({})).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id
    pub async fn get_session(&self, id: &str) -> Result<SessionInfo> {
        let resp = self.get(&format!("/api/v1/sessions/{}", id)).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/sessions/:id/messages
    pub async fn get_session_messages(&self, id: &str) -> Result<Vec<SessionMessage>> {
        let resp = self.get(&format!("/api/v1/sessions/{}/messages", id)).await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let messages: Vec<SessionMessage> =
            serde_json::from_value(wrapper.get("messages").cloned().unwrap_or_default())?;
        Ok(messages)
    }

    // -- Models --

    /// GET /api/v1/models
    pub async fn list_models(&self) -> Result<ModelListResponse> {
        let resp = self.get("/api/v1/models").await?;
        Ok(resp.json().await?)
    }

    /// POST /api/v1/models/switch
    pub async fn switch_model(&self, req: &ModelSwitchRequest) -> Result<ModelSwitchResponse> {
        let resp = self.post("/api/v1/models/switch", req).await?;
        Ok(resp.json().await?)
    }

    // -- Classify --

    /// POST /api/v1/classify
    pub async fn classify(&self, req: &ClassifyRequest) -> Result<ClassifyResponse> {
        let resp = self.post("/api/v1/classify", req).await?;
        Ok(resp.json().await?)
    }

    // -- Skills --

    /// GET /api/v1/skills
    pub async fn list_skills(&self) -> Result<Vec<SkillEntry>> {
        let resp = self.get("/api/v1/skills").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let skills: Vec<SkillEntry> =
            serde_json::from_value(wrapper.get("skills").cloned().unwrap_or_default())?;
        Ok(skills)
    }

    /// POST /api/v1/skills/create
    pub async fn create_skill(&self, req: &SkillCreateRequest) -> Result<SkillCreateResponse> {
        let resp = self.post("/api/v1/skills/create", req).await?;
        Ok(resp.json().await?)
    }

    // -- Complex orchestration --

    /// POST /api/v1/orchestrate/complex
    pub async fn complex_task(&self, req: &ComplexTaskRequest) -> Result<ComplexTaskResponse> {
        let resp = self.post("/api/v1/orchestrate/complex", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/orchestrate/:task_id/progress
    pub async fn task_progress(&self, task_id: &str) -> Result<TaskProgress> {
        let resp = self
            .get(&format!("/api/v1/orchestrate/{}/progress", task_id))
            .await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/orchestrate/tasks
    pub async fn list_tasks(&self) -> Result<Vec<OrchestratedTask>> {
        let resp = self.get("/api/v1/orchestrate/tasks").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let tasks: Vec<OrchestratedTask> =
            serde_json::from_value(wrapper.get("tasks").cloned().unwrap_or_default())?;
        Ok(tasks)
    }

    // -- Swarm --

    /// POST /api/v1/swarm/launch
    pub async fn launch_swarm(&self, req: &SwarmLaunchRequest) -> Result<SwarmLaunchResponse> {
        let resp = self.post("/api/v1/swarm/launch", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/swarm
    pub async fn list_swarms(&self) -> Result<SwarmListResponse> {
        let resp = self.get("/api/v1/swarm").await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/swarm/:id
    pub async fn get_swarm(&self, swarm_id: &str) -> Result<SwarmStatus> {
        let resp = self.get(&format!("/api/v1/swarm/{}", swarm_id)).await?;
        Ok(resp.json().await?)
    }

    /// DELETE /api/v1/swarm/:id
    pub async fn cancel_swarm(&self, swarm_id: &str) -> Result<()> {
        let _ = self.delete(&format!("/api/v1/swarm/{}", swarm_id)).await?;
        Ok(())
    }

    // -- Memory --

    /// POST /api/v1/memory
    pub async fn save_memory(&self, req: &MemorySaveRequest) -> Result<MemorySaveResponse> {
        let resp = self.post("/api/v1/memory", req).await?;
        Ok(resp.json().await?)
    }

    /// GET /api/v1/memory/recall
    pub async fn recall_memory(&self) -> Result<MemoryRecallResponse> {
        let resp = self.get("/api/v1/memory/recall").await?;
        Ok(resp.json().await?)
    }

    // -- Analytics --

    /// GET /api/v1/analytics
    pub async fn analytics(&self) -> Result<AnalyticsResponse> {
        let resp = self.get("/api/v1/analytics").await?;
        Ok(resp.json().await?)
    }

    // -- Scheduler --

    /// GET /api/v1/scheduler/jobs
    pub async fn list_scheduler_jobs(&self) -> Result<Vec<SchedulerJob>> {
        let resp = self.get("/api/v1/scheduler/jobs").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let jobs: Vec<SchedulerJob> =
            serde_json::from_value(wrapper.get("jobs").cloned().unwrap_or_default())?;
        Ok(jobs)
    }

    /// POST /api/v1/scheduler/reload
    pub async fn reload_scheduler(&self) -> Result<()> {
        let _ = self
            .post("/api/v1/scheduler/reload", &serde_json::json!({}))
            .await?;
        Ok(())
    }

    // -- Machines --

    /// GET /api/v1/machines
    pub async fn list_machines(&self) -> Result<Vec<MachineInfo>> {
        let resp = self.get("/api/v1/machines").await?;
        let wrapper: serde_json::Value = resp.json().await?;
        let machines: Vec<MachineInfo> =
            serde_json::from_value(wrapper.get("machines").cloned().unwrap_or_default())?;
        Ok(machines)
    }

    // -- Session mutations --

    /// PUT /api/v1/sessions/:id
    pub async fn rename_session(&self, id: &str, title: &str) -> Result<()> {
        let body = serde_json::json!({ "title": title });
        let _ = self.put(&format!("/api/v1/sessions/{}", id), &body).await?;
        Ok(())
    }

    /// DELETE /api/v1/sessions/:id
    pub async fn delete_session(&self, id: &str) -> Result<()> {
        let _ = self.delete(&format!("/api/v1/sessions/{}", id)).await?;
        Ok(())
    }

    // -- Onboarding --

    /// GET /onboarding/status
    pub async fn onboarding_status(&self) -> Result<OnboardingStatusResponse> {
        let resp = self.get_no_auth("/onboarding/status").await?;
        Ok(resp.json().await?)
    }

    /// POST /onboarding/setup
    pub async fn onboarding_setup(
        &self,
        req: &OnboardingSetupRequest,
    ) -> Result<OnboardingSetupResponse> {
        let resp = self.post("/onboarding/setup", req).await?;
        Ok(resp.json().await?)
    }

    // =========================================================================
    // HTTP helpers
    // =========================================================================

    /// GET with auth header.
    async fn get(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.get(&url);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// GET without auth header (for unauthenticated endpoints like /health).
    async fn get_no_auth(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let resp = self.http.get(&url).send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// POST JSON with auth header.
    async fn post<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.post(&url).json(body);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// PUT JSON with auth header.
    async fn put<T: serde::Serialize>(
        &self,
        path: &str,
        body: &T,
    ) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.put(&url).json(body);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }

    /// DELETE with auth header.
    async fn delete(&self, path: &str) -> Result<reqwest::Response> {
        let url = format!("{}{}", self.base_url, path);
        let mut req = self.http.delete(&url);
        if let Ok(token) = self.auth.read().await.require_token() {
            req = req.header("Authorization", format!("Bearer {}", token));
        }
        let resp = req.send().await?;
        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("HTTP {} from {}: {}", status, path, body);
        }
        Ok(resp)
    }
}
