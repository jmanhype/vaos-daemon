<script lang="ts">
  interface Props {
    /** When true, renders as a wider block-level cursor (first token in empty message) */
    standalone?: boolean;
  }

  let { standalone = false }: Props = $props();
</script>

{#if standalone}
  <span class="cursor cursor--standalone" aria-hidden="true"></span>
{:else}
  <span class="cursor" aria-hidden="true"></span>
{/if}

<style>
  .cursor {
    display: inline-block;
    width: 2px;
    height: 1em;
    margin-left: 2px;
    vertical-align: text-bottom;
    background: rgba(255, 255, 255, 0.7);
    border-radius: 1px;
    animation: blink 0.9s step-end infinite;
  }

  .cursor--standalone {
    width: 8px;
    height: 1.1em;
  }

  @keyframes blink {
    0%,
    100% {
      opacity: 1;
    }
    50% {
      opacity: 0;
    }
  }
</style>
