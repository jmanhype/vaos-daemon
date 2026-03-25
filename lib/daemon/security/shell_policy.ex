defmodule Daemon.Security.ShellPolicy do
  @moduledoc """
  Centralized shell command validation. Single source of truth for blocked
  commands and patterns across all callers (hooks, scheduler, shell_execute).

  Merges and de-duplicates every entry previously defined in:
    - lib/optimal_system_agent/agent/hooks.ex (security_check/1)
    - lib/optimal_system_agent/agent/scheduler.ex (@blocked_commands / @blocked_patterns)
    - lib/optimal_system_agent/skills/builtins/shell_execute.ex (same lists)

  The union here is a strict SUPERSET of all three sources.
  """

  # ── Blocked command names ─────────────────────────────────────────────────
  # Merged from scheduler.ex + shell_execute.ex (identical) PLUS hooks.ex
  # (hooks.ex had no explicit command list, so the scheduler set is the base).
  # Extra entries from hooks.ex block list: none — all covered below.
  @blocked_commands MapSet.new(
                      ~w(
    rm sudo dd mkfs fdisk format
    shutdown reboot halt poweroff
    init telinit
    kill killall pkill
    mount umount
    iptables
    systemctl
    passwd useradd userdel
    nc ncat
  )
                    )

  # ── Blocked regex patterns ────────────────────────────────────────────────
  # Superset: scheduler/shell_execute patterns (20) UNION hooks.ex patterns (11).
  # Comments mark the origin of each pattern added beyond the scheduler set.
  @blocked_pattern_sources [
    # ── Privilege escalation ─────────────────────────────────────────────
    # General rm-to-root (scheduler/shell_execute)
    {~S"\brm\s+(-[a-zA-Z]*\s+)*/", ""},
    {~S"\bsudo\b", ""},
    {~S"\bdd\b", ""},
    {~S"\bmkfs\b", ""},
    # Specific "rm -rf /" form (hooks.ex — already subsumed by the pattern
    # above, but kept explicitly for defence-in-depth clarity)
    {~S"rm\s+-rf\s+/", ""},
    # dd with input file specified (hooks.ex — more targeted than bare \bdd\b)
    {~S"dd\s+if=", ""},
    # Fork bomb (hooks.ex) — match with optional whitespace around braces
    {~S":\(\)\s*\{.*\|.*&\s*\}\s*;\s*:", ""},

    # ── Output redirection to system paths ───────────────────────────────
    {~S">\s*/etc/", ""},
    {~S">\s*~/\.ssh/", ""},
    {~S">\s*/boot/", ""},
    {~S">\s*/usr/", ""},
    # Raw device writes (hooks.ex)
    {~S">\s*/dev/sd", ""},

    # ── SQL destructive statements (hooks.ex) ────────────────────────────
    {~S"DROP\s+TABLE", "i"},
    {~S"DROP\s+DATABASE", "i"},

    # ── Shell injection / subshell ────────────────────────────────────────
    {~S"`[^`]*`", ""},
    {~S"\$\([^)]*\)", ""},
    {~S"\$\{[^}]*\}", ""},

    # ── Chained blocked commands ──────────────────────────────────────────
    {~S";\s*(rm|sudo|dd|mkfs|shutdown)", ""},
    {~S"\|\s*(rm|sudo|dd|mkfs|shutdown)", ""},
    {~S"&&\s*(rm|sudo|dd|mkfs|shutdown)", ""},
    {~S"\|\|\s*(rm|sudo|dd|mkfs|shutdown)", ""},

    # ── Piping remote content into a shell (hooks.ex) ────────────────────
    {~S"curl.*\|\s*sh", ""},
    {~S"wget.*\|\s*sh", ""},

    # ── Absolute path invocations ─────────────────────────────────────────
    {~S"/bin/(rm|dd|mkfs)", ""},
    {~S"/usr/bin/(sudo|pkill|killall)", ""},

    # ── Dangerous permission / ownership changes ──────────────────────────
    # More general pattern from scheduler (covers any leading octal digits)
    {~S"\bchmod\s+[0-7]*777\b", ""},
    # Simpler hooks.ex variant (already subsumed, kept for defence-in-depth)
    {~S"chmod\s+777", ""},
    {~S"\bchown\s+root\b", ""},

    # ── Sensitive file reads ──────────────────────────────────────────────
    {~S"\b(cat|less|more|head|tail|strings|xxd)\s+.*/etc/(shadow|passwd|sudoers)", ""},
    {~S"\b(cat|less|more|head|tail|strings|xxd)\s+.*\.ssh/(id_rsa|id_ed25519|id_ecdsa|id_dsa)", ""},
    {~S"\b(cat|less|more|head|tail|strings|xxd)\s+.*\.env\b", ""},

    # ── Path traversal ────────────────────────────────────────────────────
    {~S"\.\./", ""},

    # ── curl / wget writing to file ───────────────────────────────────────
    {~S"\bcurl\b.*\s(-o\s|--output\s)", ""},
    {~S"\bcurl\b.*\s-[a-zA-Z]*o\s", ""},
    {~S"\bwget\b.*\s(-O\s|--output-document\s)", ""},
    {~S"\bwget\b.*\s-[a-zA-Z]*O\s", ""},

    # ── Destructive git operations ─────────────────────────────────────
    {~S"\bgit\s+push\s+.*--force\b", ""},
    {~S"\bgit\s+push\s+-f\b", ""},
    {~S"\bgit\s+reset\s+--hard\b", ""},
    {~S"\bgit\s+clean\s+-[a-zA-Z]*f", ""},
    {~S"\bgit\s+checkout\s+--\s*\.", ""},
    {~S"\bgit\s+branch\s+-D\b", ""},
    {~S"\bgit\s+.*--no-verify\b", ""}
  ]

  @max_output_bytes 100_000

  defp compiled_blocked_patterns do
    Enum.map(@blocked_pattern_sources, fn {src, opts} -> Regex.compile!(src, opts) end)
  end

  # ── Public API ────────────────────────────────────────────────────────────

  @doc """
  Validates a shell command string against the consolidated blocklist.

  Returns `:ok` when the command is allowed, or `{:error, reason}` when it
  matches a blocked command name or a blocked regex pattern.

  Logic mirrors the most complete version from shell_execute.ex:
  1. Split on pipe/semicolon/ampersand boundaries.
  2. Check the first token of each segment against `@blocked_commands`.
  3. Check the full command string against every `@blocked_patterns` regex.
  """
  @spec validate(binary()) :: :ok | {:error, String.t()}
  def validate(command) when is_binary(command) do
    segments = Regex.split(~r/[|;&]/, command)

    blocked_segment =
      Enum.find(segments, fn segment ->
        first = segment |> String.trim() |> String.split() |> List.first() |> to_string()
        basename = Path.basename(first)
        MapSet.member?(@blocked_commands, first) or MapSet.member?(@blocked_commands, basename)
      end)

    cond do
      blocked_segment != nil ->
        {:error, "Command contains blocked command: #{String.trim(blocked_segment)}"}

      Enum.any?(compiled_blocked_patterns(), &Regex.match?(&1, command)) ->
        {:error, "Command contains blocked pattern"}

      true ->
        :ok
    end
  end

  @doc "Maximum output bytes returned from a shell command before truncation."
  @spec max_output_bytes() :: non_neg_integer()
  def max_output_bytes, do: @max_output_bytes
end
