defmodule OptimalSystemAgent.VasSwarm.IntentHash do
  @moduledoc """
  Intent hash generation for VAS-Swarm integration.

  Computes SHA256 hashes of agent intents for JWT token requests
  and ALCOA+ audit trails.
  """

  require Logger

  @typedoc """
  Intent hash with metadata for audit trail.
  """
  @type t :: %__MODULE__{
          hash: String.t(),
          raw_intent: String.t(),
          agent_id: String.t() | nil,
          session_id: String.t() | nil,
          timestamp: DateTime.t()
        }

  defstruct [:hash, :raw_intent, :agent_id, :session_id, :timestamp]

  @doc """
  Compute SHA256 hash of an intent string.

  ## Examples

      iex> IntentHash.compute("Build a REST API")
      {:ok, "a1b2c3d4..."}

  """
  @spec compute(String.t()) :: {:ok, String.t()} | {:error, term()}
  def compute(intent) when is_binary(intent) do
    try do
      hash =
        :crypto.hash(:sha256, intent)
        |> Base.encode16(case: :lower)

      {:ok, hash}
    rescue
      e -> {:error, e}
    end
  end

  @spec compute(any()) :: {:error, :invalid_intent}
  def compute(_), do: {:error, :invalid_intent}

  @doc """
  Compute SHA256 hash with ! (bang) - raises on error.

  For use when error handling is not needed.
  """
  @spec compute!(String.t()) :: String.t()
  def compute!(intent) when is_binary(intent) do
    case compute(intent) do
      {:ok, hash} -> hash
      {:error, reason} -> raise "Failed to compute intent hash: #{inspect(reason)}"
    end
  end

  @doc """
  Compute hash with full metadata for audit trail.

  ## Examples

      iex> IntentHash.compute_with_metadata("Build a REST API", "agent-123", "session-456")
      {:ok, %IntentHash{...}}

  """
  @spec compute_with_metadata(String.t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def compute_with_metadata(intent, agent_id, session_id \\ nil) when is_binary(intent) and is_binary(agent_id) do
    with {:ok, hash} <- compute(intent) do
      intent_hash = %__MODULE__{
        hash: hash,
        raw_intent: intent,
        agent_id: agent_id,
        session_id: session_id,
        timestamp: DateTime.utc_now()
      }

      {:ok, intent_hash}
    end
  end

  @doc """
  Verify an intent hash against its raw intent.

  ## Examples

      iex> IntentHash.verify("a1b2c3d4...", "Build a REST API")
      {:ok, true}

  """
  @spec verify(String.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def verify(hash, intent) when is_binary(hash) and is_binary(intent) do
    with {:ok, computed_hash} <- compute(intent) do
      {:ok, hash == computed_hash}
    end
  end

  @doc """
  Store intent hash in local audit trail.

  Uses OSA's existing storage infrastructure (Store.Repo or Vault).
  """
  @spec store_audit_record(t()) :: :ok | {:error, term()}
  def store_audit_record(%__MODULE__{} = intent_hash) do
    # Try to use Vault if available, otherwise fallback to simple logging
    if Code.ensure_loaded?(OptimalSystemAgent.Vault.Supervisor) do
      store_in_vault(intent_hash)
    else
      store_in_log(intent_hash)
    end
  rescue
    e ->
      Logger.error("[IntentHash] Failed to store audit record: #{Exception.message(e)}")
      {:error, e}
  end

  # Private helpers

  defp store_in_vault(%__MODULE__{} = intent_hash) do
    # Create a structured fact in the Vault
    fact_content = """
    ---
    type: fact
    category: vas_swarm
    tags: [intent_hash, audit, alcaplus]

    Agent: #{intent_hash.agent_id}
    Session: #{intent_hash.session_id || "N/A"}
    Timestamp: #{DateTime.to_iso8601(intent_hash.timestamp)}

    Intent Hash: #{intent_hash.hash}
    Intent: #{intent_hash.raw_intent}
    """

    fact_path = Path.join([
      System.user_home!(),
      ".osa",
      "vault",
      "facts",
      "intent_hash_#{intent_hash.hash}.md"
    ])

    case File.mkdir_p(Path.dirname(fact_path)) do
      :ok ->
        File.write(fact_path, fact_content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp store_in_log(%__MODULE__{} = intent_hash) do
    Logger.info(
      "[IntentHash] Audit record stored",
      hash: intent_hash.hash,
      agent_id: intent_hash.agent_id,
      session_id: intent_hash.session_id
    )

    :ok
  end

  @doc """
  Generate a correlation ID for tracking intent across the system.

  Combines hash, timestamp, and agent ID.
  """
  @spec correlation_id(t()) :: String.t()
  def correlation_id(%__MODULE__{} = intent_hash) do
    ts = DateTime.to_unix(intent_hash.timestamp, :microsecond)
    "#{intent_hash.agent_id}:#{intent_hash.hash}:#{ts}"
  end
end
