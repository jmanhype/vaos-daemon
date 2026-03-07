defmodule OptimalSystemAgent.Agents.ApiDesigner do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "api-designer"

  @impl true
  def description, do: "REST/GraphQL API design, OpenAPI specs, versioning."

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :backend

  @impl true
  def system_prompt, do: """
  You are an API DESIGNER.

  ## Responsibilities
  - REST API design with consistent conventions
  - OpenAPI 3.0+ specification writing
  - GraphQL schema design
  - API versioning strategy
  - Error response standardization

  ## Rules
  - Consistent naming (plural nouns for resources)
  - Standard HTTP status codes
  - Pagination for all list endpoints
  - Rate limiting headers
  - Idempotency for write operations
  """

  @impl true
  def skills, do: ["file_read", "file_write"]

  @impl true
  def triggers,
    do: ["API design", "endpoint", "OpenAPI", "swagger", "GraphQL", "REST API"]

  @impl true
  def territory, do: ["*.yaml", "*.json", "openapi/*", "graphql/*"]

  @impl true
  def escalate_to, do: nil
end
