<script lang="ts">
  // src/lib/components/tasks/ScheduledTaskForm.svelte
  // Inline form for creating or editing a scheduled (cron) task.
  // Distinct from the SSE-driven task tracking in TaskCard.svelte.

  import type { ScheduledTask, CreateScheduledTaskPayload } from '$lib/stores/scheduledTasks.svelte';

  interface Props {
    /** When provided the form is in edit mode; omit for create mode. */
    task?: ScheduledTask | null;
    onSubmit: (payload: CreateScheduledTaskPayload) => void;
    onCancel: () => void;
  }

  let { task = null, onSubmit, onCancel }: Props = $props();

  // ── Cron presets ──────────────────────────────────────────────────────────────

  const PRESETS = [
    { label: 'Every minute',   value: '* * * * *'     },
    { label: 'Every 5 minutes', value: '*/5 * * * *'  },
    { label: 'Every hour',     value: '0 * * * *'     },
    { label: 'Every 6 hours',  value: '0 */6 * * *'   },
    { label: 'Daily at 9 AM',  value: '0 9 * * *'     },
    { label: 'Weekly Monday',  value: '0 9 * * 1'     },
    { label: 'Monthly 1st',    value: '0 9 1 * *'     },
  ] as const;

  // ── Form state ────────────────────────────────────────────────────────────────

  let name        = $state(task?.name ?? '');
  let description = $state(task?.description ?? '');
  let schedule    = $state(task?.schedule ?? '');
  let taskContent = $state('');

  // ── Validation ────────────────────────────────────────────────────────────────

  function isValidCron(expr: string): boolean {
    const trimmed = expr.trim();
    const parts = trimmed.split(/\s+/);
    return parts.length === 5;
  }

  let errors = $state<{ name?: string; schedule?: string; task?: string }>({});

  function validate(): boolean {
    const next: typeof errors = {};
    if (!name.trim()) {
      next.name = 'Name is required.';
    }
    if (!schedule.trim()) {
      next.schedule = 'Schedule is required.';
    } else if (!isValidCron(schedule)) {
      next.schedule = 'Must be a valid cron expression (5 space-separated parts).';
    }
    if (!taskContent.trim()) {
      next.task = 'Command is required.';
    }
    errors = next;
    return Object.keys(next).length === 0;
  }

  function handlePreset(value: string) {
    schedule = value;
    if (errors.schedule) {
      errors = { ...errors, schedule: undefined };
    }
  }

  function handleSubmit(e: Event) {
    e.preventDefault();
    if (!validate()) return;
    onSubmit({
      name: name.trim(),
      description: description.trim() || undefined,
      schedule: schedule.trim(),
      task: taskContent.trim(),
    });
  }

  const isEditing = $derived(task !== null);
</script>

<form
  class="stask-form"
  onsubmit={handleSubmit}
  novalidate
  aria-label="{isEditing ? 'Edit' : 'New'} scheduled task"
>
  <div class="stask-form-header">
    <h2 class="stask-form-title">{isEditing ? 'Edit task' : 'New scheduled task'}</h2>
    <button
      type="button"
      class="stask-form-close"
      onclick={onCancel}
      aria-label="Cancel and close form"
    >
      <svg width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" aria-hidden="true">
        <line x1="1.5" y1="1.5" x2="8.5" y2="8.5"/>
        <line x1="8.5" y1="1.5" x2="1.5" y2="8.5"/>
      </svg>
    </button>
  </div>

  <div class="stask-form-body">
    <!-- Name -->
    <div class="stask-field" class:stask-field--error={!!errors.name}>
      <label class="stask-label" for="stask-name">
        Name <span class="stask-required" aria-hidden="true">*</span>
      </label>
      <input
        id="stask-name"
        class="stask-input"
        type="text"
        bind:value={name}
        placeholder="Daily digest"
        autocomplete="off"
        aria-required="true"
        aria-describedby={errors.name ? 'stask-name-err' : undefined}
        oninput={() => { if (errors.name) errors = { ...errors, name: undefined }; }}
      />
      {#if errors.name}
        <span id="stask-name-err" class="stask-error-msg" role="alert">{errors.name}</span>
      {/if}
    </div>

    <!-- Description -->
    <div class="stask-field">
      <label class="stask-label" for="stask-description">Description</label>
      <input
        id="stask-description"
        class="stask-input"
        type="text"
        bind:value={description}
        placeholder="What does this job do?"
        autocomplete="off"
      />
    </div>

    <!-- Schedule -->
    <div class="stask-field" class:stask-field--error={!!errors.schedule}>
      <label class="stask-label" for="stask-schedule">
        Schedule <span class="stask-required" aria-hidden="true">*</span>
      </label>
      <div class="stask-schedule-row">
        <input
          id="stask-schedule"
          class="stask-input stask-input--mono"
          type="text"
          bind:value={schedule}
          placeholder="0 9 * * 1-5"
          autocomplete="off"
          spellcheck="false"
          aria-required="true"
          aria-describedby={errors.schedule ? 'stask-schedule-err' : 'stask-schedule-hint'}
          oninput={() => { if (errors.schedule) errors = { ...errors, schedule: undefined }; }}
        />
        <div class="stask-presets" role="group" aria-label="Cron presets">
          <select
            class="stask-select"
            onchange={(e) => {
              const el = e.currentTarget as HTMLSelectElement;
              if (el.value) handlePreset(el.value);
              el.value = '';
            }}
            aria-label="Select a preset schedule"
          >
            <option value="">Preset</option>
            {#each PRESETS as preset}
              <option value={preset.value}>{preset.label}</option>
            {/each}
          </select>
        </div>
      </div>
      {#if errors.schedule}
        <span id="stask-schedule-err" class="stask-error-msg" role="alert">{errors.schedule}</span>
      {:else}
        <span id="stask-schedule-hint" class="stask-hint">
          5 parts: minute hour day-of-month month day-of-week
        </span>
      {/if}
    </div>

    <!-- Command -->
    <div class="stask-field" class:stask-field--error={!!errors.task}>
      <label class="stask-label" for="stask-command">
        Command <span class="stask-required" aria-hidden="true">*</span>
      </label>
      <textarea
        id="stask-command"
        class="stask-textarea"
        bind:value={taskContent}
        placeholder="osa run digest --format=markdown"
        rows={3}
        spellcheck="false"
        aria-required="true"
        aria-describedby={errors.task ? 'stask-command-err' : undefined}
        oninput={() => { if (errors.task) errors = { ...errors, task: undefined }; }}
      ></textarea>
      {#if errors.task}
        <span id="stask-command-err" class="stask-error-msg" role="alert">{errors.task}</span>
      {/if}
    </div>
  </div>

  <!-- Actions -->
  <div class="stask-form-footer">
    <button type="button" class="stask-btn-cancel" onclick={onCancel}>
      Cancel
    </button>
    <button type="submit" class="stask-btn-submit">
      {isEditing ? 'Save changes' : 'Create task'}
    </button>
  </div>
</form>

<style>
  /* ── Form shell ── */

  .stask-form {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.08);
    border-radius: var(--radius-md);
    overflow: hidden;
    display: flex;
    flex-direction: column;
  }

  /* ── Form header ── */

  .stask-form-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 14px 16px 12px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
  }

  .stask-form-title {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
  }

  .stask-form-close {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border-radius: var(--radius-xs);
    background: none;
    border: none;
    color: var(--text-tertiary);
    transition: color 0.15s, background 0.15s;
  }

  .stask-form-close:hover {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
  }

  /* ── Form body ── */

  .stask-form-body {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 16px;
  }

  /* ── Field ── */

  .stask-field {
    display: flex;
    flex-direction: column;
    gap: 5px;
  }

  .stask-label {
    font-size: 0.75rem;
    font-weight: 500;
    color: var(--text-secondary);
    letter-spacing: 0.01em;
  }

  .stask-required {
    color: var(--accent-error);
    margin-left: 2px;
  }

  /* ── Inputs ── */

  .stask-input {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    font-size: 0.8125rem;
    color: var(--text-primary);
    outline: none;
    transition: border-color 0.15s, box-shadow 0.15s;
    width: 100%;
  }

  .stask-input::placeholder {
    color: var(--text-muted);
  }

  .stask-input:focus {
    border-color: var(--border-focus);
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.04);
  }

  .stask-input--mono {
    font-family: var(--font-mono);
    font-size: 0.75rem;
    letter-spacing: 0.02em;
  }

  .stask-field--error .stask-input,
  .stask-field--error .stask-textarea {
    border-color: rgba(239, 68, 68, 0.4);
  }

  .stask-field--error .stask-input:focus,
  .stask-field--error .stask-textarea:focus {
    border-color: rgba(239, 68, 68, 0.6);
    box-shadow: 0 0 0 3px rgba(239, 68, 68, 0.06);
  }

  /* ── Textarea ── */

  .stask-textarea {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm);
    padding: 8px 12px;
    font-size: 0.75rem;
    font-family: var(--font-mono);
    letter-spacing: 0.02em;
    color: var(--text-primary);
    outline: none;
    transition: border-color 0.15s, box-shadow 0.15s;
    resize: vertical;
    width: 100%;
    line-height: 1.55;
  }

  .stask-textarea::placeholder {
    color: var(--text-muted);
    font-family: var(--font-mono);
  }

  .stask-textarea:focus {
    border-color: var(--border-focus);
    box-shadow: 0 0 0 3px rgba(255, 255, 255, 0.04);
  }

  /* ── Schedule row ── */

  .stask-schedule-row {
    display: flex;
    gap: 8px;
    align-items: center;
  }

  .stask-schedule-row .stask-input {
    flex: 1;
  }

  .stask-presets {
    flex-shrink: 0;
  }

  .stask-select {
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: var(--radius-sm);
    padding: 7px 10px;
    font-size: 0.75rem;
    font-family: var(--font-sans);
    color: var(--text-secondary);
    outline: none;
    cursor: pointer;
    transition: border-color 0.15s;
    appearance: none;
    -webkit-appearance: none;
  }

  .stask-select:focus {
    border-color: var(--border-focus);
  }

  /* ── Hint and error messages ── */

  .stask-hint {
    font-size: 0.7rem;
    color: var(--text-muted);
  }

  .stask-error-msg {
    font-size: 0.7rem;
    color: rgba(239, 68, 68, 0.85);
  }

  /* ── Footer buttons ── */

  .stask-form-footer {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: 8px;
    padding: 12px 16px;
    border-top: 1px solid rgba(255, 255, 255, 0.05);
  }

  .stask-btn-cancel {
    padding: 7px 16px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.09);
    color: var(--text-secondary);
    font-size: 0.8125rem;
    font-weight: 500;
    transition: background 0.15s, border-color 0.15s, color 0.15s;
  }

  .stask-btn-cancel:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: var(--border-hover);
    color: var(--text-primary);
  }

  .stask-btn-submit {
    padding: 7px 18px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.12);
    border: 1px solid rgba(255, 255, 255, 0.16);
    color: var(--text-primary);
    font-size: 0.8125rem;
    font-weight: 600;
    transition: background 0.15s, border-color 0.15s;
  }

  .stask-btn-submit:hover {
    background: rgba(255, 255, 255, 0.18);
    border-color: rgba(255, 255, 255, 0.24);
  }

  .stask-btn-submit:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }
</style>
