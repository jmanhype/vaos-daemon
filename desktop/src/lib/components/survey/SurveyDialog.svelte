<!-- src/lib/components/survey/SurveyDialog.svelte -->
<!-- Floating glassmorphic survey questionnaire with slide transitions. -->
<script lang="ts">
  import { fly, fade } from 'svelte/transition';
  import { cubicOut, cubicInOut } from 'svelte/easing';
  import { tick } from 'svelte';
  import RadioCard from './RadioCard.svelte';
  import type { Survey, Answer } from '$lib/stores/survey.svelte';

  interface Props {
    survey: Survey;
    onComplete: (answers: Answer[]) => void;
    onDismiss: () => void;
  }

  let { survey, onComplete, onDismiss }: Props = $props();

  // ── State ────────────────────────────────────────────────────────────────────

  let currentIndex = $state(0);
  // Map of questionIndex → selected option id (or 'custom')
  let selectedOptions = $state<Map<number, string>>(new Map());
  // Map of questionIndex → custom text entered
  let customTexts = $state<Map<number, string>>(new Map());
  // Tracks which direction we're moving so fly transitions are correct
  let direction = $state<1 | -1>(1);
  // Controls the slide key so Svelte re-runs the fly transition on question change
  let slideKey = $state(0);
  // Focused option index within the current question's option list (for keyboard nav)
  let focusedOptionIndex = $state<number | null>(null);
  // Reference to the custom input element for programmatic focus
  let customInputEl = $state<HTMLInputElement | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────────────

  let totalQuestions = $derived(survey.questions.length);
  let currentQuestion = $derived(survey.questions[currentIndex]);
  let currentSelection = $derived(selectedOptions.get(currentIndex));
  let currentCustomText = $derived(customTexts.get(currentIndex) ?? '');
  let isLastQuestion = $derived(currentIndex === totalQuestions - 1);

  // Valid to advance: an option is selected OR custom text entered
  let canAdvance = $derived(
    currentSelection !== undefined ||
    (currentQuestion.skippable === true)
  );

  // Extended options list — options + optional custom entry at bottom
  let allOptions = $derived(
    currentQuestion.allowCustom
      ? [...currentQuestion.options, { id: 'custom', label: 'Type your own answer', description: undefined } as const]
      : currentQuestion.options
  );

  let isCustomSelected = $derived(currentSelection === 'custom');

  // ── Navigation ───────────────────────────────────────────────────────────────

  function goToNext() {
    if (!canAdvance) return;
    if (isLastQuestion) {
      finalize();
      return;
    }
    direction = 1;
    currentIndex += 1;
    slideKey += 1;
    focusedOptionIndex = null;
  }

  function finalize() {
    const answers: Answer[] = survey.questions.map((_q, i) => {
      const sel = selectedOptions.get(i);
      const custom = customTexts.get(i) ?? '';
      return {
        questionIndex: i,
        selectedOptionId: sel === 'custom' ? null : (sel ?? null),
        customText: sel === 'custom' ? custom : null,
      };
    });
    onComplete(answers);
  }

  // ── Option selection ─────────────────────────────────────────────────────────

  function selectOption(optionId: string) {
    const next = new Map(selectedOptions);
    next.set(currentIndex, optionId);
    selectedOptions = next;

    // Focus the custom text input after the DOM updates
    if (optionId === 'custom') {
      tick().then(() => customInputEl?.focus());
    }
  }

  function onCustomInput(e: Event) {
    const value = (e.target as HTMLInputElement).value;
    const next = new Map(customTexts);
    next.set(currentIndex, value);
    customTexts = next;
  }

  // ── Keyboard navigation ───────────────────────────────────────────────────────

  function handleKeydown(e: KeyboardEvent) {
    const optCount = allOptions.length;
    const currentFocus = focusedOptionIndex;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      focusedOptionIndex = currentFocus === null ? 0 : (currentFocus + 1) % optCount;
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      focusedOptionIndex = currentFocus === null
        ? optCount - 1
        : (currentFocus - 1 + optCount) % optCount;
    } else if (e.key === 'Enter' || e.key === ' ') {
      if (focusedOptionIndex !== null) {
        e.preventDefault();
        selectOption(allOptions[focusedOptionIndex].id);
      } else if (canAdvance) {
        e.preventDefault();
        goToNext();
      }
    } else if (e.key === 'Escape') {
      onDismiss();
    }
  }
</script>

<!-- Backdrop -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div
  class="sd-backdrop"
  role="presentation"
  transition:fade={{ duration: 200 }}
  onclick={(e) => { if (e.target === e.currentTarget) onDismiss(); }}
>
  <!-- Dialog card -->
  <div
    class="sd-card"
    role="dialog"
    aria-modal="true"
    aria-label="Survey — question {currentIndex + 1} of {totalQuestions}"
    tabindex="-1"
    onkeydown={handleKeydown}
  >
    <!-- Header: progress dashes + counter -->
    <header class="sd-header">
      <div class="sd-progress" aria-hidden="true">
        {#each survey.questions as _, i}
          <div
            class="sd-dash"
            class:sd-dash--active={i <= currentIndex}
          ></div>
        {/each}
      </div>
      <span class="sd-counter">{currentIndex + 1} of {totalQuestions} questions</span>
    </header>

    <!-- Animated question body -->
    <div class="sd-body" aria-live="polite">
      {#key slideKey}
        <div
          class="sd-question-wrap"
          in:fly={{ x: direction * 200, duration: 280, easing: cubicOut, delay: 60 }}
          out:fly={{ x: direction * -200, duration: 220, easing: cubicInOut }}
        >
          <!-- Question text -->
          <div class="sd-question-text">
            <h2 class="sd-question">{currentQuestion.text}</h2>
            {#if currentQuestion.subtitle}
              <p class="sd-question-sub">{currentQuestion.subtitle}</p>
            {:else}
              <p class="sd-question-sub">Select one answer</p>
            {/if}
          </div>

          <!-- Options -->
          <div
            class="sd-options"
            role="radiogroup"
            aria-label="Answer options"
          >
            {#each allOptions as option, i}
              {@const isCustomOption = option.id === 'custom'}

              {#if isCustomOption}
                <!-- Custom answer option -->
                <div class="sd-custom-wrap">
                  <RadioCard
                    label={option.label}
                    selected={currentSelection === 'custom'}
                    focused={focusedOptionIndex === i}
                    onSelect={() => selectOption('custom')}
                  />
                  {#if isCustomSelected}
                    <div
                      class="sd-custom-input-wrap"
                      in:fly={{ y: -6, duration: 180, easing: cubicOut }}
                    >
                      <input
                        bind:this={customInputEl}
                        class="sd-custom-input glass-input"
                        type="text"
                        placeholder="Describe in your own words…"
                        value={currentCustomText}
                        oninput={onCustomInput}
                        aria-label="Custom answer text"
                      />
                    </div>
                  {/if}
                </div>
              {:else}
                <RadioCard
                  label={option.label}
                  description={'description' in option ? option.description : undefined}
                  selected={currentSelection === option.id}
                  focused={focusedOptionIndex === i}
                  onSelect={() => selectOption(option.id)}
                />
              {/if}
            {/each}
          </div>
        </div>
      {/key}
    </div>

    <!-- Footer -->
    <footer class="sd-footer">
      <button
        class="sd-dismiss"
        onclick={onDismiss}
        aria-label="Dismiss survey"
      >
        Dismiss
      </button>

      <button
        class="sd-next"
        class:sd-next--disabled={!canAdvance}
        disabled={!canAdvance}
        onclick={goToNext}
        aria-label={isLastQuestion ? 'Complete survey' : 'Next question'}
      >
        {isLastQuestion ? 'Done' : 'Next'}
      </button>
    </footer>
  </div>
</div>

<style>
  /* ── Backdrop ──────────────────────────────────────────────────────────────── */

  .sd-backdrop {
    position: fixed;
    inset: 0;
    z-index: var(--z-modal-backdrop, 300);
    display: flex;
    align-items: center;
    justify-content: center;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(6px);
    -webkit-backdrop-filter: blur(6px);
  }

  /* ── Card ──────────────────────────────────────────────────────────────────── */

  .sd-card {
    position: relative;
    width: 100%;
    max-width: 480px;
    padding: 24px;
    background: rgba(22, 22, 24, 0.88);
    backdrop-filter: blur(32px) saturate(1.6);
    -webkit-backdrop-filter: blur(32px) saturate(1.6);
    border: 1px solid rgba(255, 255, 255, 0.09);
    border-radius: 20px;
    box-shadow:
      0 24px 64px rgba(0, 0, 0, 0.5),
      0 8px 24px rgba(0, 0, 0, 0.3),
      inset 0 1px 0 rgba(255, 255, 255, 0.08);
    outline: none;
    overflow: hidden;
  }

  /* ── Header ────────────────────────────────────────────────────────────────── */

  .sd-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 24px;
  }

  .sd-progress {
    display: flex;
    align-items: center;
    gap: 4px;
  }

  .sd-dash {
    width: 24px;
    height: 3px;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.15);
    transition: background 0.25s ease;
  }

  .sd-dash--active {
    background: #ffffff;
  }

  .sd-counter {
    font-size: 12px;
    font-weight: 500;
    color: #666666;
    letter-spacing: 0.01em;
  }

  /* ── Body ──────────────────────────────────────────────────────────────────── */

  .sd-body {
    /* Reserve space so the card height stays stable during transition */
    position: relative;
    overflow: hidden;
  }

  .sd-question-wrap {
    display: flex;
    flex-direction: column;
    gap: 16px;
  }

  .sd-question-text {
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .sd-question {
    font-size: 18px;
    font-weight: 700;
    color: #ffffff;
    line-height: 1.3;
    letter-spacing: -0.02em;
  }

  .sd-question-sub {
    font-size: 13px;
    color: #666666;
  }

  /* ── Options ───────────────────────────────────────────────────────────────── */

  .sd-options {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  /* ── Custom input ──────────────────────────────────────────────────────────── */

  .sd-custom-wrap {
    display: flex;
    flex-direction: column;
    gap: 6px;
  }

  .sd-custom-input-wrap {
    padding: 0 4px;
  }

  .sd-custom-input {
    /* Inherit .glass-input from app.css */
    font-size: 14px;
  }

  /* ── Footer ────────────────────────────────────────────────────────────────── */

  .sd-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-top: 24px;
    padding-top: 20px;
    border-top: 1px solid rgba(255, 255, 255, 0.06);
  }

  .sd-dismiss {
    font-size: 13px;
    font-weight: 500;
    color: #888888;
    background: none;
    border: none;
    cursor: pointer;
    padding: 0;
    text-decoration: underline;
    text-underline-offset: 2px;
    transition: color 0.15s ease;
  }

  .sd-dismiss:hover {
    color: #ffffff;
  }

  .sd-dismiss:focus-visible {
    outline: 2px solid var(--accent-primary, #3b82f6);
    outline-offset: 3px;
    border-radius: 2px;
  }

  .sd-next {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    padding: 8px 20px;
    background: #ffffff;
    color: #0a0a0a;
    font-size: 13px;
    font-weight: 600;
    border-radius: 9999px;
    border: none;
    cursor: pointer;
    transition: background 0.15s ease, opacity 0.15s ease, transform 0.1s ease;
  }

  .sd-next:hover:not(:disabled) {
    background: #e8e8e8;
  }

  .sd-next:active:not(:disabled) {
    transform: scale(0.97);
  }

  .sd-next:focus-visible {
    outline: 2px solid rgba(255, 255, 255, 0.5);
    outline-offset: 2px;
  }

  .sd-next--disabled,
  .sd-next:disabled {
    opacity: 0.28;
    cursor: not-allowed;
  }

  /* ── Reduced motion ────────────────────────────────────────────────────────── */

  @media (prefers-reduced-motion: reduce) {
    .sd-card,
    .sd-dash,
    .sd-dismiss,
    .sd-next {
      transition: none;
    }
  }
</style>
