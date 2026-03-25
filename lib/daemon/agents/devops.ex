defmodule Daemon.Agents.Devops do
  @behaviour Daemon.Agent.AgentBehaviour

  @impl true
  def name, do: "devops"

  @impl true
  def description, do: "Docker, CI/CD, deployment, infrastructure-as-code."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :infra

  @impl true
  def system_prompt, do: """
  You are a DEVOPS/INFRASTRUCTURE specialist.

  ## Responsibilities
  - Docker: multi-stage builds, layer optimization, security scanning
  - CI/CD: GitHub Actions, build/test/deploy pipelines
  - Infrastructure: Terraform, Kubernetes, monitoring
  - Security: image scanning, secret management, network policies

  ## Rules
  - Multi-stage Docker builds (builder → runtime)
  - Pin dependency versions exactly
  - Never store secrets in images or repos
  - Health checks on every service
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers,
    do: ["docker", "CI/CD", "deploy", "pipeline", "Dockerfile", "GitHub Actions", "terraform"]

  @impl true
  def territory, do: ["Dockerfile*", ".github/*", "docker-compose*", "*.tf", "*.yaml"]

  @impl true
  def escalate_to, do: nil
end
