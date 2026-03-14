<script lang="ts">
  import { onMount } from 'svelte';
  import { skillsStore } from '$lib/stores/skills.svelte';
  import SkillsGrid from '$lib/components/skills/SkillsGrid.svelte';
  import SkillDetail from '$lib/components/skills/SkillDetail.svelte';

  let selectedSkillId = $state<string | null>(null);

  onMount(() => {
    skillsStore.fetchSkills();
  });

  function handleToggle(id: string) {
    skillsStore.toggle(id);
  }

  function handleBulkAction(action: 'enable' | 'disable') {
    const ids = skillsStore.filtered.map((s) => s.id);
    if (ids.length === 0) return;
    if (action === 'enable') skillsStore.bulkEnable(ids);
    else skillsStore.bulkDisable(ids);
  }

  let searchInput = $state('');
  let searchTimer: ReturnType<typeof setTimeout> | null = null;

  function handleSearch(value: string) {
    searchInput = value;
    if (searchTimer) clearTimeout(searchTimer);
    searchTimer = setTimeout(() => skillsStore.setSearch(value), 150);
  }
</script>

<div class="skills-page">
  <header class="page-header">
    <div class="header-left">
      <h1 class="page-title">Skills</h1>
      <div class="stats-bar" role="status" aria-label="Skills statistics">
        <span class="stat-value">{skillsStore.enabledCount}</span>
        <span class="stat-label">enabled</span>
        <span class="stat-divider" aria-hidden="true"></span>
        <span class="stat-value">{skillsStore.totalCount}</span>
        <span class="stat-label">total</span>
        {#if skillsStore.loading}
          <span class="loading-spinner" aria-label="Loading"></span>
        {/if}
      </div>
    </div>

    <div class="header-actions">
      <div class="search-wrapper">
        <svg class="search-icon" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" aria-hidden="true">
          <circle cx="11" cy="11" r="8" />
          <line x1="21" y1="21" x2="16.65" y2="16.65" />
        </svg>
        <input
          type="search"
          class="search-input"
          placeholder="Search skills..."
          value={searchInput}
          oninput={(e) => handleSearch(e.currentTarget.value)}
          aria-label="Search skills"
        />
      </div>

      <div class="bulk-actions">
        <button
          class="bulk-btn"
          onclick={() => handleBulkAction('enable')}
          aria-label="Enable all visible skills"
        >
          Enable visible
        </button>
        <button
          class="bulk-btn bulk-btn--muted"
          onclick={() => handleBulkAction('disable')}
          aria-label="Disable all visible skills"
        >
          Disable visible
        </button>
      </div>
    </div>
  </header>

  <div class="category-tabs" role="tablist" aria-label="Skill categories">
    {#each skillsStore.allCategories as cat (cat.name)}
      <button
        class="tab"
        class:tab--active={skillsStore.activeCategory === cat.name}
        onclick={() => skillsStore.setCategory(cat.name)}
        role="tab"
        aria-selected={skillsStore.activeCategory === cat.name}
      >
        {cat.label}
        <span class="tab-count">{cat.count}</span>
      </button>
    {/each}
  </div>

  <main class="page-content">
    {#if skillsStore.error}
      <div class="status-banner" role="status">
        <span class="banner-dot"></span>
        <span class="banner-text">Failed to load skills</span>
        <button class="banner-btn" onclick={() => skillsStore.fetchSkills()}>
          Retry
        </button>
      </div>
    {/if}

    <SkillsGrid
      skills={skillsStore.filtered}
      onToggle={handleToggle}
      onSelect={(id) => { selectedSkillId = id; }}
    />
  </main>
</div>

{#if selectedSkillId}
  <SkillDetail
    skillId={selectedSkillId}
    onClose={() => { selectedSkillId = null; }}
    onToggle={(id) => { handleToggle(id); }}
  />
{/if}

<style>
  .skills-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    overflow: hidden;
    background: var(--bg-secondary);
  }

  .page-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 20px 24px 16px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.05);
    flex-shrink: 0;
    gap: 16px;
    flex-wrap: wrap;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  .page-title {
    font-size: 1.125rem;
    font-weight: 600;
    color: var(--text-primary);
    letter-spacing: -0.01em;
  }

  .stats-bar {
    display: flex;
    align-items: center;
    gap: 6px;
    background: rgba(255, 255, 255, 0.04);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-full);
    padding: 4px 12px;
  }

  .stat-value {
    font-size: 0.8125rem;
    font-weight: 600;
    color: var(--text-primary);
    font-variant-numeric: tabular-nums;
  }

  .stat-label {
    font-size: 0.6875rem;
    color: var(--text-tertiary);
    text-transform: uppercase;
    letter-spacing: 0.05em;
  }

  .stat-divider {
    width: 1px;
    height: 12px;
    background: rgba(255, 255, 255, 0.08);
    margin: 0 4px;
  }

  .loading-spinner {
    width: 12px;
    height: 12px;
    border: 1.5px solid rgba(255, 255, 255, 0.1);
    border-top-color: rgba(255, 255, 255, 0.5);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
    margin-left: 4px;
  }

  @keyframes spin {
    to { transform: rotate(360deg); }
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 12px;
  }

  .search-wrapper {
    position: relative;
    display: flex;
    align-items: center;
  }

  .search-icon {
    position: absolute;
    left: 10px;
    color: var(--text-muted);
    pointer-events: none;
  }

  .search-input {
    width: 220px;
    padding: 6px 10px 6px 32px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.08);
    background: rgba(255, 255, 255, 0.04);
    color: var(--text-primary);
    font-size: 0.8125rem;
    outline: none;
    transition: border-color 0.15s;
  }

  .search-input::placeholder {
    color: var(--text-muted);
  }

  .search-input:focus {
    border-color: var(--border-focus);
  }

  .bulk-actions {
    display: flex;
    gap: 6px;
  }

  .bulk-btn {
    padding: 5px 12px;
    border-radius: var(--radius-sm);
    border: 1px solid rgba(255, 255, 255, 0.1);
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
    font-size: 0.75rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
  }

  .bulk-btn:hover {
    background: rgba(255, 255, 255, 0.1);
    color: var(--text-primary);
  }

  .bulk-btn--muted {
    color: var(--text-tertiary);
    border-color: rgba(255, 255, 255, 0.06);
  }

  .category-tabs {
    display: flex;
    gap: 2px;
    padding: 8px 24px;
    border-bottom: 1px solid rgba(255, 255, 255, 0.04);
    overflow-x: auto;
    scrollbar-width: none;
    flex-shrink: 0;
  }

  .category-tabs::-webkit-scrollbar {
    display: none;
  }

  .tab {
    display: flex;
    align-items: center;
    gap: 6px;
    padding: 6px 14px;
    border-radius: var(--radius-sm);
    border: none;
    background: none;
    color: var(--text-tertiary);
    font-size: 0.8125rem;
    font-weight: 500;
    cursor: pointer;
    transition: all 0.15s;
    white-space: nowrap;
  }

  .tab:hover {
    background: rgba(255, 255, 255, 0.05);
    color: var(--text-secondary);
  }

  .tab--active {
    background: rgba(59, 130, 246, 0.1);
    color: var(--text-primary);
  }

  .tab-count {
    font-size: 0.6875rem;
    font-variant-numeric: tabular-nums;
    color: var(--text-muted);
    min-width: 14px;
    text-align: center;
  }

  .tab--active .tab-count {
    color: var(--accent-primary);
  }

  .page-content {
    flex: 1;
    overflow-y: auto;
    padding: 20px 24px 24px;
    scrollbar-width: thin;
    scrollbar-color: rgba(255, 255, 255, 0.08) transparent;
  }

  .status-banner {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 16px;
    background: rgba(255, 255, 255, 0.03);
    border: 1px solid rgba(255, 255, 255, 0.06);
    border-radius: var(--radius-md);
    font-size: 0.7rem;
    color: var(--text-tertiary);
    margin-bottom: 16px;
  }

  .banner-dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: rgba(251, 191, 36, 0.6);
    flex-shrink: 0;
  }

  .banner-text {
    color: var(--text-secondary);
  }

  .banner-btn {
    margin-left: auto;
    padding: 3px 10px;
    background: rgba(255, 255, 255, 0.07);
    border: 1px solid rgba(255, 255, 255, 0.12);
    border-radius: var(--radius-full);
    color: rgba(255, 255, 255, 0.7);
    font-size: 0.65rem;
    font-weight: 500;
    cursor: pointer;
    transition: background 0.15s;
  }

  .banner-btn:hover {
    background: rgba(255, 255, 255, 0.12);
    color: var(--text-primary);
  }
</style>
