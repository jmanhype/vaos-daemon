<!-- src/lib/components/survey/RadioCard.svelte -->
<!-- A single selectable radio option card for the survey questionnaire. -->
<script lang="ts">
  interface Props {
    label: string;
    description?: string;
    selected: boolean;
    focused?: boolean;
    onSelect: () => void;
  }

  let { label, description, selected, focused = false, onSelect }: Props = $props();
</script>

<button
  class="rc-card"
  class:rc-card--selected={selected}
  class:rc-card--focused={focused}
  role="radio"
  aria-checked={selected}
  aria-label={label}
  onclick={onSelect}
>
  <!-- Radio circle -->
  <div class="rc-radio" class:rc-radio--on={selected} aria-hidden="true">
    {#if selected}
      <div class="rc-radio-dot"></div>
    {/if}
  </div>

  <!-- Text content -->
  <div class="rc-body">
    <span class="rc-label">{label}</span>
    {#if description}
      <span class="rc-description">{description}</span>
    {/if}
  </div>
</button>

<style>
  .rc-card {
    display: flex;
    align-items: center;
    gap: 12px;
    width: 100%;
    padding: 14px 16px;
    border-radius: 12px;
    text-align: left;
    cursor: pointer;
    color: inherit;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    transition: border-color 0.15s ease, background 0.15s ease, box-shadow 0.15s ease;
  }

  .rc-card:hover {
    background: rgba(255, 255, 255, 0.05);
    border-color: rgba(255, 255, 255, 0.10);
  }

  .rc-card--selected {
    background: rgba(59, 130, 246, 0.08);
    border-color: rgba(59, 130, 246, 0.30);
  }

  .rc-card--selected:hover {
    background: rgba(59, 130, 246, 0.11);
    border-color: rgba(59, 130, 246, 0.38);
  }

  /* Keyboard-focus highlight (driven by parent, not :focus-visible, so arrow keys work) */
  .rc-card--focused {
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.45);
  }

  .rc-card:focus-visible {
    outline: none;
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.45);
  }

  .rc-card:active {
    transform: scale(0.995);
  }

  /* Radio circle — 18px outer */
  .rc-radio {
    flex-shrink: 0;
    width: 18px;
    height: 18px;
    border-radius: 9999px;
    border: 2px solid rgba(255, 255, 255, 0.18);
    display: flex;
    align-items: center;
    justify-content: center;
    transition: border-color 0.15s ease, background 0.15s ease;
  }

  .rc-radio--on {
    border-color: #3b82f6;
    background: rgba(59, 130, 246, 0.15);
  }

  /* Inner dot — 10px when selected */
  .rc-radio-dot {
    width: 10px;
    height: 10px;
    border-radius: 9999px;
    background: #3b82f6;
  }

  .rc-body {
    display: flex;
    flex-direction: column;
    gap: 2px;
    min-width: 0;
  }

  .rc-label {
    font-size: 14px;
    font-weight: 600;
    color: #ffffff;
    line-height: 1.3;
  }

  .rc-description {
    font-size: 13px;
    color: #888888;
    line-height: 1.4;
  }
</style>
