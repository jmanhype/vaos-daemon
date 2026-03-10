<script lang="ts">
  import { browser } from '$app/environment';
  import { isMacOS } from '$lib/utils/platform';

  interface Props {
    title?: string;
  }

  let { title = 'OSA' }: Props = $props();

  const onMac = $derived(browser && isMacOS());

  // macOS traffic lights occupy the left ~72px.
  // On non-macOS platforms the bar has full content from left edge.
  const trafficLightOffset = $derived(onMac ? '72px' : '16px');
</script>

<div
  class="titlebar"
  data-tauri-drag-region
  style="-webkit-app-region: drag;"
>
  <!-- Left padding: reserves space for macOS traffic lights on mac,
       or sits at normal left edge on Windows/Linux. -->
  <div class="titlebar-left" style:width={trafficLightOffset}></div>

  <!-- Center title — non-interactive so drag passthrough works -->
  <div class="titlebar-center" aria-label="Window title">
    <span class="titlebar-title">{title}</span>
  </div>

  <!-- Right slot — reserved for future window controls on Windows/Linux -->
  <div class="titlebar-right"></div>
</div>

<style>
  .titlebar {
    position: absolute;
    top: 0;
    left: 0;
    right: 0;
    height: 44px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    /* Transparent — lets sidebar and content backgrounds show through */
    background: transparent;
    z-index: var(--z-fixed);
    /* Drag passthrough: Tauri handles drag via data-tauri-drag-region.
       pointer-events: none lets clicks reach sidebar toggle and nav links below. */
    pointer-events: none;
  }

  .titlebar-left {
    flex-shrink: 0;
    height: 100%;
  }

  .titlebar-center {
    flex: 1;
    display: flex;
    align-items: center;
    justify-content: center;
  }

  .titlebar-title {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-tertiary);
    letter-spacing: 0.02em;
    /* Prevent text from interfering with drag */
    pointer-events: none;
    user-select: none;
  }

  .titlebar-right {
    width: 72px;
    flex-shrink: 0;
  }
</style>
