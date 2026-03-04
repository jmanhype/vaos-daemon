defmodule OptimalSystemAgent.Tools.Builtins.MultiFileEdit do
  @behaviour OptimalSystemAgent.Tools.Behaviour

  @max_edits 20

  @default_allowed_paths ["~", "/tmp"]
  @sensitive_paths [".ssh/id_rsa", ".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_dsa",
    ".gnupg/", ".aws/credentials", ".env", "/etc/shadow", "/etc/sudoers",
    "/etc/master.passwd", ".netrc", ".npmrc", ".pypirc"]
  @blocked_write_paths [".ssh/", ".gnupg/", "/etc/", "/boot/", "/usr/",
    "/bin/", "/sbin/", "/var/", ".aws/", ".env"]

  @impl true
  def name, do: "multi_file_edit"

  @impl true
  def description, do: "Apply multiple string replacements across one or more files in a single atomic call. All edits are validated before any are applied."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "edits" => %{
          "type" => "array",
          "description" => "List of file edits to apply atomically (max #{@max_edits})",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "path" => %{"type" => "string", "description" => "Absolute file path"},
              "old_string" => %{"type" => "string", "description" => "Exact string to find and replace (must be unique in file)"},
              "new_string" => %{"type" => "string", "description" => "Replacement string"}
            },
            "required" => ["path", "old_string", "new_string"]
          }
        }
      },
      "required" => ["edits"]
    }
  end

  @impl true
  def execute(%{"edits" => edits}) when is_list(edits) and length(edits) > 0 do
    if length(edits) > @max_edits do
      {:error, "Too many edits: #{length(edits)} exceeds max of #{@max_edits}"}
    else
      validate_and_apply(edits)
    end
  end
  def execute(%{"edits" => []}), do: {:error, "edits list is empty"}
  def execute(_), do: {:error, "Missing required parameter: edits (array)"}

  defp validate_and_apply(edits) do
    # Phase 1: validate all edits, collect ALL failures before rejecting
    {valid_edits, errors} =
      edits
      |> Enum.with_index(1)
      |> Enum.reduce({[], []}, fn {edit, idx}, {oks, errs} ->
        case validate_edit(edit, idx) do
          {:ok, checked} -> {[checked | oks], errs}
          {:error, msg} -> {oks, [msg | errs]}
        end
      end)

    if errors != [] do
      {:error, "Validation failed — no edits applied:\n" <> Enum.join(Enum.reverse(errors), "\n")}
    else
      apply_edits(Enum.reverse(valid_edits))
    end
  end

  # Returns {:ok, %{expanded, display, old, new, content}} or {:error, msg}
  defp validate_edit(%{"path" => path, "old_string" => old, "new_string" => new}, idx) do
    expanded = Path.expand(path)
    prefix = "[edit #{idx}] #{path}"

    cond do
      not read_allowed?(expanded) ->
        {:error, "#{prefix}: access denied — outside allowed paths or sensitive file"}
      not write_allowed?(expanded) ->
        {:error, "#{prefix}: access denied — protected location"}
      old == "" ->
        {:error, "#{prefix}: old_string cannot be empty"}
      old == new ->
        {:error, "#{prefix}: old_string and new_string are identical"}
      true ->
        case File.read(expanded) do
          {:error, :enoent} -> {:error, "#{prefix}: file not found"}
          {:error, reason} -> {:error, "#{prefix}: cannot read — #{reason}"}
          {:ok, content} ->
            occurrences = count_occurrences(content, old)
            cond do
              occurrences == 0 ->
                {:error, "#{prefix}: old_string not found"}
              occurrences > 1 ->
                {:error, "#{prefix}: old_string found #{occurrences} times — must be unique"}
              true ->
                {:ok, %{expanded: expanded, display: path, old: old, new: new, content: content}}
            end
        end
    end
  end
  defp validate_edit(_, idx), do: {:error, "[edit #{idx}]: missing path, old_string, or new_string"}

  defp apply_edits(valid_edits) do
    # Group by file to count distinct files touched
    files_touched =
      valid_edits
      |> Enum.map(& &1.expanded)
      |> Enum.uniq()
      |> length()

    results =
      Enum.map(valid_edits, fn %{expanded: expanded, display: display, old: old, new: new, content: content} ->
        new_content = String.replace(content, old, new, global: false)
        File.write!(expanded, new_content)
        "  #{display}: replaced 1 occurrence"
      end)

    summary = "Applied #{length(valid_edits)} edits across #{files_touched} file(s):\n" <> Enum.join(results, "\n")
    {:ok, summary}
  end

  defp count_occurrences(content, pattern) do
    content |> String.split(pattern) |> length() |> Kernel.-(1)
  end

  defp read_allowed?(expanded_path) do
    sensitive = Enum.any?(@sensitive_paths, fn p -> String.contains?(expanded_path, p) end)
    if sensitive do
      false
    else
      check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
      Enum.any?(allowed_read_paths(), fn a -> String.starts_with?(check, a) end)
    end
  end

  defp write_allowed?(expanded_path) do
    if dotfile_outside_osa?(expanded_path) do
      false
    else
      blocked = Enum.any?(@blocked_write_paths, fn p -> String.contains?(expanded_path, p) end)
      if blocked do
        false
      else
        check = if String.ends_with?(expanded_path, "/"), do: expanded_path, else: expanded_path <> "/"
        Enum.any?(allowed_write_paths(), fn a -> String.starts_with?(check, a) end)
      end
    end
  end

  defp allowed_read_paths do
    Application.get_env(:optimal_system_agent, :allowed_read_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp allowed_write_paths do
    Application.get_env(:optimal_system_agent, :allowed_write_paths, @default_allowed_paths)
    |> Enum.map(fn p ->
      e = Path.expand(p)
      if String.ends_with?(e, "/"), do: e, else: e <> "/"
    end)
  end

  defp dotfile_outside_osa?(expanded_path) do
    home = Path.expand("~")
    osa = Path.expand("~/.osa") <> "/"
    case String.split_at(expanded_path, byte_size(home)) do
      {^home, "/" <> rest} ->
        first = rest |> String.split("/") |> List.first()
        String.starts_with?(first, ".") and not String.starts_with?(expanded_path, osa)
      _ -> false
    end
  end
end
