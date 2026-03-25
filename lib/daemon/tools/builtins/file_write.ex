defmodule Daemon.Tools.Builtins.FileWrite do
  @behaviour MiosaTools.Behaviour

  @default_allowed_write_paths ["~", "/tmp"]

  @blocked_write_paths [
    ".ssh/",
    ".gnupg/",
    "/etc/",
    "/boot/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/var/",
    ".aws/",
    ".env"
  ]

  @impl true
  def safety, do: :write_safe

  @impl true
  def name, do: "file_write"

  @impl true
  def description, do: "Write content to a file. Use relative paths (e.g. 'my-app/server.js') to write into the workspace at ~/.daemon/workspace/. Absolute paths and ~ paths are also accepted."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{"type" => "string", "description" => "Path to write to. Relative paths are rooted at ~/.daemon/workspace/ automatically. Example: 'todo-app/server.js' writes to ~/.daemon/workspace/todo-app/server.js"},
        "content" => %{"type" => "string", "description" => "Content to write"}
      },
      "required" => ["path", "content"]
    }
  end

  @impl true
  def execute(%{"path" => path, "content" => content}) do
    normalized =
      if relative_path?(path) do
        Path.join("~/.daemon/workspace", path)
      else
        path
      end

    expanded = Path.expand(normalized)

    if write_allowed?(expanded) do
      case File.mkdir_p(Path.dirname(expanded)) do
        :ok ->
          case File.write(expanded, content) do
            :ok -> {:ok, "Written to #{expanded}"}
            {:error, reason} -> {:error, "Error writing file: #{reason}"}
          end

        {:error, reason} ->
          {:error, "Cannot create directory: #{:file.format_error(reason)}"}
      end
    else
      {:error, "Access denied: #{path} is outside allowed paths or targets a protected location"}
    end
  end

  defp relative_path?(path) do
    not (String.starts_with?(path, "~") or
           String.starts_with?(path, "/") or
           String.match?(path, ~r/^[A-Za-z]:[\\\/]/))
  end

  defp allowed_write_paths do
    configured =
      Application.get_env(
        :daemon,
        :allowed_write_paths,
        @default_allowed_write_paths
      )

    Enum.map(configured, fn p ->
      expanded = Path.expand(p)
      if String.ends_with?(expanded, "/"), do: expanded, else: expanded <> "/"
    end)
  end

  defp osa_path do
    Path.expand("~/.daemon") <> "/"
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    # A dotfile is any path directly under ~ starting with a dot component
    # e.g. ~/.bashrc, ~/.zshrc, ~/.config/..., ~/.ssh/config
    # but NOT paths under ~/.daemon/ (those are OSA's own config)
    relative =
      case String.split_at(expanded_path, byte_size(home)) do
        {^home, rest} -> rest
        _ -> nil
      end

    case relative do
      "/" <> rest ->
        first_component = rest |> String.split("/") |> List.first()
        starts_with_dot = String.starts_with?(first_component, ".")
        under_osa = String.starts_with?(expanded_path, osa_path())
        starts_with_dot and not under_osa

      _ ->
        false
    end
  end

  defp write_allowed?(expanded_path) do
    # Block dotfiles outside ~/.daemon/
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked =
        Enum.any?(@blocked_write_paths, fn pattern ->
          String.contains?(expanded_path, pattern)
        end)

      if blocked do
        false
      else
        check_path =
          if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"

        Enum.any?(allowed_write_paths(), fn allowed ->
          String.starts_with?(check_path, allowed)
        end)
      end
    end
  end
end
