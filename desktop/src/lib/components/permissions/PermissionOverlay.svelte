<script lang="ts">
  import { fade } from 'svelte/transition';
  import { cubicOut } from 'svelte/easing';
  import { permissionStore } from '$lib/stores/permissions.svelte';
  import PermissionDialog from './PermissionDialog.svelte';
</script>

{#if permissionStore.hasPending && permissionStore.current}
  {@const req = permissionStore.current}

  <!-- Backdrop -->
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div
    class="po-backdrop"
    aria-hidden="true"
    onclick={() => permissionStore.deny()}
    transition:fade={{ duration: 180, easing: cubicOut }}
  ></div>

  <!-- Dialog wrapper — prevents backdrop click from reaching dialog -->
  <div
    class="po-stage"
    role="presentation"
    transition:fade={{ duration: 180, easing: cubicOut }}
  >
    <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
    <div
      class="po-dialog-wrap"
      onclick={(e) => e.stopPropagation()}
    >
      <PermissionDialog
        tool={req.tool}
        description={req.description}
        paths={req.paths}
        onAllow={() => permissionStore.allow()}
        onAllowAlways={() => permissionStore.allowAlways()}
        onDeny={() => permissionStore.deny()}
      />
    </div>
  </div>
{/if}

<style>
  .po-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, 0.55);
    backdrop-filter: blur(4px);
    -webkit-backdrop-filter: blur(4px);
    z-index: var(--z-modal-backdrop, 300);
    cursor: default;
  }

  .po-stage {
    position: fixed;
    inset: 0;
    z-index: var(--z-modal, 400);
    display: flex;
    align-items: center;
    justify-content: center;
    /* Vertical offset — slightly above center feels more intentional */
    padding-bottom: 5vh;
    pointer-events: none;
  }

  .po-dialog-wrap {
    pointer-events: all;
    /* Additional drop shadow to lift dialog off the backdrop */
    filter: drop-shadow(0 32px 80px rgba(0, 0, 0, 0.5));
  }
</style>
