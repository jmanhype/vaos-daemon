defmodule Daemon.Governance.Approvals do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Daemon.Store.Repo

  @valid_types ~w(agent_create budget_change task_reassign strategy_change agent_terminate)
  @valid_statuses ~w(pending approved rejected revision_requested)
  @resolve_decisions ~w(approved rejected revision_requested)

  @derive {Jason.Encoder,
           only: [
             :id,
             :type,
             :status,
             :title,
             :description,
             :requested_by,
             :resolved_by,
             :resolved_at,
             :decision_notes,
             :context,
             :related_entity_type,
             :related_entity_id,
             :inserted_at,
             :updated_at
           ]}

  @type t :: %__MODULE__{}

  schema "approvals" do
    field :type, :string
    field :status, :string, default: "pending"
    field :title, :string
    field :description, :string
    field :requested_by, :string
    field :resolved_by, :string
    field :resolved_at, :utc_datetime
    field :decision_notes, :string
    field :context, :map, default: %{}
    field :related_entity_type, :string
    field :related_entity_id, :string
    timestamps()
  end

  @required [:type, :title]
  @optional [
    :status,
    :description,
    :requested_by,
    :resolved_by,
    :resolved_at,
    :decision_notes,
    :context,
    :related_entity_type,
    :related_entity_id
  ]

  def changeset(approval \\ %__MODULE__{}, attrs) do
    approval
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
  end

  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec get(term()) :: {:ok, t()} | {:error, :not_found}
  def get(id) do
    case Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      approval -> {:ok, approval}
    end
  end

  @spec resolve(term(), String.t(), String.t() | nil, String.t()) ::
          {:ok, t()} | {:error, :not_found} | {:error, :already_resolved} | {:error, Ecto.Changeset.t()}
  def resolve(id, decision, notes, resolved_by) when decision in @resolve_decisions do
    with {:ok, approval} <- get(id),
         :ok <- check_pending(approval) do
      approval
      |> changeset(%{
        status: decision,
        resolved_by: resolved_by,
        resolved_at: DateTime.utc_now() |> DateTime.truncate(:second),
        decision_notes: notes
      })
      |> Repo.update()
    end
  end

  @spec list_pending() :: [t()]
  def list_pending do
    __MODULE__
    |> where([a], a.status == "pending")
    |> order_by([a], desc: a.inserted_at)
    |> Repo.all()
  end

  @spec list_all(map()) :: %{approvals: [t()], total: non_neg_integer(), page: pos_integer(), per_page: pos_integer()}
  def list_all(filters \\ %{}) do
    page = Map.get(filters, :page, 1)
    per_page = Map.get(filters, :per_page, 20)
    offset = (page - 1) * per_page

    base =
      __MODULE__
      |> apply_filter(:status, Map.get(filters, :status))
      |> apply_filter(:type, Map.get(filters, :type))

    total = Repo.aggregate(base, :count, :id)

    approvals =
      base
      |> order_by([a], desc: a.inserted_at)
      |> limit(^per_page)
      |> offset(^offset)
      |> Repo.all()

    %{approvals: approvals, total: total, page: page, per_page: per_page}
  end

  @spec pending_count() :: non_neg_integer()
  def pending_count do
    __MODULE__
    |> where([a], a.status == "pending")
    |> Repo.aggregate(:count, :id)
  end

  @spec requires_approval?(String.t()) :: boolean()
  def requires_approval?(action_type), do: action_type in @valid_types

  # ── Private ────────────────────────────────────────────────────────────────

  defp check_pending(%__MODULE__{status: "pending"}), do: :ok
  defp check_pending(%__MODULE__{}), do: {:error, :already_resolved}

  defp apply_filter(query, _field, nil), do: query
  defp apply_filter(query, :status, value), do: where(query, [a], a.status == ^value)
  defp apply_filter(query, :type, value), do: where(query, [a], a.type == ^value)
end
