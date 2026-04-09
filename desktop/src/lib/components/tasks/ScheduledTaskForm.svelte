<script lang="ts">
  import type { ScheduledTask, CreateScheduledTaskPayload } from '$lib/stores/scheduledTasks.svelte';
  import { scheduledTasksStore } from '$lib/stores/scheduledTasks.svelte';
  import type { CronPreset } from '$lib/api/types';

  interface Props {
    task?: ScheduledTask | null;
    onSubmit: (payload: CreateScheduledTaskPayload) => void;
    onCancel: () => void;
  }

  let { task = null, onSubmit, onCancel }: Props = $props();

  // ── Cron description ────────────────────────────────────────────────────────

  const CRON_DESCRIPTIONS: Record<string, string> = {
    '* * * * *':     'Every minute',
    '*/5 * * * *':   'Every 5 minutes',
    '*/15 * * * *':  'Every 15 minutes',
    '*/30 * * * *':  'Every 30 minutes',
    '0 * * * *':     'Every hour',
    '0 9 * * *':     'Daily at 9:00 AM',
    '0 9 * * 1':     'Weekly on Monday at 9:00 AM',
    '0 9 1 * *':     'Monthly on the 1st at 9:00 AM',
  };

  function describeCron(expr: string): string {
    return CRON_DESCRIPTIONS[expr.trim()] ?? '';
  }

  // ── Presets ─────────────────────────────────────────────────────────────────

  const DEFAULT_PRESETS: CronPreset[] = [
    { id: '1m',      cron: '* * * * *',     label: 'Every minute' },
    { id: '5m',      cron: '*/5 * * * *',   label: 'Every 5 min' },
    { id: '15m',     cron: '*/15 * * * *',  label: 'Every 15 min' },
    { id: '30m',     cron: '*/30 * * * *',  label: 'Every 30 min' },
    { id: '1h',      cron: '0 * * * *',     label: 'Hourly' },
    { id: 'daily',   cron: '0 9 * * *',     label: 'Daily 9 AM' },
    { id: 'weekly',  cron: '0 9 * * 1',     label: 'Weekly Mon' },
    { id: 'monthly', cron: '0 9 1 * *',     label: 'Monthly 1st' },
  ];

  const presets = $derived(
    scheduledTasksStore.presets.length > 0
      ? scheduledTasksStore.presets
      : DEFAULT_PRESETS
  );

  // ── Form state ──────────────────────────────────────────────────────────────

  let name = $state('');
  let description = $state('');
  let schedule = $state('');
  let taskContent = $state('');
  let timeoutMinutes = $state(5);
  let useCustomCron = $state(false);
  let syncedTaskId = $state<string | null>(null);

  const cronDescription = $derived(describeCron(schedule));
  const selectedPresetId = $derived(
    presets.find((p) => p.cron === schedule.trim())?.id ?? null
  );

  // ── Validation ──────────────────────────────────────────────────────────────

  function isValidCron(expr: string): boolean {
    return expr.trim().split(/\s+/).length === 5;
  }

  let errors = $state<{ name?: string; schedule?: string; task?: string }>({});

  $effect(() => {
    const currentTask = task;
    const currentTaskId = currentTask?.id ?? null;

    if (syncedTaskId === currentTaskId) {
      return;
    }

    syncedTaskId = currentTaskId;
    name = currentTask?.name ?? '';
    description = currentTask?.description ?? '';
    schedule = currentTask?.schedule ?? '';
    taskContent = '';
    timeoutMinutes = 5;
    useCustomCron = currentTask
      ? !presets.some((preset) => preset.cron === currentTask.schedule.trim())
      : false;
    errors = {};
  });

  function validate(): boolean {
    const next: typeof errors = {};
    if (!name.trim()) next.name = 'Name is required.';
    if (!schedule.trim()) {
      next.schedule = 'Schedule is required.';
    } else if (!isValidCron(schedule)) {
      next.schedule = 'Must be a valid cron expression (5 parts).';
    }
    if (!taskContent.trim()) next.task = 'Command is required.';
    errors = next;
    return Object.keys(next).length === 0;
  }

  function selectPreset(cron: string) {
    schedule = cron;
    useCustomCron = false;
    if (errors.schedule) errors = { ...errors, schedule: undefined };
  }

  function handleSubmit(e: Event) {
    e.preventDefault();
    if (!validate()) return;
    onSubmit({
      name: name.trim(),
      description: description.trim() || undefined,
      schedule: schedule.trim(),
      task: taskContent.trim(),
      timeout_minutes: timeoutMinutes,
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
      <span class="stask-label" id="stask-schedule-label">
        Schedule <span class="stask-required" aria-hidden="true">*</span>
      </span>

      <!-- Preset grid -->
      <div
        class="stask-preset-grid"
        role="radiogroup"
        aria-labelledby="stask-schedule-label"
      >
        {#each presets as preset}
          <button
            type="button"
            class="stask-preset"
            class:stask-preset--selected={selectedPresetId === preset.id && !useCustomCron}
            role="radio"
            aria-checked={selectedPresetId === preset.id && !useCustomCron}
            onclick={() => selectPreset(preset.cron)}
          >
            {preset.label}
          </button>
        {/each}
      </div>

      <!-- Custom toggle -->
      <button
        type="button"
        class="stask-custom-toggle"
        class:stask-custom-toggle--active={useCustomCron}
        onclick={() => { useCustomCron = !useCustomCron; }}
      >
        Custom expression
      </button>

      {#if useCustomCron}
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
      {/if}

      <!-- Human-readable preview -->
      {#if schedule && cronDescription}
        <span class="stask-cron-preview">{cronDescription}</span>
      {:else if schedule && !cronDescription}
        <span class="stask-cron-preview stask-cron-preview--custom">{schedule}</span>
      {/if}

      {#if errors.schedule}
        <span id="stask-schedule-err" class="stask-error-msg" role="alert">{errors.schedule}</span>
      {:else if useCustomCron}
        <span id="stask-schedule-hint" class="stask-hint">
          5 parts: minute hour day-of-month month day-of-week
        </span>
      {/if}
    </div>

    <!-- Timeout -->
    <div class="stask-field">
      <label class="stask-label" for="stask-timeout">Timeout (minutes)</label>
      <input
        id="stask-timeout"
        class="stask-input stask-input--narrow"
        type="number"
        bind:value={timeoutMinutes}
        min={1}
        max={30}
      />
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

  .stask-form-body {
    display: flex;
    flex-direction: column;
    gap: 14px;
    padding: 16px;
  }

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

  .stask-input--narrow {
    max-width: 100px;
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

  /* ── Preset grid ── */

  .stask-preset-grid {
    display: grid;
    grid-template-columns: repeat(4, 1fr);
    gap: 6px;
  }

  .stask-preset {
    padding: 6px 8px;
    border-radius: var(--radius-sm);
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.08);
    color: var(--text-tertiary);
    font-size: 0.6875rem;
    font-weight: 500;
    transition: all 0.15s;
    text-align: center;
    white-space: nowrap;
  }

  .stask-preset:hover {
    background: rgba(255, 255, 255, 0.08);
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.14);
  }

  .stask-preset--selected {
    background: rgba(34, 197, 94, 0.1);
    border-color: rgba(34, 197, 94, 0.3);
    color: rgba(34, 197, 94, 0.9);
  }

  .stask-preset--selected:hover {
    background: rgba(34, 197, 94, 0.15);
    color: rgba(34, 197, 94, 1);
  }

  /* ── Custom toggle ── */

  .stask-custom-toggle {
    align-self: flex-start;
    padding: 4px 10px;
    border-radius: var(--radius-sm);
    background: none;
    border: 1px solid rgba(255, 255, 255, 0.06);
    color: var(--text-muted);
    font-size: 0.6875rem;
    transition: all 0.15s;
  }

  .stask-custom-toggle:hover {
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.12);
  }

  .stask-custom-toggle--active {
    background: rgba(255, 255, 255, 0.06);
    color: var(--text-secondary);
    border-color: rgba(255, 255, 255, 0.14);
  }

  /* ── Cron preview ── */

  .stask-cron-preview {
    font-size: 0.7rem;
    color: rgba(34, 197, 94, 0.7);
    font-weight: 500;
  }

  .stask-cron-preview--custom {
    font-family: var(--font-mono);
    color: var(--text-muted);
  }

  .stask-hint {
    font-size: 0.7rem;
    color: var(--text-muted);
  }

  .stask-error-msg {
    font-size: 0.7rem;
    color: rgba(239, 68, 68, 0.85);
  }

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

  @media (max-width: 480px) {
    .stask-preset-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }
</style>
