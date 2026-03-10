<script lang="ts">
  import type { TaskStatus } from '$lib/stores/tasks.svelte';

  interface Props {
    status: TaskStatus;
    size?: number;
  }

  let { status, size = 18 }: Props = $props();

  const isCompleted = $derived(status === 'completed');
  const isActive = $derived(status === 'active');
  const isFailed = $derived(status === 'failed');
</script>

<span
  class="checkbox"
  class:checkbox--completed={isCompleted}
  class:checkbox--active={isActive}
  class:checkbox--failed={isFailed}
  style="width: {size}px; height: {size}px;"
  aria-hidden="true"
>
  {#if isCompleted}
    <!-- Green check with SVG stroke-dasharray draw animation -->
    <svg
      viewBox="0 0 18 18"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      class="checkbox__svg checkbox__svg--check"
    >
      <circle cx="9" cy="9" r="8.25" stroke="var(--accent-success)" stroke-width="1.5" />
      <polyline
        points="4.5,9 7.5,12 13.5,6"
        stroke="var(--accent-success)"
        stroke-width="1.75"
        stroke-linecap="round"
        stroke-linejoin="round"
        class="check-path"
      />
    </svg>
  {:else if isFailed}
    <!-- Red X -->
    <svg
      viewBox="0 0 18 18"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      class="checkbox__svg"
    >
      <circle cx="9" cy="9" r="8.25" stroke="var(--accent-error)" stroke-width="1.5" />
      <line x1="6" y1="6" x2="12" y2="12" stroke="var(--accent-error)" stroke-width="1.75" stroke-linecap="round" />
      <line x1="12" y1="6" x2="6" y2="12" stroke="var(--accent-error)" stroke-width="1.75" stroke-linecap="round" />
    </svg>
  {:else if isActive}
    <!-- Blue pulsing dot -->
    <svg
      viewBox="0 0 18 18"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      class="checkbox__svg"
    >
      <circle cx="9" cy="9" r="8.25" stroke="var(--accent-primary)" stroke-width="1.5" />
      <circle cx="9" cy="9" r="3.5" fill="var(--accent-primary)" class="active-dot" />
    </svg>
  {:else}
    <!-- Pending: empty circle -->
    <svg
      viewBox="0 0 18 18"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      class="checkbox__svg"
    >
      <circle cx="9" cy="9" r="8.25" stroke="rgba(255,255,255,0.2)" stroke-width="1.5" />
    </svg>
  {/if}
</span>

<style>
  .checkbox {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
    position: relative;
  }

  .checkbox__svg {
    width: 100%;
    height: 100%;
    display: block;
    overflow: visible;
  }

  /* Scale-bounce on completion */
  .checkbox--completed .checkbox__svg {
    animation: check-bounce 0.35s cubic-bezier(0.34, 1.56, 0.64, 1) both;
  }

  @keyframes check-bounce {
    0%   { transform: scale(0.6); opacity: 0; }
    60%  { transform: scale(1.15); }
    100% { transform: scale(1); opacity: 1; }
  }

  /* Check-mark draw animation via stroke-dasharray */
  .check-path {
    /* polyline perimeter ≈ 10.6px */
    stroke-dasharray: 11;
    stroke-dashoffset: 11;
    animation: draw-check 0.28s 0.08s ease-out forwards;
  }

  @keyframes draw-check {
    to { stroke-dashoffset: 0; }
  }

  /* Pulsing blue dot for active tasks */
  .active-dot {
    animation: pulse-dot 1.8s ease-in-out infinite;
  }

  @keyframes pulse-dot {
    0%, 100% { opacity: 1;   transform-origin: center; transform: scale(1); }
    50%       { opacity: 0.5; transform-origin: center; transform: scale(0.75); }
  }

  /* Completion state: green ring glow */
  .checkbox--completed {
    filter: drop-shadow(0 0 4px rgba(34, 197, 94, 0.35));
  }

  /* Active state: blue ring glow */
  .checkbox--active {
    filter: drop-shadow(0 0 4px rgba(59, 130, 246, 0.4));
  }

  /* Failed state: red ring glow */
  .checkbox--failed {
    filter: drop-shadow(0 0 4px rgba(239, 68, 68, 0.35));
  }
</style>
