defmodule Daemon.Channels.HTTP.API.MessageValidation do
  @moduledoc """
  Changeset-based validation for incoming HTTP API message data.

  Provides centralized validation logic for message submissions, ensuring
  required fields are present and valid before processing. Returns
  consistent JSON error responses matching the API's error format.

  ## Request Types

  ### Simple Orchestration (POST /orchestrate)
    * `input` - The text message/task content (non-empty string)
    * `session_id` - Optional session identifier (auto-generated if missing)

  ### Complex Orchestration (POST /orchestrate/complex)
    * `task` - The task description (non-empty string)
    * `session_id` - Optional session identifier (auto-generated if missing)
    * `strategy` - Optional strategy ("auto", "pact", etc.)

  ### Swarm Launch (POST /swarm/launch)
    * `task` - The task description (non-empty string)
    * `pattern` - Optional pattern name
    * `max_agents` - Optional maximum number of agents (1-10)
    * `timeout_ms` - Optional timeout in milliseconds (1000-600000)

  ## Usage

      case MessageValidation.validate_orchestration(params) do
        {:ok, validated_data} ->
          # Process validated message

        {:error, changeset} ->
          # Return formatted errors to client
          {status, error_code, details} = MessageValidation.error_response(changeset)
          json_error(conn, status, error_code, details)
      end
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    # Simple orchestration fields
    field(:input, :string)
    field(:skip_plan, :boolean)
    field(:working_dir, :string)
    field(:auto_dispatch, :boolean)

    # Complex orchestration fields
    field(:task, :string)
    field(:strategy, :string)
    field(:max_agents, :integer)
    field(:blocking, :boolean)

    # Common fields
    field(:session_id, :string)
    field(:user_id, :string)

    # Swarm-specific fields
    field(:pattern, :string)
    field(:timeout_ms, :integer)
  end

  @max_input_length 100_000
  @max_agents_limit 10
  @min_timeout_ms 1_000
  @max_timeout_ms 600_000

  @doc """
  Validates simple orchestration request parameters (POST /orchestrate).

  ## Parameters

    * `params` - Map of raw parameters from request body

  ## Returns

    * `{:ok, validated_data}` - Changeset with valid data
    * `{:error, changeset}` - Changeset with validation errors

  ## Examples

      iex> MessageValidation.validate_orchestration(%{"input" => "hello world"})
      {:ok, %{input: "hello world", ...}}

      iex> MessageValidation.validate_orchestration(%{})
      {:error, %Ecto.Changeset{valid?: false}}
  """
  def validate_orchestration(params) do
    %__MODULE__{}
    |> cast(params, [:input, :session_id, :user_id, :skip_plan, :working_dir, :auto_dispatch])
    |> validate_required([:input],
      message: "is required for orchestration"
    )
    |> validate_input()
    |> validate_session_id()
    |> validate_working_dir()
    |> case do
      %{valid?: true} = changeset -> {:ok, apply_changes(changeset)}
      %{valid?: false} = changeset -> {:error, changeset}
    end
  end

  @doc """
  Validates complex orchestration request parameters (POST /orchestrate/complex).

  ## Parameters

    * `params` - Map of raw parameters from request body

  ## Returns

    * `{:ok, validated_data}` - Changeset with valid data
    * `{:error, changeset}` - Changeset with validation errors
  """
  def validate_complex_orchestration(params) do
    %__MODULE__{}
    |> cast(params, [:task, :session_id, :strategy, :max_agents, :blocking])
    |> validate_required([:task],
      message: "is required for complex orchestration"
    )
    |> validate_task()
    |> validate_session_id()
    |> validate_strategy()
    |> validate_max_agents()
    |> case do
      %{valid?: true} = changeset -> {:ok, apply_changes(changeset)}
      %{valid?: false} = changeset -> {:error, changeset}
    end
  end

  @doc """
  Validates swarm launch request parameters (POST /swarm/launch).

  ## Parameters

    * `params` - Map of raw parameters from request body

  ## Returns

    * `{:ok, validated_data}` - Changeset with valid data
    * `{:error, changeset}` - Changeset with validation errors
  """
  def validate_swarm_launch(params) do
    %__MODULE__{}
    |> cast(params, [:task, :session_id, :pattern, :max_agents, :timeout_ms])
    |> validate_required([:task],
      message: "is required for swarm launch"
    )
    |> validate_task()
    |> validate_session_id()
    |> validate_pattern()
    |> validate_max_agents()
    |> validate_timeout_ms()
    |> case do
      %{valid?: true} = changeset -> {:ok, apply_changes(changeset)}
      %{valid?: false} = changeset -> {:error, changeset}
    end
  end

  @doc """
  Formats changeset errors into a consistent JSON-friendly structure.

  Returns a map with field names as keys and error messages as values.

  ## Examples

      iex> changeset_errors(changeset)
      %{"message_content" => ["can't be blank"], "thread_id" => ["can't be blank"]}
  """
  def changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts
        |> Keyword.get(String.to_existing_atom(key), key)
        |> to_string()
      end)
    end)
  end

  # Private validation helpers

  defp validate_message_content(changeset) do
    changeset
    |> validate_length(:message_content,
      min: 1,
      max: 100_000,
      message: "must be between 1 and 100000 characters"
    )
    |> validate_change(:message_content, fn :message_content, content ->
      cond do
        not is_binary(content) ->
          [message_content: "must be a string"]

        String.trim(content) == "" ->
          [message_content: "cannot be empty or whitespace only"]

        not String.valid?(content) ->
          [message_content: "contains invalid UTF-8 characters"]

        true ->
          []
      end
    end)
  end

  defp validate_thread_id(changeset) do
    changeset
    |> validate_length(:thread_id,
      min: 1,
      max: 255,
      message: "must be between 1 and 255 characters"
    )
    |> validate_change(:thread_id, fn :thread_id, thread_id ->
      cond do
        not is_binary(thread_id) ->
          [thread_id: "must be a string"]

        String.trim(thread_id) == "" ->
          [thread_id: "cannot be empty or whitespace only"]

        not String.valid?(thread_id) ->
          [thread_id: "contains invalid UTF-8 characters"]

        true ->
          []
      end
    end)
  end

  @doc """
  Builds a standardized error response tuple for API handlers.

  ## Parameters

    * `changeset` - Invalid changeset

  ## Returns

    * `{status_code, error_code, details}` - Tuple suitable for json_error/4

  ## Examples

      {400, "validation_failed", %{"message_content" => ["can't be blank"]}}
  """
  def error_response(changeset) do
    errors = changeset_errors(changeset)

    {400, "validation_failed", errors}
  end
end
