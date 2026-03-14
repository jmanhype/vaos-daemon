<script lang="ts">
  import type { Skill } from '$lib/api/types';
  import SkillCard from './SkillCard.svelte';

  interface Props {
    skills: Skill[];
    onToggle: (id: string) => void;
    onSelect: (id: string) => void;
  }

  let { skills, onToggle, onSelect }: Props = $props();
</script>

{#if skills.length === 0}
  <div class="empty-state" role="status">
    <div class="empty-icon" aria-hidden="true">
      <svg width="48" height="48" viewBox="0 0 48 48" fill="none">
        <path
          d="M24 8L30 14H42V40H6V8H24Z"
          stroke="currentColor"
          stroke-width="1.5"
          fill="none"
          opacity="0.3"
        />
        <circle cx="24" cy="28" r="4" stroke="currentColor" stroke-width="1.5" fill="none" opacity="0.2" />
      </svg>
    </div>
    <p class="empty-title">No skills found</p>
    <p class="empty-subtitle">Try adjusting your search or category filter.</p>
  </div>
{:else}
  <div class="skills-grid" role="list" aria-label="Skills list">
    {#each skills as skill (skill.id)}
      <SkillCard {skill} {onToggle} {onSelect} />
    {/each}
  </div>
{/if}

<style>
  .skills-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }

  @media (max-width: 1024px) {
    .skills-grid {
      grid-template-columns: repeat(2, 1fr);
    }
  }

  @media (max-width: 640px) {
    .skills-grid {
      grid-template-columns: 1fr;
    }
  }

  .empty-state {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    min-height: 280px;
    gap: 12px;
    color: var(--text-tertiary);
    text-align: center;
    padding: 48px 32px;
  }

  .empty-icon {
    color: rgba(255, 255, 255, 0.12);
    margin-bottom: 4px;
  }

  .empty-title {
    font-size: 0.9375rem;
    font-weight: 500;
    color: var(--text-secondary);
  }

  .empty-subtitle {
    font-size: 0.8125rem;
    color: var(--text-tertiary);
    max-width: 280px;
    line-height: 1.5;
  }
</style>
