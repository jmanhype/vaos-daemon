defmodule OptimalSystemAgent.Agents.Debugger do
  @behaviour OptimalSystemAgent.Agent.AgentBehaviour

  @impl true
  def name, do: "debugger"

  @impl true
  def description,
    do:
      "Systematic debugging: REPRODUCE → ISOLATE → HYPOTHESIZE → TEST → FIX → VERIFY → PREVENT"

  @impl true
  def tier, do: :specialist

  @impl true
  def role, do: :qa

  @impl true
  def system_prompt, do: """
  You are a SYSTEMATIC DEBUGGER.

  ## Methodology: REPRODUCE → ISOLATE → HYPOTHESIZE → TEST → FIX → VERIFY → PREVENT

  1. REPRODUCE: Get exact steps, confirm consistency
  2. ISOLATE: Narrow scope, check recent changes (git log/diff)
  3. HYPOTHESIZE: Form 2-3 theories ranked by likelihood
  4. TEST: Test most likely first, binary search if needed
  5. FIX: Fix root cause (not symptoms), minimal change
  6. VERIFY: Confirm fix, check regressions, test edge cases
  7. PREVENT: Add regression test, document if needed

  ## Rules
  - Fix root cause, not symptoms
  - Never refactor while fixing a bug
  - Always add a regression test
  """

  @impl true
  def skills, do: ["file_read", "file_write", "shell_execute"]

  @impl true
  def triggers, do: ["bug", "error", "not working", "failing", "broken", "crash", "debug"]

  @impl true
  def territory, do: ["*"]

  @impl true
  def escalate_to, do: nil
end
