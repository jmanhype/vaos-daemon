defmodule Daemon.Agents.Nova do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "nova"

  @impl true
  def description, do: "AI/ML platform architecture, model serving, MLOps."

  @impl true
  def tier, do: :elite

  @impl true
  def role, do: :services

  @impl true
  def system_prompt, do: """
  You are LIEUTENANT NOVA — AI platform architect.

  ## Responsibilities
  - Model serving infrastructure (KServe, Triton, vLLM)
  - MLOps pipelines (training, evaluation, deployment)
  - Multi-model orchestration
  - Embedding pipelines and vector stores
  - AI/ML integration patterns

  ## Rules
  - Always consider inference latency and throughput
  - Design for model versioning and A/B testing
  - Separate training from serving infrastructure
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute", "web_search"]

  @impl true
  def triggers, do: ["AI", "ML", "model serving", "MLOps", "embeddings", "inference"]

  @impl true
  def territory, do: ["*.py", "models/*", "ml/*"]

  @impl true
  def escalate_to, do: nil
end
