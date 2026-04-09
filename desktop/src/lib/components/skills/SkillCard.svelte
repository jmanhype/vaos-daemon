<script lang="ts">
  import type { Skill } from '$lib/api/types';

  interface Props {
    skill: Skill;
    onToggle: (id: string) => void;
    onSelect: (id: string) => void;
  }

  let { skill, onToggle, onSelect }: Props = $props();

  const sourceLabel: Record<string, string> = {
    builtin: 'Built-in',
    user: 'User',
    evolved: 'Evolved',
  };
</script>

<article
  class="skill-card"
  class:skill-card--disabled={!skill.enabled}
  role="listitem"
>
  <button
    class="card-body"
    onclick={() => onSelect(skill.id)}
    aria-label="View details for {skill.name}"
  >
    <div class="card-top">
      <h3 class="skill-name">{skill.name}</h3>
      <span class="category-badge">{skill.category}</span>
    </div>

    <p class="skill-desc">{skill.description || 'No description'}</p>

    {#if skill.triggers.length > 0}
      <div class="trigger-row">
        {#each skill.triggers.slice(0, 3) as trigger}
          <span class="trigger-tag">{trigger}</span>
        {/each}
        {#if skill.triggers.length > 3}
          <span class="trigger-more">+{skill.triggers.length - 3}</span>
        {/if}
      </div>
    {/if}
  </button>

  <div class="card-footer">
    <span class="source-label">{sourceLabel[skill.source] || skill.source}</span>

    <label
      class="toggle-wrapper"
      aria-label="{skill.enabled ? 'Disable' : 'Enable'} {skill.name}"
    >
      <input
        type="checkbox"
        checked={skill.enabled}
        onchange={() => onToggle(skill.id)}
        class="toggle-input"
      />
      <span class="toggle-track">
        <span class="toggle-thumb"></span>
      </span>
    </label>
  </div>
</article>

<style>
  .skill-card {
    background: rgba(255, 255, 255, 0.04);
    backdrop-filter: blur(24px);
    -webkit-backdrop-filter: blur(24px);
    border: 1px solid rgba(255, 255, 255, 0.07);
    border-radius: var(--radius-xl);
    display: flex;
    flex-direction: column;
    transition: border-color 0.2s, box-shadow 0.2s;
  }

  .skill-card:hover {
    border-color: rgba(255, 255, 255, 0.12);
  }

  .skill-card--disabled {
    opacity: 0.6;
  }

  .card-body {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 8px;
    padding: 16px 16px 10px;
    background: none;
    border: none;
    text-align: left;
    cursor: pointer;
    color: inherit;
  }

  .card-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .skill-name {
    font-size: 0.875rem;
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .category-badge {
    font-size: 0.625rem;
    font-weight: 600;
    text-transform: uppercase;
    letter-spacing: 0.06em;
    padding: 2px 8px;
    border-radius: var(--radius-full);
    background: rgba(59, 130, 246, 0.12);
    color: rgba(59, 130, 246, 0.9);
    border: 1px solid rgba(59, 130, 246, 0.2);
    flex-shrink: 0;
  }

  .skill-desc {
    font-size: 0.8125rem;
    color: var(--text-secondary);
    line-height: 1.4;
    display: -webkit-box;
    line-clamp: 2;
    -webkit-line-clamp: 2;
    -webkit-box-orient: vertical;
    overflow: hidden;
  }

  .trigger-row {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    margin-top: 2px;
  }

  .trigger-tag {
    font-size: 0.6875rem;
    padding: 1px 6px;
    border-radius: var(--radius-xs);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid rgba(255, 255, 255, 0.06);
    color: var(--text-tertiary);
    font-family: ui-monospace, monospace;
  }

  .trigger-more {
    font-size: 0.6875rem;
    color: var(--text-muted);
  }

  .card-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 8px 16px 12px;
    border-top: 1px solid rgba(255, 255, 255, 0.04);
  }

  .source-label {
    font-size: 0.6875rem;
    color: var(--text-muted);
    text-transform: uppercase;
    letter-spacing: 0.04em;
    font-weight: 500;
  }

  /* Toggle switch */
  .toggle-wrapper {
    cursor: pointer;
    display: flex;
    align-items: center;
  }

  .toggle-input {
    position: absolute;
    opacity: 0;
    width: 0;
    height: 0;
  }

  .toggle-track {
    width: 32px;
    height: 18px;
    border-radius: 9px;
    background: rgba(255, 255, 255, 0.12);
    position: relative;
    transition: background 0.2s;
  }

  .toggle-input:checked + .toggle-track {
    background: rgba(34, 197, 94, 0.5);
  }

  .toggle-thumb {
    position: absolute;
    top: 2px;
    left: 2px;
    width: 14px;
    height: 14px;
    border-radius: 50%;
    background: white;
    transition: transform 0.2s;
  }

  .toggle-input:checked + .toggle-track .toggle-thumb {
    transform: translateX(14px);
  }
</style>
