defmodule Daemon.Agents.Hierarchy do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Daemon.Store.Repo

  @valid_roles ~w(ceo director lead engineer specialist)
  @type t :: %__MODULE__{}

  schema "agent_hierarchy" do
    field :agent_name, :string
    field :reports_to, :string
    field :org_role, :string, default: "engineer"
    field :title, :string
    field :org_order, :integer, default: 0
    field :can_delegate_to, :string, default: "[]"
    field :metadata, :map, default: %{}
    timestamps()
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @spec get_tree() :: [map()]
  def get_tree do
    rows = Repo.all(from a in __MODULE__, order_by: [asc: a.org_order, asc: a.agent_name])
    build_tree(rows, nil)
  end

  @spec get_reports(String.t()) :: [t()]
  def get_reports(agent_name) do
    Repo.all(from a in __MODULE__, where: a.reports_to == ^agent_name)
  end

  @spec get_chain(String.t()) :: {:ok, [t()]} | {:error, :not_found}
  def get_chain(agent_name) do
    case Repo.get_by(__MODULE__, agent_name: agent_name) do
      nil -> {:error, :not_found}
      root -> {:ok, walk_up(root, [])}
    end
  end

  @spec move_agent(String.t(), String.t() | nil) :: {:ok, integer()} | {:error, atom()}
  def move_agent(agent_name, new_reports_to) do
    with :ok <- check_cycle(agent_name, new_reports_to) do
      count =
        Repo.update_all(
          from(a in __MODULE__, where: a.agent_name == ^agent_name),
          set: [reports_to: new_reports_to]
        )
        |> elem(0)

      {:ok, count}
    end
  end

  @spec set_role(String.t(), String.t()) :: {:ok, t()} | {:error, atom() | Ecto.Changeset.t()}
  def set_role(agent_name, role) when role in @valid_roles do
    case Repo.get_by(__MODULE__, agent_name: agent_name) do
      nil -> {:error, :not_found}
      agent -> agent |> change(org_role: role) |> Repo.update()
    end
  end

  def set_role(_agent_name, _role), do: {:error, :invalid_role}

  @spec delegate(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def delegate(from_agent, to_agent, task) do
    reports = get_reports(from_agent)

    case Enum.find(reports, &(&1.agent_name == to_agent)) do
      nil ->
        {:error, :not_a_direct_report}

      agent ->
        {:ok,
         %{
           from: from_agent,
           to: to_agent,
           task: task,
           delegated_at: DateTime.utc_now(),
           delegate_role: agent.org_role
         }}
    end
  end

  @spec seed_defaults() :: {:ok, integer()}
  def seed_defaults do
    {count, _} =
      Repo.insert_all(
        __MODULE__,
        default_agents(),
        on_conflict: :replace_all,
        conflict_target: :agent_name
      )

    {:ok, count}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp build_tree(rows, parent) do
    rows
    |> Enum.filter(&(&1.reports_to == parent))
    |> Enum.map(fn row ->
      %{
        agent_name: row.agent_name,
        reports_to: row.reports_to,
        org_role: row.org_role,
        title: row.title,
        children: build_tree(rows, row.agent_name)
      }
    end)
  end

  defp walk_up(%__MODULE__{reports_to: nil} = node, acc), do: Enum.reverse([node | acc])

  defp walk_up(%__MODULE__{reports_to: parent_name} = node, acc) do
    case Repo.get_by(__MODULE__, agent_name: parent_name) do
      nil -> Enum.reverse([node | acc])
      parent -> walk_up(parent, [node | acc])
    end
  end

  defp check_cycle(_agent_name, nil), do: :ok

  defp check_cycle(agent_name, candidate) do
    case Repo.get_by(__MODULE__, agent_name: candidate) do
      nil -> :ok
      %{agent_name: ^agent_name} -> {:error, :cycle_detected}
      %{reports_to: nil} -> :ok
      %{reports_to: next} -> check_cycle(agent_name, next)
    end
  end

  defp now do
    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  defp agent(name, role, reports, title, order) do
    %{
      agent_name: name,
      org_role: role,
      reports_to: reports,
      title: title,
      org_order: order,
      can_delegate_to: "[]",
      metadata: %{},
      inserted_at: now(),
      updated_at: now()
    }
  end

  defp default_agents do
    [
      agent("master_orchestrator", "ceo", nil, "Chief Executive", 0),
      agent("architect", "director", "master_orchestrator", "Chief Architect", 10),
      agent("dragon", "lead", "architect", "VP Engineering", 20),
      agent("backend_go", "engineer", "dragon", nil, 30),
      agent("frontend_react", "engineer", "dragon", nil, 31),
      agent("frontend_svelte", "engineer", "dragon", nil, 32),
      agent("database", "engineer", "dragon", nil, 33),
      agent("go_concurrency", "engineer", "dragon", nil, 34),
      agent("typescript_expert", "engineer", "dragon", nil, 35),
      agent("tailwind_expert", "engineer", "dragon", nil, 36),
      agent("orm_expert", "engineer", "dragon", nil, 37),
      agent("nova", "lead", "architect", "VP AI/ML", 40),
      agent("api_designer", "engineer", "architect", nil, 50),
      agent("devops", "engineer", "architect", nil, 51),
      agent("performance_optimizer", "engineer", "architect", nil, 52),
      agent("security_auditor", "director", "master_orchestrator", "Chief Security Officer", 60),
      agent("red_team", "specialist", "security_auditor", nil, 70),
      agent("code_reviewer", "lead", "master_orchestrator", "VP Quality", 80),
      agent("test_automator", "engineer", "code_reviewer", nil, 90),
      agent("qa_lead", "engineer", "code_reviewer", nil, 91),
      agent("debugger", "engineer", "code_reviewer", nil, 92),
      agent("reviewer", "specialist", "code_reviewer", nil, 93),
      agent("tester", "specialist", "code_reviewer", nil, 94),
      agent("doc_writer", "engineer", "master_orchestrator", nil, 100),
      agent("refactorer", "engineer", "master_orchestrator", nil, 101),
      agent("explorer", "engineer", "master_orchestrator", nil, 102),
      agent("researcher", "engineer", "master_orchestrator", nil, 103),
      agent("coder", "engineer", "master_orchestrator", nil, 104),
      agent("writer", "engineer", "master_orchestrator", nil, 105),
      agent("formatter", "specialist", "master_orchestrator", nil, 106),
      agent("dependency_analyzer", "specialist", "master_orchestrator", nil, 107)
    ]
  end
end
