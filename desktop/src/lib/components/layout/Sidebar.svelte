<script lang="ts">
  import { page } from '$app/stores';
  import { browser } from '$app/environment';
  import { fly, fade } from 'svelte/transition';
  import { isTauri, isMacOS } from '$lib/utils/platform';

  interface NavItem {
    id: string;
    label: string;
    href: string;
    shortcut: string;
    icon: string;
  }

  interface Props {
    isCollapsed?: boolean;
    onToggle?: () => void;
    user?: { name: string; email: string; avatarUrl?: string } | null;
  }

  let {
    isCollapsed = $bindable(false),
    onToggle,
    user = null,
  }: Props = $props();

  const NAV_ITEMS: NavItem[] = [
    {
      id: 'chat',
      label: 'Chat',
      href: '/app',
      shortcut: '⌘1',
      icon: 'M8.625 12a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H8.25m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H12m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0h-.375M21 12c0 4.556-4.03 8.25-9 8.25a9.764 9.764 0 01-2.555-.337A5.972 5.972 0 015.41 20.97a5.969 5.969 0 01-.474-.065 4.48 4.48 0 00.978-2.025c.09-.457-.133-.901-.467-1.226C3.93 16.178 3 14.189 3 12c0-4.556 4.03-8.25 9-8.25s9 3.694 9 8.25z',
    },
    {
      id: 'agents',
      label: 'Agents',
      href: '/app/agents',
      shortcut: '⌘2',
      icon: 'M8.25 3v1.5M4.5 8.25H3m18 0h-1.5M4.5 12H3m18 0h-1.5m-15 3.75H3m18 0h-1.5M8.25 19.5V21M12 3v1.5m0 15V21m3.75-18v1.5m0 15V21m-9-1.5h10.5a2.25 2.25 0 002.25-2.25V6.75a2.25 2.25 0 00-2.25-2.25H6.75A2.25 2.25 0 004.5 6.75v10.5a2.25 2.25 0 002.25 2.25zm.75-12h9v9h-9v-9z',
    },
    {
      id: 'models',
      label: 'Models',
      href: '/app/models',
      shortcut: '⌘3',
      icon: 'M9.813 15.904L9 18.75l-.813-2.846a4.5 4.5 0 00-3.09-3.09L2.25 12l2.846-.813a4.5 4.5 0 003.09-3.09L9 5.25l.813 2.846a4.5 4.5 0 003.09 3.09L15.75 12l-2.846.813a4.5 4.5 0 00-3.09 3.09zM18.259 8.715L18 9.75l-.259-1.035a3.375 3.375 0 00-2.455-2.456L14.25 6l1.036-.259a3.375 3.375 0 002.455-2.456L18 2.25l.259 1.035a3.375 3.375 0 002.456 2.456L21.75 6l-1.035.259a3.375 3.375 0 00-2.456 2.456zM16.894 20.567L16.5 21.75l-.394-1.183a2.25 2.25 0 00-1.423-1.423L13.5 18.75l1.183-.394a2.25 2.25 0 001.423-1.423l.394-1.183.394 1.183a2.25 2.25 0 001.423 1.423l1.183.394-1.183.394a2.25 2.25 0 00-1.423 1.423z',
    },
    {
      id: 'terminal',
      label: 'Terminal',
      href: '/app/terminal',
      shortcut: '⌘4',
      icon: 'M6.75 7.5l3 2.25-3 2.25m4.5 0h3m-9 8.25h13.5A2.25 2.25 0 0021 18V6a2.25 2.25 0 00-2.25-2.25H5.25A2.25 2.25 0 003 6v12a2.25 2.25 0 002.25 2.25z',
    },
    {
      id: 'connectors',
      label: 'Connectors',
      href: '/app/connectors',
      shortcut: '⌘5',
      icon: 'M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.86-2.556a4.5 4.5 0 00-6.364-6.364L4.5 8.25l4.5 4.5 4.19-4.062z',
    },
    {
      id: 'settings',
      label: 'Settings',
      href: '/app/settings',
      shortcut: '⌘6',
      icon: 'M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.324.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 011.37.49l1.296 2.247a1.125 1.125 0 01-.26 1.431l-1.003.827c-.293.24-.438.613-.431.992a6.759 6.759 0 010 .255c-.007.378.138.75.43.99l1.005.828c.424.35.534.954.26 1.43l-1.298 2.247a1.125 1.125 0 01-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.57 6.57 0 01-.22.128c-.331.183-.581.495-.644.869l-.213 1.28c-.09.543-.56.941-1.11.941h-2.594c-.55 0-1.02-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 01-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 01-1.369-.49l-1.297-2.247a1.125 1.125 0 01.26-1.431l1.004-.827c.292-.24.437-.613.43-.992a6.932 6.932 0 010-.255c.007-.378-.138-.75-.43-.99l-1.004-.828a1.125 1.125 0 01-.26-1.43l1.297-2.247a1.125 1.125 0 011.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.087.22-.128.332-.183.582-.495.644-.869l.214-1.281z M15 12a3 3 0 11-6 0 3 3 0 016 0z',
    },
  ];

  // Platform state — only truthy in browser+Tauri+macOS
  const isDesktop = $derived(browser && isTauri());
  const onMac = $derived(browser && isMacOS());
  const trafficLightSpace = $derived(isDesktop && onMac);

  // Tooltip state for collapsed mode
  let tooltipVisible = $state<string | null>(null);
  let tooltipY = $state(0);

  function handleNavMouseEnter(id: string, event: MouseEvent) {
    if (!isCollapsed) return;
    tooltipVisible = id;
    const rect = (event.currentTarget as HTMLElement).getBoundingClientRect();
    tooltipY = rect.top + rect.height / 2;
  }

  function handleNavMouseLeave() {
    tooltipVisible = null;
  }

  function isActive(href: string): boolean {
    if (href === '/app') {
      return $page.url.pathname === '/app' || $page.url.pathname === '/app/';
    }
    return $page.url.pathname === href || $page.url.pathname.startsWith(href + '/');
  }

  const userInitials = $derived(
    user?.name
      ? user.name
          .split(' ')
          .map((w) => w[0])
          .slice(0, 2)
          .join('')
          .toUpperCase()
      : 'U'
  );
</script>

<aside
  class="sidebar"
  style:width={isCollapsed ? 'var(--sidebar-collapsed-width)' : 'var(--sidebar-expanded-width)'}
  aria-label="Main navigation"
>
  <!-- macOS traffic light spacer — draggable zone -->
  {#if trafficLightSpace}
    <div
      class="traffic-light-zone"
      style="-webkit-app-region: drag;"
    >
      <!-- Traffic light spacer only — no text -->
    </div>
  {:else}
    <div class="spacer-top"></div>
  {/if}

  <!-- Toggle collapse/expand -->
  <div class="toggle-row" class:centered={isCollapsed}>
    <button
      onclick={onToggle}
      aria-label={isCollapsed ? 'Expand sidebar' : 'Collapse sidebar'}
      aria-keyshortcuts="Meta+Backslash"
      class="toggle-btn"
      style="-webkit-app-region: no-drag;"
    >
      <svg
        class="toggle-icon"
        class:rotated={isCollapsed}
        fill="none"
        stroke="currentColor"
        viewBox="0 0 24 24"
        aria-hidden="true"
        width="16"
        height="16"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke-width="1.5"
          d="M11 19l-7-7 7-7m8 14l-7-7 7-7"
        />
      </svg>
    </button>
  </div>

  <!-- Divider -->
  <div class="divider"></div>

  <!-- Navigation -->
  <nav class="nav" aria-label="Main">
    {#each NAV_ITEMS as item (item.id)}
      <a
        href={item.href}
        data-active={isActive(item.href) ? '' : undefined}
        class="nav-item"
        aria-current={isActive(item.href) ? 'page' : undefined}
        onmouseenter={(e) => handleNavMouseEnter(item.id, e)}
        onmouseleave={handleNavMouseLeave}
      >
        <svg
          class="nav-icon"
          fill="none"
          stroke="currentColor"
          viewBox="0 0 24 24"
          aria-hidden="true"
          width="18"
          height="18"
        >
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d={item.icon} />
        </svg>
        {#if !isCollapsed}
          <span class="nav-label" transition:fade={{ duration: 150 }}>
            {item.label}
          </span>
          <span class="nav-shortcut" aria-hidden="true">{item.shortcut}</span>
        {/if}
      </a>
    {/each}
  </nav>

  <!-- Bottom divider -->
  <div class="divider" style="margin-top: auto; margin-bottom: 8px;"></div>

  <!-- User avatar / profile -->
  <div class="user-section">
    <button
      class="user-btn"
      class:centered={isCollapsed}
      aria-label="User menu"
      aria-haspopup="menu"
    >
      {#if user?.avatarUrl}
        <img
          src={user.avatarUrl}
          alt={user.name}
          class="avatar-img"
        />
      {:else}
        <div class="avatar-initials" aria-hidden="true">
          {userInitials}
        </div>
      {/if}
      {#if !isCollapsed && user}
        <div class="user-info" transition:fade={{ duration: 150 }}>
          <p class="user-name">{user.name}</p>
          <p class="user-email">{user.email}</p>
        </div>
      {/if}
    </button>
  </div>

  <!-- Tooltip portal (collapsed mode only) -->
  {#if isCollapsed && tooltipVisible}
    {@const item = NAV_ITEMS.find((n) => n.id === tooltipVisible)}
    {#if item}
      <div
        class="nav-tooltip"
        style:top="{tooltipY}px"
        transition:fly={{ x: -8, duration: 100 }}
        role="tooltip"
      >
        <span>{item.label}</span>
        <kbd class="tooltip-shortcut">{item.shortcut}</kbd>
      </div>
    {/if}
  {/if}
</aside>

<style>
  .sidebar {
    height: 100%;
    display: flex;
    flex-direction: column;
    flex-shrink: 0;
    background: rgba(10, 10, 10, 0.85);
    backdrop-filter: blur(20px);
    -webkit-backdrop-filter: blur(20px);
    border-right: 1px solid var(--border-default);
    transition: var(--sidebar-transition);
    overflow: hidden;
    position: relative;
    z-index: 20;
  }

  /* macOS traffic light zone */
  .traffic-light-zone {
    height: 72px;
    flex-shrink: 0;
    display: flex;
    align-items: flex-end;
    justify-content: center;
    padding-bottom: 8px;
  }

  .spacer-top {
    height: 16px;
    flex-shrink: 0;
  }

  /* Toggle button row */
  .toggle-row {
    padding: 0 8px 12px;
    display: flex;
    justify-content: flex-end;
  }

  .toggle-row.centered {
    justify-content: center;
  }

  .toggle-btn {
    width: 28px;
    height: 28px;
    display: flex;
    align-items: center;
    justify-content: center;
    border-radius: 6px;
    color: var(--text-tertiary);
    background: transparent;
    border: none;
    cursor: pointer;
    transition: background var(--transition-fast), color var(--transition-fast);
  }

  .toggle-btn:hover {
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }

  .toggle-icon {
    transition: transform 300ms cubic-bezier(0.4, 0, 0.2, 1);
  }

  .toggle-icon.rotated {
    transform: rotate(180deg);
  }

  /* Dividers */
  .divider {
    margin: 0 8px 8px;
    height: 1px;
    background: var(--border-default);
    flex-shrink: 0;
  }

  /* Navigation */
  .nav {
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 2px;
    padding: 0 8px;
    overflow-y: auto;
    overflow-x: hidden;
  }

  .nav-item {
    position: relative;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px 10px;
    border-radius: var(--radius-sm);
    color: var(--text-tertiary);
    text-decoration: none;
    font-size: 13px;
    font-weight: 500;
    transition: background var(--transition-fast), color var(--transition-fast);
    white-space: nowrap;
    overflow: hidden;
  }

  .nav-item:hover {
    background: var(--bg-elevated);
    color: var(--text-secondary);
  }

  /* Active state — left glow border */
  .nav-item[data-active] {
    color: var(--text-primary);
    background: rgba(59, 130, 246, 0.08);
  }

  .nav-item[data-active]::before {
    content: '';
    position: absolute;
    left: 0;
    top: 50%;
    transform: translateY(-50%);
    width: 2px;
    height: 60%;
    background: var(--accent-primary);
    border-radius: 0 2px 2px 0;
    box-shadow: 0 0 8px rgba(59, 130, 246, 0.5);
  }

  .nav-icon {
    flex-shrink: 0;
  }

  .nav-label {
    flex: 1;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .nav-shortcut {
    font-size: 10px;
    color: var(--text-muted);
    font-family: ui-monospace, monospace;
    margin-left: auto;
    opacity: 0.7;
    flex-shrink: 0;
  }

  /* User section */
  .user-section {
    padding: 0 8px 8px;
    flex-shrink: 0;
  }

  .user-btn {
    width: 100%;
    display: flex;
    align-items: center;
    gap: 10px;
    padding: 8px;
    border-radius: var(--radius-sm);
    background: transparent;
    border: none;
    cursor: pointer;
    transition: background var(--transition-fast);
    overflow: hidden;
    white-space: nowrap;
  }

  .user-btn.centered {
    justify-content: center;
  }

  .user-btn:hover {
    background: var(--bg-elevated);
  }

  .avatar-img {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    object-fit: cover;
    flex-shrink: 0;
  }

  .avatar-initials {
    width: 32px;
    height: 32px;
    border-radius: 50%;
    background: rgba(255, 255, 255, 0.08);
    border: 1px solid rgba(255, 255, 255, 0.12);
    backdrop-filter: blur(12px);
    -webkit-backdrop-filter: blur(12px);
    color: rgba(255, 255, 255, 0.7);
    font-size: 12px;
    font-weight: 600;
    display: flex;
    align-items: center;
    justify-content: center;
    flex-shrink: 0;
  }

  .user-info {
    flex: 1;
    min-width: 0;
    text-align: left;
  }

  .user-name {
    font-size: 13px;
    font-weight: 500;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .user-email {
    font-size: 11px;
    color: var(--text-tertiary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  /* Tooltip (fixed, portaled outside sidebar) */
  .nav-tooltip {
    position: fixed;
    left: calc(var(--sidebar-collapsed-width) + 8px);
    transform: translateY(-50%);
    background: #1e1e1e;
    border: 1px solid var(--border-default);
    border-radius: 6px;
    padding: 6px 10px;
    font-size: 12px;
    font-weight: 500;
    color: var(--text-primary);
    display: flex;
    align-items: center;
    gap: 8px;
    pointer-events: none;
    z-index: var(--z-tooltip);
    white-space: nowrap;
    box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
  }

  .tooltip-shortcut {
    font-family: ui-monospace, monospace;
    font-size: 10px;
    color: var(--text-tertiary);
    background: rgba(255, 255, 255, 0.05);
    border: 1px solid var(--border-default);
    border-radius: 4px;
    padding: 1px 5px;
  }
</style>
