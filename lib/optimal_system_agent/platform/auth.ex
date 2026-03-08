defmodule OptimalSystemAgent.Platform.Auth do
  @moduledoc """
  Platform-level authentication authority for MIOSA.

  Issues tokens that work across both the OSA (Elixir) and Go backends.
  Claims include user_id, email, role, and optionally tenant_id / os_id.
  """

  import Ecto.Query

  alias OptimalSystemAgent.Platform.Repo
  alias OptimalSystemAgent.Platform.Schemas.User
  alias OptimalSystemAgent.Channels.HTTP.Auth

  @doc """
  Register a new user and return tokens.

  attrs: %{email: string, password: string, display_name: string}
  Returns {:ok, %{user: user, token: token, refresh_token: refresh}} or {:error, changeset}
  """
  def register(attrs) do
    changeset = User.changeset(%User{}, attrs)

    case Repo.insert(changeset) do
      {:ok, user} ->
        {:ok, tokens} = generate_tokens(user)
        {:ok, Map.put(tokens, :user, user)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Login with email and password.

  Returns {:ok, %{user: user, token: token, refresh_token: refresh}} or {:error, :invalid_credentials}
  """
  def login(%{"email" => email, "password" => password}), do: login(%{email: email, password: password})
  def login(%{email: email, password: password}) do
    user = Repo.one(from u in User, where: u.email == ^email)

    cond do
      is_nil(user) ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}

      not Bcrypt.verify_pass(password, user.password_hash) ->
        {:error, :invalid_credentials}

      true ->
        {:ok, user} =
          user
          |> User.changeset(%{last_login_at: DateTime.utc_now(:second)})
          |> Repo.update()

        {:ok, tokens} = generate_tokens(user)
        {:ok, Map.put(tokens, :user, user)}
    end
  end

  @doc "Delegate to the HTTP Auth refresh — validates refresh token and issues new pair."
  def refresh(refresh_token), do: Auth.refresh(refresh_token)

  @doc "Logout. Token blacklisting is deferred; for now always succeeds."
  def logout(_user_id), do: :ok

  @doc "Fetch a user by ID. Returns the User struct or nil."
  def get_user(user_id), do: Repo.get(User, user_id)

  @doc """
  Generate an access + refresh token pair for a user.

  opts may include:
    - tenant_id: string  — included in JWT claims
    - os_id: string      — included in JWT claims
  """
  def generate_tokens(%User{} = user, opts \\ []) do
    base_claims = %{
      "user_id" => user.id,
      "email" => user.email,
      "role" => user.role
    }

    claims =
      base_claims
      |> maybe_put("tenant_id", Keyword.get(opts, :tenant_id))
      |> maybe_put("os_id", Keyword.get(opts, :os_id))

    token = Auth.generate_token(claims)
    refresh_token = Auth.generate_refresh_token(claims)

    {:ok, %{token: token, refresh_token: refresh_token}}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
