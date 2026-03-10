<script lang="ts">
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { fly } from 'svelte/transition';
  import { cubicOut, cubicIn } from 'svelte/easing';
  import type { Provider, OnboardingStep, DetectionResult } from '$lib/onboarding/types';
  import { detectLocalProviders } from '$lib/onboarding/detection';
  import { completeOnboarding, getDefaultWorkingDirectory } from '$lib/onboarding/store';
  import StepProvider from './steps/StepProvider.svelte';
  import StepApiKey from './steps/StepApiKey.svelte';
  import StepDirectory from './steps/StepDirectory.svelte';
  import StepComplete from './steps/StepComplete.svelte';

  // ── State ────────────────────────────────────────────────────────────
  let step = $state<OnboardingStep>(1);
  let direction = $state<1 | -1>(1);
  let provider = $state<Provider | null>(null);
  let detectedProviders = $state<DetectionResult>({ ollama: false, lmstudio: false });
  let detecting = $state(true);
  let apiKey = $state('');
  let workingDirectory = $state('');
  let containerRef = $state<HTMLElement | null>(null);

  // ── Derived ──────────────────────────────────────────────────────────
  let isLocalProvider = $derived(provider === 'ollama' || provider === 'lmstudio');
  let visualStep = $derived(step === 'complete' ? 3 : step === 1 ? 1 : step === 2 ? 2 : 3);

  // ── Lifecycle ────────────────────────────────────────────────────────
  onMount(async () => {
    const [detected, defaultDir] = await Promise.all([
      detectLocalProviders(),
      getDefaultWorkingDirectory(),
    ]);

    detectedProviders = detected;
    workingDirectory = defaultDir;
    detecting = false;

    // Auto-select first detected local provider
    if (detected.ollama) provider = 'ollama';
    else if (detected.lmstudio) provider = 'lmstudio';
  });

  // Focus first interactive element after transitions
  $effect(() => {
    step; // reactive dependency — intentional read to track step changes
    if (!containerRef) return;
    const prefersReduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    const delay = prefersReduced ? 0 : 220;
    const t = setTimeout(() => {
      const first = containerRef?.querySelector<HTMLElement>(
        'button:not([disabled]), input, [href]'
      );
      first?.focus();
    }, delay);
    return () => clearTimeout(t);
  });

  // ── Navigation ───────────────────────────────────────────────────────
  function next() {
    direction = 1;
    if (step === 1) {
      step = isLocalProvider ? 3 : 2;
    } else if (step === 2) {
      step = 3;
    } else if (step === 3) {
      step = 'complete';
      void finalize();
    }
  }

  function back() {
    direction = -1;
    if (step === 3) {
      step = isLocalProvider ? 1 : 2;
    } else if (step === 2) {
      step = 1;
    }
  }

  async function finalize() {
    if (!provider) return;
    await completeOnboarding({ provider, workingDirectory, apiKey });
    // StepComplete handles auto-redirect after 1800ms
  }

  function handleKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape' && step !== 1 && step !== 'complete') {
      back();
    }
  }

  // Fly params — zero duration if reduced motion
  function flyIn() {
    const reduced = typeof window !== 'undefined'
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false;
    return reduced ? { duration: 0 } : { x: direction * 28, duration: 200, easing: cubicOut };
  }

  function flyOut() {
    const reduced = typeof window !== 'undefined'
      ? window.matchMedia('(prefers-reduced-motion: reduce)').matches
      : false;
    return reduced ? { duration: 0 } : { x: direction * -28, duration: 160, easing: cubicIn };
  }
</script>

<svelte:window onkeydown={handleKeydown} />

<div class="ob-root dark" bind:this={containerRef}>
  <!-- Ambient background glow -->
  <div class="ob-ambient" aria-hidden="true"></div>

  <div class="ob-frame ob-glass">
    <!-- Header -->
    <header class="ob-header">
      <div class="ob-logo" aria-label="OSA">
        <div class="ob-logo-mark"></div>
        <span class="ob-logo-name">OSA</span>
      </div>
    </header>

    <!-- Step content with fly transition -->
    <main class="ob-content" id="ob-main" tabindex="-1">
      {#key step}
        <div
          in:fly={flyIn()}
          out:fly={flyOut()}
          class="ob-step"
        >
          {#if step === 1}
            <StepProvider
              {provider}
              {detectedProviders}
              {detecting}
              onSelect={(p) => { provider = p; }}
              onNext={next}
            />
          {:else if step === 2}
            <StepApiKey
              {provider}
              bind:apiKey
              onNext={next}
              onBack={back}
            />
          {:else if step === 3}
            <StepDirectory
              bind:workingDirectory
              onNext={next}
              onBack={back}
            />
          {:else if step === 'complete'}
            <StepComplete onDone={() => goto('/')} />
          {/if}
        </div>
      {/key}
    </main>

    <!-- Progress dots -->
    {#if step !== 'complete'}
      <footer class="ob-footer">
        <div
          class="ob-dots"
          role="progressbar"
          aria-label="Setup progress"
          aria-valuenow={visualStep}
          aria-valuemin={1}
          aria-valuemax={3}
        >
          {#each [1, 2, 3] as dot}
            <div class="ob-dot" class:ob-dot--active={visualStep === dot} class:ob-dot--done={visualStep > dot}></div>
          {/each}
        </div>
      </footer>
    {/if}
  </div>
</div>

<style>
  .ob-root {
    position: fixed;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #0a0a0a;
    overflow: hidden;
  }

  /* Ambient gradient glow in the background */
  .ob-ambient {
    position: absolute;
    inset: 0;
    background:
      radial-gradient(ellipse 60% 40% at 30% 60%, rgba(59, 130, 246, 0.04) 0%, transparent 70%),
      radial-gradient(ellipse 50% 50% at 70% 30%, rgba(124, 58, 237, 0.04) 0%, transparent 70%);
    pointer-events: none;
  }

  /* Main glass frame */
  .ob-frame {
    position: relative;
    width: 100%;
    max-width: 520px;
    min-height: 480px;
    display: flex;
    flex-direction: column;
    z-index: 1;
  }

  .ob-glass {
    background: rgba(255, 255, 255, 0.03);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: 20px;
    box-shadow: 0 8px 40px rgba(0, 0, 0, 0.5);
  }

  .ob-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 28px 0;
  }

  .ob-logo {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ob-logo-mark {
    width: 24px;
    height: 24px;
    border-radius: 7px;
    background: linear-gradient(135deg, #3b82f6 0%, #6d28d9 100%);
  }

  .ob-logo-name {
    font-size: 14px;
    font-weight: 700;
    color: #ffffff;
    letter-spacing: 0.04em;
  }

  .ob-content {
    flex: 1;
    position: relative;
    overflow: hidden;
    padding: 32px 28px 24px;
  }

  .ob-content:focus {
    outline: none;
  }

  .ob-step {
    position: absolute;
    inset: 32px 28px 24px;
    display: flex;
    flex-direction: column;
  }

  .ob-footer {
    padding: 0 28px 24px;
    display: flex;
    justify-content: center;
  }

  .ob-dots {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .ob-dot {
    width: 6px;
    height: 6px;
    border-radius: 9999px;
    background: rgba(255, 255, 255, 0.15);
    transition: all 0.25s ease;
  }

  .ob-dot--active {
    width: 20px;
    background: rgba(255, 255, 255, 0.7);
  }

  .ob-dot--done {
    background: rgba(255, 255, 255, 0.35);
  }
</style>
