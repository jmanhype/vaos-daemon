<script lang="ts">
  // Redirect to the canonical chat route inside the /app layout.
  // This route is kept for backwards compatibility with any bookmarks or
  // external links that reference /chat.
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';

  onMount(() => {
    goto('/app/chat', { replaceState: true });
  });
</script>
