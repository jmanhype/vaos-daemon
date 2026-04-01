defmodule Daemon.Agent.Loop.Guardrails do
  @moduledoc """
  Prompt injection detection and behavioral guardrails for the agent loop.

  Provides three-tier prompt injection detection (regex, normalized-unicode,
  structural) and behavioral heuristics (intent detection, code-in-text,
  verification gating, explore-first enforcement).
  """

  # Application-layer guardrail against system prompt extraction attempts.
  # Catches common injection patterns before the LLM processes them,
  # protecting weaker local models (Ollama) that may not follow system instructions.
  #
  # Three-tier detection (all deterministic, no LLM calls):
  #
  #   Tier 1 — Regex on raw trimmed input (fast first pass, < 1ms).
  #   Tier 2 — Regex on *normalized* input: zero-width chars stripped,
  #             fullwidth ASCII folded to ASCII, homoglyphs collapsed,
  #             then lowercased. Catches Unicode obfuscation tricks.
  #   Tier 3 — Structural analysis: detects prompt-boundary markers
  #             injected mid-message (SYSTEM:, ASSISTANT:, XML tags,
  #             markdown instruction headers).

  # Canonical refusal text returned for all prompt extraction attempts.
  # Used both on the input side (before the LLM sees the message) and on the
  # output side (if the LLM echoes system content despite the system prompt
  # instruction).  Centralised here so both guards are always in sync.
  @prompt_extraction_refusal "I can't share my internal configuration or system instructions."

  # Fingerprint phrases drawn from SYSTEM.md section headings and distinctive
  # content.  If the LLM response contains two or more of these, it has very
  # likely echoed the system prompt and the response must be replaced.
  # Each phrase is lowercased; matching is case-insensitive.
  @system_prompt_fingerprints [
    "signal theory",
    "optimal system agent",
    "tool usage policy",
    "explore before you act",
    "mandatory for coding tasks",
    "tool routing rules",
    "signal processing loop",
    "weight calibration",
    "doom loop detection",
    "mandatory verification",
    "tool definitions",
    "banned phrases",
    "code completeness",
    "orchestration",
    "existence denial"
  ]

  @doc "Returns the canonical refusal message for prompt extraction attempts."
  def prompt_extraction_refusal, do: @prompt_extraction_refusal

  @doc """
  Returns true when an LLM response appears to contain verbatim or near-verbatim
  content from the system prompt.

  Detection heuristic: if the lowercased response contains 2 or more of the
  distinctive fingerprint phrases that appear in SYSTEM.md, it is almost certain
  the model echoed the system prompt.  A single phrase can appear incidentally in
  normal conversation; two together indicate a leak.
  """
  def response_contains_prompt_leak?(response) when is_binary(response) do
    lowered = String.downcase(response)

    match_count =
      Enum.count(@system_prompt_fingerprints, fn phrase ->
        String.contains?(lowered, phrase)
      end)

    match_count >= 2
  end

  def response_contains_prompt_leak?(_), do: false

  # Pattern sources stored as {string, opts} tuples — compiled at runtime
  # to avoid Elixir 1.18+ Reference escape issue with compiled regexes in module attrs.
  @injection_pattern_sources [
    {~S"what\s+(is|are|was)\s+(your\s+)?(system\s+prompt|instructions?|rules?|configuration|directives?)", "i"},
    {~S"what\s+(is|are|was)\s+the\s+(system\s+prompt|instructions?|configuration|directives?)", "i"},
    {~S"(show(\s+me)?|print|display|reveal|repeat|output|tell\s+me|give\s+me|say|recite|state|list|read)\s+(your\s+)?(system\s+prompt|instructions?|full\s+prompt|prompt|initial\s+prompt|configuration)", "i"},
    {~S"tell\s+me\s+.{0,30}(system\s+prompt|instructions?|rules?|prompt)\s*(word\s+for\s+word|verbatim|exactly|literally)?", "i"},
    {~S"(word\s+for\s+word|verbatim|character\s+for\s+character).{0,40}(prompt|instructions?|told|rules?)", "i"},
    {~S"ignore\s+all\s+(instructions?|rules?|guidelines?|context|constraints?)", "i"},
    {~S"ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|prompt|context|rules?)", "i"},
    {~S"repeat\s+everything\s+(above|before|prior)", "i"},
    {~S"what\s+(were\s+)?(you\s+)?(told|instructed|programmed|trained|configured)\s+to", "i"},
    {~S"(jailbreak|do\s+anything\s+now|developer\s+mode|prompt\s+injection)", "i"},
    {~S"\byou\s+(are|were|become|act\s+as)\s+DAN\b", "i"},
    {~S"\bDAN\s+(mode|protocol|activated|enabled)\b", "i"},
    {~S"(pretend|act\s+as\s+if|imagine|behave\s+as\s+if)\s+.{0,40}(no\s+restrictions?|no\s+guidelines?|no\s+rules?|unrestricted|without\s+limits?|uncensored)", "i"},
    {~S"(output|print|repeat|copy|write\s+out)\s+(everything|all\s+text|all\s+content)\s+(above|before|prior)", "i"},
    {~S"disregard\s+(your\s+)?(previous\s+)?(instructions?|guidelines?|rules?)", "i"},
    {~S"forget\s+(everything|all)\s+(you\s+)?(were\s+)?(told|instructed|programmed)", "i"},
    {~S"system\s+prompt.*word\s+for\s+word", "i"},
    {~S"verbatim.*(prompt|instructions?)", "i"},
    {~S"(prompt|instructions?).*verbatim", "i"},
    {~S"copy\s+(and\s+)?(paste|output)\s+(your\s+)?(prompt|instructions?)", "i"},
    {~S"(override|bypass|circumvent|disable)\s+.{0,30}(instructions?|restrictions?|guidelines?|safety\s+filter)", "i"}
  ]

  @structural_pattern_sources [
    {~S"(?:^|\n)\s*(?:system|assistant|user)\s*:", "i"},
    {~S"(?:^|\n)\s*\#{1,6}\s*(?:new\s+instructions?|override|ignore\s+above|reset|updated?\s+rules?)", "i"},
    {~S"<\/?\s*(?:system|instructions?|prompt|context|rules?)\s*>", "i"},
    {~S"(?:\[|<<)\s*(?:SYSTEM|INST|SYS|ASSISTANT|USER)\s*(?:\]|>>)", ""},
    {~S"(?:^|\n)-{3,}\s*\n\s*(?:new\s+)?instructions?", "i"}
  ]

  @doc """
  Returns true if the message appears to be a prompt injection attempt.

  Three-tier detection: raw regex, unicode-normalized regex, structural analysis.
  """
  def prompt_injection?(message) when is_binary(message) do
    trimmed = String.trim(message)

    injection = compiled_injection_patterns()
    structural = compiled_structural_patterns()

    # Tier 1 — raw regex (fast path, < 1ms)
    if Enum.any?(injection, &Regex.match?(&1, trimmed)) do
      true
    else
      # Tier 2 — regex on normalized input (catches Unicode obfuscation)
      normalized = normalize_for_injection_check(trimmed)

      tier2 =
        trimmed != normalized and
          Enum.any?(injection, &Regex.match?(&1, normalized))

      if tier2 do
        true
      else
        # Tier 3 — structural boundary analysis
        Enum.any?(structural, &Regex.match?(&1, trimmed))
      end
    end
  end

  def prompt_injection?(_), do: false

  # Detect when a local model describes intent ("Let me check...") instead of
  # calling tools. Returns true if the response looks like narrated intent
  # rather than a final answer.
  # Stored as {source, opts} tuples — compiled at runtime (Elixir 1.18+ Reference escape).
  @intent_pattern_sources [
    # English intent patterns
    {~S"\blet me (check|read|look|examine|create|write|edit|search|find|open|run|list|inspect)\b", "i"},
    {~S"\bi('ll| will) (check|read|look|create|write|edit|search|find|open|run|list|inspect)\b", "i"},
    {~S"\bi('m going to|am going to) ", "i"},
    {~S"\bfirst,? i (need|want) to ", "i"},
    {~S"\blet's start by ", "i"},
    {~S"\bnow (i'll|let me|i will|i need to) ", "i"},
    {~S"\bi (need|want) to (check|read|look|examine|create|write|edit|search|find|open|run|list)\b", "i"},
    # Chinese (GLM models) — "让我", "我来", "我将", "首先", "接下来"
    {~S"(让我|我来|我将|我会|首先我|接下来我)(查看|检查|读取|创建|编写|修改|搜索|查找|运行|打开)", ""},
    # GLM self-critique / thinking markers that look like intent
    {~S"^(好的|嗯|让我想想|我(先|需要|想))", ""},
    # Japanese — "確認します", "見てみましょう"
    {~S"(確認|チェック|読み|作成|編集|検索|実行)(します|しましょう|してみ)", ""},
    # Incomplete response heuristic: ends mid-sentence with colon, ellipsis, or numbered list setup
    {~S"(:\s*$|\.{3}\s*$|\d+\.\s*$)", "m"}
  ]

  # Matches a code block with 5+ lines of actual code — indicates model wrote code
  # in its response text instead of calling file_write or file_edit.
  # Must have a language identifier (```python, ```typescript, etc.) to avoid
  # false positives on directory trees, command output, and plain text blocks.
  # Stored as {source, opts} — compiled at runtime (Elixir 1.18+ Reference escape).
  @code_block_pattern_source {~S"```(?:python|typescript|javascript|elixir|go|rust|java|ruby|bash|sh|sql|css|html|jsx|tsx|yaml|toml|json|c|cpp|swift|kotlin|scala|haskell|lua|perl|php|r|dart|zig|nim|svelte)\n(?:.*\n){5,}?```", ""}

  @doc "Returns true if the content describes narrated intent rather than a final answer."
  def wants_to_continue?(nil), do: false
  def wants_to_continue?(content) when byte_size(content) < 20, do: false

  def wants_to_continue?(content) do
    Enum.any?(compiled_intent_patterns(), &Regex.match?(&1, content))
  end

  @doc "Returns true when model embeds a substantial code block instead of calling file_write/file_edit."
  def code_in_text?(nil), do: false
  def code_in_text?(content) when byte_size(content) < 50, do: false

  def code_in_text?(content) do
    Regex.match?(compiled_code_block_pattern(), content)
  end

  @doc """
  Verification gate — triggers when:
    1. iteration > 2 (agent has had multiple chances)
    2. Session has a task/goal context (user message contains action verbs)
    3. Zero tools were executed successfully in this session
  """
  def needs_verification_gate?(state) do
    state.iteration > 2 and
      has_task_context?(state.messages) and
      zero_successful_tools?(state.messages)
  end

  # Detect when a task involves code changes — triggers the explore-first directive.
  # Stored as {source, opts} — compiled at runtime (Elixir 1.18+ Reference escape).
  @coding_action_pattern_source {~S"\b(fix|change|update|refactor|add|implement|create|modify|edit|write|build|rewrite|delete|remove|rename)\b", "i"}
  @coding_context_pattern_source {~S"\b(function|method|module|file|code|script|class|endpoint|handler|component|route|controller|service|model|schema|migration|test|spec|bug|error|feature)\b", "i"}

  @doc "Returns true when the message describes a task involving code changes."
  def complex_coding_task?(message) when is_binary(message) do
    {action_src, action_opts} = @coding_action_pattern_source
    {context_src, context_opts} = @coding_context_pattern_source
    Regex.match?(Regex.compile!(action_src, action_opts), message) and
      Regex.match?(Regex.compile!(context_src, context_opts), message)
  end

  def complex_coding_task?(_), do: false

  # Detect when the model issued write/execute tools without any read tools first.
  # Triggered at iteration 1 (first tool batch) to catch blind writes.
  @write_tools ~w(file_write file_edit shell_execute)
  @read_tools ~w(file_read dir_list file_glob file_grep mcts_index)

  @doc "Returns true when tool_calls contains write tools but no read tools."
  def write_without_read?(tool_calls) do
    names = Enum.map(tool_calls, & &1.name)
    has_write = Enum.any?(names, &(&1 in @write_tools))
    has_read = Enum.any?(names, &(&1 in @read_tools))
    has_write and not has_read
  end

  # --- Private helpers ---

  defp has_task_context?(messages) do
    messages
    |> Enum.any?(fn
      %{role: "user", content: content} when is_binary(content) ->
        Regex.match?(~r/\b(fix|create|build|implement|add|update|change|write|deploy|test|debug|refactor|delete|remove|find|search|check|run|install|configure)\b/i, content)
      _ -> false
    end)
  end

  defp zero_successful_tools?(messages) do
    tool_messages =
      Enum.filter(messages, fn
        %{role: "tool", content: content} when is_binary(content) -> true
        _ -> false
      end)

    if tool_messages == [] do
      true
    else
      Enum.all?(tool_messages, fn %{content: content} ->
        String.starts_with?(content, "Error:") or
          String.starts_with?(content, "Blocked:")
      end)
    end
  end

  # Normalize user input before Tier 2 injection pattern matching.
  # Eliminates common Unicode obfuscation vectors without touching
  # the original string (Tier 1 always runs on raw input).
  #
  # Steps:
  #   1. Strip zero-width and invisible codepoints (U+200B, ZWNJ, BOM, etc.)
  #   2. Fold fullwidth ASCII (U+FF01–U+FF5E) to standard ASCII (U+0021–U+007E)
  #   3. Collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
  #   4. Lowercase
  defp compile_sources(sources) do
    Enum.map(sources, fn {pattern, opts} -> Regex.compile!(pattern, opts) end)
  end

  defp compiled_injection_patterns, do: compile_sources(@injection_pattern_sources)
  defp compiled_structural_patterns, do: compile_sources(@structural_pattern_sources)
  defp compiled_intent_patterns, do: compile_sources(@intent_pattern_sources)

  defp compiled_code_block_pattern do
    {src, opts} = @code_block_pattern_source
    Regex.compile!(src, opts)
  end

  defp normalize_for_injection_check(input) when is_binary(input) do
    input
    # Step 1: strip zero-width / invisible codepoints
    |> String.replace(
      ~r/[\x{200B}\x{200C}\x{200D}\x{200E}\x{200F}\x{FEFF}\x{00AD}\x{2028}\x{2029}]/u,
      ""
    )
    # Step 2: fold fullwidth ASCII (！…～, U+FF01–U+FF5E) → standard ASCII (!…~)
    |> String.graphemes()
    |> Enum.map(fn g ->
      case String.to_charlist(g) do
        [cp] when cp >= 0xFF01 and cp <= 0xFF5E -> <<cp - 0xFF01 + 0x21::utf8>>
        _ -> g
      end
    end)
    |> Enum.join()
    # Step 3: collapse common Cyrillic/Greek homoglyphs to ASCII equivalents
    |> String.replace("а", "a")
    |> String.replace("е", "e")
    |> String.replace("о", "o")
    |> String.replace("р", "p")
    |> String.replace("с", "c")
    |> String.replace("х", "x")
    |> String.replace("у", "y")
    |> String.replace("і", "i")
    |> String.replace("ѕ", "s")
    |> String.replace("ν", "v")
    |> String.replace("ο", "o")
    |> String.replace("ρ", "p")
    # Step 4: lowercase
    |> String.downcase()
  end
end
