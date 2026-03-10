<script lang="ts">
  import '../app.css';
  import { onMount } from 'svelte';
  import { initializeAuth } from '$lib/api/client';

  let { children } = $props();

  onMount(() => {
    void initializeAuth();
  });
</script>

<svelte:head>
  <title>OSA</title>
  <meta name="description" content="OSA — Optimal System Agent desktop app" />
</svelte:head>

{@render children()}
