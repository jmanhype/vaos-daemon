<script lang="ts">
  import { onMount, onDestroy } from 'svelte';
  import { restartBackend } from '$lib/utils/backend';
  import { BASE_URL, API_PREFIX, getToken } from '$lib/api/client';

  // ── xterm types (imported dynamically to avoid SSR issues) ──────────────────
  import type { Terminal as XTerminal } from '@xterm/xterm';
  import type { FitAddon } from '@xterm/addon-fit';
  import type { SearchAddon } from '@xterm/addon-search';

  // xterm CSS — MUST be imported for proper rendering
  import '@xterm/xterm/css/xterm.css';

  // ── State ────────────────────────────────────────────────────────────────────

  let terminalEl = $state<HTMLDivElement | null>(null);
  let term = $state<XTerminal | null>(null);
  let fitAddon = $state<FitAddon | null>(null);
  let searchAddon = $state<SearchAddon | null>(null);

  let searchVisible = $state(false);
  let searchQuery = $state('');
  let fontSize = $state(13);
  let inputBuffer = $state('');
  let cursorPos = $state(0);
  let isExecuting = $state(false);
  let searchInputEl = $state<HTMLInputElement | null>(null);
  let resizeObserver: ResizeObserver | null = null;
  let resizeTimer: ReturnType<typeof setTimeout> | null = null;

  // ── Command history ─────────────────────────────────────────────────────────
  const MAX_HISTORY = 100;
  let history: string[] = [];
  let historyIndex = -1;
  let savedInput = ''; // saves current input when browsing history

  function addToHistory(cmd: string) {
    if (!cmd.trim()) return;
    // Skip consecutive duplicates
    if (history.length > 0 && history[0] === cmd) return;
    history.unshift(cmd);
    if (history.length > MAX_HISTORY) history.pop();
    historyIndex = -1;
  }

  // ── Line editing helpers ────────────────────────────────────────────────────
  function clearLine(t: XTerminal) {
    // Move cursor back to start of input, clear to end
    if (inputBuffer.length > 0) {
      // Move left by cursorPos chars, then clear to end of line
      if (cursorPos > 0) t.write(`\x1b[${cursorPos}D`);
      t.write('\x1b[K');
    }
  }

  function redrawInput(t: XTerminal, newBuffer: string, newCursorPos?: number) {
    clearLine(t);
    inputBuffer = newBuffer;
    cursorPos = newCursorPos ?? newBuffer.length;
    t.write(newBuffer);
    // Move cursor back if not at end
    const diff = newBuffer.length - cursorPos;
    if (diff > 0) t.write(`\x1b[${diff}D`);
  }

  // ── Terminal theme ───────────────────────────────────────────────────────────

  const TERM_THEME = {
    background:   '#0a0a0c',
    foreground:   '#e0e0e0',
    cursor:       '#ffffff',
    cursorAccent: '#0a0a0c',
    selectionBackground: 'rgba(255,255,255,0.15)',
    // ANSI normal
    black:   '#1a1a1f',
    red:     '#ef4444',
    green:   '#22c55e',
    yellow:  '#f59e0b',
    blue:    '#3b82f6',
    magenta: '#a855f7',
    cyan:    '#06b6d4',
    white:   '#e0e0e0',
    // ANSI bright
    brightBlack:   '#555566',
    brightRed:     '#f87171',
    brightGreen:   '#4ade80',
    brightYellow:  '#fbbf24',
    brightBlue:    '#60a5fa',
    brightMagenta: '#c084fc',
    brightCyan:    '#22d3ee',
    brightWhite:   '#ffffff',
  };

  // ── Prompt helper ────────────────────────────────────────────────────────────

  const PROMPT = '\r\n\x1b[38;5;39mosa\x1b[0m \x1b[38;5;240m>\x1b[0m ';

  function writePrompt(t: XTerminal) {
    t.write(PROMPT);
  }

  // ── Shell execution via OSA backend ─────────────────────────────────────────

  async function executeCommand(command: string): Promise<void> {
    if (!term || !command.trim()) {
      writePrompt(term!);
      return;
    }

    isExecuting = true;
    term.write('\r\n');

    try {
      const token = getToken();
      const headers: Record<string, string> = { 'Content-Type': 'application/json' };
      if (token) headers['Authorization'] = `Bearer ${token}`;

      const res = await fetch(`${BASE_URL}${API_PREFIX}/tools/shell_execute/execute`, {
        method: 'POST',
        headers,
        body: JSON.stringify({ command, working_directory: null }),
      });

      if (!res.ok) {
        const errText = await res.text().catch(() => `HTTP ${res.status}`);
        term.write(`\x1b[31mError ${res.status}: ${errText}\x1b[0m`);
      } else {
        const data = (await res.json()) as {
          stdout?: string;
          stderr?: string;
          exit_code?: number;
          output?: string;
          result?: string;
        };

        // Accept several possible field names from the backend
        const stdout = data.stdout ?? data.output ?? data.result ?? '';
        const stderr = data.stderr ?? '';

        if (stdout) {
          // Normalize LF to CRLF for xterm rendering
          term.write(stdout.replace(/\n/g, '\r\n'));
        }
        if (stderr) {
          term.write(`\x1b[31m${stderr.replace(/\n/g, '\r\n')}\x1b[0m`);
        }

        const exitCode = data.exit_code;
        if (typeof exitCode === 'number' && exitCode !== 0) {
          term.write(`\r\n\x1b[33m[exit ${exitCode}]\x1b[0m`);
        }
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      term.write(`\x1b[31m${msg}\x1b[0m`);
    } finally {
      isExecuting = false;
      writePrompt(term!);
    }
  }

  // ── Slash command autocomplete ──────────────────────────────────────────────

  const SLASH_COMMANDS = ['help', 'clear', 'model', 'new', 'history', 'restart'];

  /** Returns the best matching slash command for the current input, or null */
  function getSlashCompletion(buf: string): string | null {
    if (!buf.startsWith('/') || buf.length < 2) return null;
    const typed = buf.slice(1).toLowerCase();
    const match = SLASH_COMMANDS.find(c => c.startsWith(typed) && c !== typed);
    return match ?? null;
  }

  /** Ghost text state — the remaining chars to show as preview */
  let ghostText = $state('');

  function updateGhost() {
    if (!inputBuffer.startsWith('/') || cursorPos !== inputBuffer.length) {
      ghostText = '';
      return;
    }
    const match = getSlashCompletion(inputBuffer);
    ghostText = match ? match.slice(inputBuffer.length - 1) : '';
  }

  /** Write ghost text in dim color after cursor, then move cursor back */
  function renderGhost(t: XTerminal) {
    if (!ghostText) return;
    // Write dim ghost text
    t.write(`\x1b[38;5;240m${ghostText}\x1b[0m`);
    // Move cursor back to where it was
    t.write(`\x1b[${ghostText.length}D`);
  }

  /** Clear any rendered ghost text */
  function clearGhost(t: XTerminal) {
    if (!ghostText) return;
    // From cursor position, clear to end of line
    t.write('\x1b[K');
  }

  // ── Slash commands ──────────────────────────────────────────────────────────

  function handleSlashCommand(cmd: string, t: XTerminal) {
    const parts = cmd.slice(1).split(/\s+/);
    const name = parts[0]?.toLowerCase() ?? '';

    t.write('\r\n');

    switch (name) {
      case 'help':
        t.writeln('\x1b[1m\x1b[38;5;39mAvailable commands:\x1b[0m');
        t.writeln('  \x1b[38;5;39m/help\x1b[0m          Show this help');
        t.writeln('  \x1b[38;5;39m/clear\x1b[0m         Clear the terminal');
        t.writeln('  \x1b[38;5;39m/model\x1b[0m         Show active model');
        t.writeln('  \x1b[38;5;39m/new\x1b[0m           Start new session');
        t.writeln('  \x1b[38;5;39m/history\x1b[0m       Show command history');
        t.writeln('  \x1b[38;5;39m/restart\x1b[0m       Restart the backend');
        t.writeln('');
        t.writeln('\x1b[1mKeyboard shortcuts:\x1b[0m');
        t.writeln('  \x1b[38;5;240mCtrl+L\x1b[0m   Clear screen');
        t.writeln('  \x1b[38;5;240mCtrl+C\x1b[0m   Cancel / clear line');
        t.writeln('  \x1b[38;5;240mCtrl+F\x1b[0m   Toggle search');
        t.writeln('  \x1b[38;5;240mCtrl+A\x1b[0m   Jump to start');
        t.writeln('  \x1b[38;5;240mCtrl+E\x1b[0m   Jump to end');
        t.writeln('  \x1b[38;5;240mCtrl+K\x1b[0m   Delete to end of line');
        t.writeln('  \x1b[38;5;240mCtrl+U\x1b[0m   Delete to start of line');
        t.writeln('  \x1b[38;5;240mCtrl+W\x1b[0m   Delete word back');
        t.writeln('  \x1b[38;5;240m↑/↓\x1b[0m      History navigation');
        break;
      case 'clear':
        t.clear();
        inputBuffer = '';
        cursorPos = 0;
        break;
      case 'model':
        t.writeln('\x1b[38;5;240mQuerying active model...\x1b[0m');
        void (async () => {
          try {
            const token = getToken();
            const headers: Record<string, string> = { Accept: 'application/json' };
            if (token) headers['Authorization'] = `Bearer ${token}`;
            const res = await fetch(`${BASE_URL}${API_PREFIX}/models`, { headers });
            if (res.ok) {
              const models = await res.json() as Array<{ name: string; active?: boolean }>;
              const active = models.find(m => m.active);
              if (active) {
                t.writeln(`\x1b[38;5;39mActive model:\x1b[0m ${active.name}`);
              } else {
                t.writeln('\x1b[38;5;240mNo active model set\x1b[0m');
              }
            } else {
              t.writeln('\x1b[31mBackend offline\x1b[0m');
            }
          } catch {
            t.writeln('\x1b[31mBackend offline\x1b[0m');
          }
          writePrompt(t);
        })();
        return; // Don't write prompt — async handler does it
      case 'history':
        if (history.length === 0) {
          t.writeln('\x1b[38;5;240mNo command history\x1b[0m');
        } else {
          t.writeln('\x1b[1mCommand history:\x1b[0m');
          const show = history.slice(0, 20);
          show.forEach((h, i) => {
            t.writeln(`  \x1b[38;5;240m${i + 1}.\x1b[0m ${h}`);
          });
          if (history.length > 20) {
            t.writeln(`  \x1b[38;5;240m... and ${history.length - 20} more\x1b[0m`);
          }
        }
        break;
      case 'new':
        t.writeln('\x1b[38;5;39mStarting new session...\x1b[0m');
        history = [];
        historyIndex = -1;
        t.clear();
        t.writeln('\x1b[1m\x1b[38;5;39mOSA\x1b[0m \x1b[38;5;240mTerminal\x1b[0m');
        t.writeln('\x1b[38;5;240mNew session started. Type /help for commands.\x1b[0m');
        break;
      case 'restart':
        t.writeln('\x1b[38;5;39mSending restart signal...\x1b[0m');
        restartBackend()
          .then(() => t.writeln('\x1b[38;5;39mRestart signal sent\x1b[0m'))
          .catch(() => t.writeln('\x1b[31mBackend offline — cannot restart\x1b[0m'))
          .finally(() => writePrompt(t));
        return;
      default:
        t.writeln(`\x1b[31mUnknown command: /${name}\x1b[0m`);
        t.writeln('\x1b[38;5;240mType /help for available commands.\x1b[0m');
        break;
    }

    writePrompt(t);
  }

  // ── xterm initialization ─────────────────────────────────────────────────────

  async function initTerminal(container: HTMLDivElement) {
    const { Terminal } = await import('@xterm/xterm');
    const { FitAddon }       = await import('@xterm/addon-fit');
    const { WebLinksAddon }  = await import('@xterm/addon-web-links');
    const { SearchAddon }    = await import('@xterm/addon-search');

    const t = new Terminal({
      fontFamily: "'SF Mono', 'Fira Code', 'Fira Mono', 'Cascadia Code', ui-monospace, monospace",
      fontSize,
      lineHeight: 1.4,
      letterSpacing: 0,
      cursorBlink: true,
      cursorStyle: 'block',
      theme: TERM_THEME,
      allowProposedApi: true,
      scrollback: 5000,
      convertEol: false,
      windowsMode: false,
      macOptionIsMeta: true,
    });

    const fit  = new FitAddon();
    const wla  = new WebLinksAddon();
    const srch = new SearchAddon();

    t.loadAddon(fit);
    t.loadAddon(wla);
    t.loadAddon(srch);

    t.open(container);
    fit.fit();

    // Banner
    t.writeln('\x1b[1m\x1b[38;5;39mOSA\x1b[0m \x1b[38;5;240mTerminal\x1b[0m');
    t.writeln('\x1b[38;5;240mType a command or /help for available commands.\x1b[0m');
    t.writeln('\x1b[38;5;240mCtrl+L clear | Ctrl+F search | ↑↓ history | Ctrl+A/E home/end\x1b[0m');
    writePrompt(t);

    // Key handler — full readline emulation
    t.onKey(({ key, domEvent }) => {
      const ev = domEvent;

      // Tab — complete slash command
      if (ev.key === 'Tab') {
        ev.preventDefault();
        const match = getSlashCompletion(inputBuffer);
        if (match && cursorPos === inputBuffer.length) {
          clearGhost(t);
          const completion = match.slice(inputBuffer.length - 1);
          inputBuffer += completion;
          cursorPos = inputBuffer.length;
          t.write(completion);
          ghostText = '';
        }
        return;
      }

      // Ctrl+C — interrupt
      if (ev.ctrlKey && ev.key === 'c') {
        clearGhost(t);
        if (isExecuting) {
          isExecuting = false;
          t.write('^C');
        } else {
          t.write('^C');
          inputBuffer = '';
          cursorPos = 0;
        }
        ghostText = '';
        writePrompt(t);
        return;
      }

      // Ctrl+L — clear screen
      if (ev.ctrlKey && ev.key === 'l') {
        t.clear();
        inputBuffer = '';
        cursorPos = 0;
        writePrompt(t);
        return;
      }

      // Ctrl+F — toggle search overlay
      if (ev.ctrlKey && ev.key === 'f') {
        searchVisible = !searchVisible;
        if (searchVisible) {
          setTimeout(() => searchInputEl?.focus(), 50);
        }
        return;
      }

      // Ctrl+A — jump to start of line
      if (ev.ctrlKey && ev.key === 'a') {
        if (cursorPos > 0) {
          t.write(`\x1b[${cursorPos}D`);
          cursorPos = 0;
        }
        return;
      }

      // Ctrl+E — jump to end of line
      if (ev.ctrlKey && ev.key === 'e') {
        const diff = inputBuffer.length - cursorPos;
        if (diff > 0) {
          t.write(`\x1b[${diff}C`);
          cursorPos = inputBuffer.length;
        }
        return;
      }

      // Ctrl+K — delete from cursor to end of line
      if (ev.ctrlKey && ev.key === 'k') {
        if (cursorPos < inputBuffer.length) {
          t.write('\x1b[K');
          inputBuffer = inputBuffer.slice(0, cursorPos);
        }
        return;
      }

      // Ctrl+U — delete from start to cursor
      if (ev.ctrlKey && ev.key === 'u') {
        if (cursorPos > 0) {
          const rest = inputBuffer.slice(cursorPos);
          t.write(`\x1b[${cursorPos}D\x1b[K`);
          inputBuffer = rest;
          cursorPos = 0;
          t.write(rest);
          if (rest.length > 0) t.write(`\x1b[${rest.length}D`);
        }
        return;
      }

      // Ctrl+W — delete word back
      if (ev.ctrlKey && ev.key === 'w') {
        if (cursorPos > 0) {
          const before = inputBuffer.slice(0, cursorPos);
          const after = inputBuffer.slice(cursorPos);
          const wordStart = before.trimEnd().lastIndexOf(' ') + 1;
          const deleted = cursorPos - wordStart;
          if (deleted > 0) {
            const newBuf = before.slice(0, wordStart) + after;
            t.write(`\x1b[${deleted}D\x1b[K`);
            cursorPos = wordStart;
            inputBuffer = newBuf;
            t.write(after);
            if (after.length > 0) t.write(`\x1b[${after.length}D`);
          }
        }
        return;
      }

      if (isExecuting) return;

      // Enter — execute
      if (ev.key === 'Enter') {
        clearGhost(t);
        ghostText = '';
        const cmd = inputBuffer;
        addToHistory(cmd);
        inputBuffer = '';
        cursorPos = 0;
        historyIndex = -1;

        // Handle slash commands locally
        if (cmd.startsWith('/')) {
          handleSlashCommand(cmd, t);
          return;
        }

        void executeCommand(cmd);
        return;
      }

      // Up arrow — history back
      if (ev.key === 'ArrowUp') {
        clearGhost(t);
        ghostText = '';
        if (history.length === 0) return;
        if (historyIndex === -1) savedInput = inputBuffer;
        if (historyIndex < history.length - 1) {
          historyIndex++;
          redrawInput(t, history[historyIndex]);
        }
        return;
      }

      // Down arrow — history forward
      if (ev.key === 'ArrowDown') {
        clearGhost(t);
        ghostText = '';
        if (historyIndex <= 0) {
          if (historyIndex === 0) {
            historyIndex = -1;
            redrawInput(t, savedInput);
          }
          return;
        }
        historyIndex--;
        redrawInput(t, history[historyIndex]);
        return;
      }

      // Left arrow — move cursor left
      if (ev.key === 'ArrowLeft') {
        if (cursorPos > 0) {
          cursorPos--;
          t.write('\x1b[D');
        }
        return;
      }

      // Right arrow — move cursor right
      if (ev.key === 'ArrowRight') {
        if (cursorPos < inputBuffer.length) {
          cursorPos++;
          t.write('\x1b[C');
        }
        return;
      }

      // Home — jump to start
      if (ev.key === 'Home') {
        if (cursorPos > 0) {
          t.write(`\x1b[${cursorPos}D`);
          cursorPos = 0;
        }
        return;
      }

      // End — jump to end
      if (ev.key === 'End') {
        const diff = inputBuffer.length - cursorPos;
        if (diff > 0) {
          t.write(`\x1b[${diff}C`);
          cursorPos = inputBuffer.length;
        }
        return;
      }

      // Backspace — delete char before cursor
      if (ev.key === 'Backspace') {
        clearGhost(t);
        if (cursorPos > 0) {
          const before = inputBuffer.slice(0, cursorPos - 1);
          const after = inputBuffer.slice(cursorPos);
          inputBuffer = before + after;
          cursorPos--;
          t.write('\b');
          t.write(after + ' ');
          t.write(`\x1b[${after.length + 1}D`);
          updateGhost();
          renderGhost(t);
        }
        return;
      }

      // Delete — delete char at cursor
      if (ev.key === 'Delete') {
        if (cursorPos < inputBuffer.length) {
          const before = inputBuffer.slice(0, cursorPos);
          const after = inputBuffer.slice(cursorPos + 1);
          inputBuffer = before + after;
          t.write(after + ' ');
          t.write(`\x1b[${after.length + 1}D`);
        }
        return;
      }

      // Ignore non-printable / modifier-only keys
      if (ev.ctrlKey || ev.altKey || ev.metaKey) return;
      if (key.length !== 1) return;

      // Printable character — insert at cursor position
      clearGhost(t);
      const before = inputBuffer.slice(0, cursorPos);
      const after = inputBuffer.slice(cursorPos);
      inputBuffer = before + key + after;
      cursorPos++;
      t.write(key + after);
      if (after.length > 0) t.write(`\x1b[${after.length}D`);

      // Show ghost text for slash commands
      updateGhost();
      renderGhost(t);
    });

    term      = t;
    fitAddon  = fit;
    searchAddon = srch;

    // ResizeObserver — debounced to avoid thrashing
    resizeObserver = new ResizeObserver(() => {
      if (resizeTimer !== null) clearTimeout(resizeTimer);
      resizeTimer = setTimeout(() => {
        fit.fit();
      }, 80);
    });
    resizeObserver.observe(container);
  }

  // ── Font size controls ───────────────────────────────────────────────────────

  function increaseFontSize() {
    fontSize = Math.min(fontSize + 1, 24);
    if (term) {
      term.options.fontSize = fontSize;
    }
    fitAddon?.fit();
  }

  function decreaseFontSize() {
    fontSize = Math.max(fontSize - 1, 9);
    if (term) {
      term.options.fontSize = fontSize;
    }
    fitAddon?.fit();
  }

  // ── Clear terminal ───────────────────────────────────────────────────────────

  function clearTerminal() {
    term?.clear();
    inputBuffer = '';
    writePrompt(term!);
  }

  // ── Search ───────────────────────────────────────────────────────────────────

  function handleSearchInput(e: Event) {
    const val = (e.target as HTMLInputElement).value;
    searchQuery = val;
    if (val) {
      searchAddon?.findNext(val, { incremental: true, caseSensitive: false });
    }
  }

  function searchNext() {
    if (searchQuery) searchAddon?.findNext(searchQuery, { caseSensitive: false });
  }

  function searchPrev() {
    if (searchQuery) searchAddon?.findPrevious(searchQuery, { caseSensitive: false });
  }

  function closeSearch() {
    searchVisible = false;
    searchQuery = '';
    term?.focus();
  }

  function handleSearchKeydown(e: KeyboardEvent) {
    if (e.key === 'Escape') { closeSearch(); return; }
    if (e.key === 'Enter')  {
      if (e.shiftKey) {
        searchPrev();
      } else {
        searchNext();
      }
      return;
    }
    if (e.key === 'f' && (e.ctrlKey || e.metaKey)) { e.preventDefault(); closeSearch(); }
  }

  // ── Lifecycle ────────────────────────────────────────────────────────────────

  onMount(async () => {
    // Wait one tick for terminalEl to be set by the DOM
    await Promise.resolve();
    if (terminalEl) {
      await initTerminal(terminalEl);
    }
  });

  onDestroy(() => {
    resizeObserver?.disconnect();
    if (resizeTimer !== null) clearTimeout(resizeTimer);
    term?.dispose();
  });
</script>

<svelte:head>
  <title>Terminal — OSA</title>
</svelte:head>

<div class="terminal-page">
  <!-- ── Header bar ─────────────────────────────────────────────────────────── -->
  <header class="term-header">
    <div class="term-header__left">
      <!-- Terminal icon -->
      <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true">
        <rect width="16" height="16" rx="3" fill="rgba(255,255,255,0.06)" />
        <path d="M3.5 5.5L6.5 8L3.5 10.5" stroke="rgba(255,255,255,0.6)" stroke-width="1.2"
              stroke-linecap="round" stroke-linejoin="round"/>
        <line x1="8" y1="10.5" x2="12" y2="10.5" stroke="rgba(255,255,255,0.4)"
              stroke-width="1.2" stroke-linecap="round"/>
      </svg>
      <span class="term-header__title">Terminal</span>
    </div>

    <div class="term-header__toolbar">
      <!-- Search toggle -->
      <button
        class="toolbar-btn"
        class:toolbar-btn--active={searchVisible}
        onclick={() => {
          searchVisible = !searchVisible;
          if (searchVisible) setTimeout(() => searchInputEl?.focus(), 50);
        }}
        aria-label="Toggle search (Ctrl+F)"
        title="Search  Ctrl+F"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <circle cx="5.5" cy="5.5" r="3.5" stroke="currentColor" stroke-width="1.3"/>
          <line x1="8.5" y1="8.5" x2="12" y2="12" stroke="currentColor" stroke-width="1.3"
                stroke-linecap="round"/>
        </svg>
      </button>

      <!-- Font size decrease -->
      <button
        class="toolbar-btn"
        onclick={decreaseFontSize}
        aria-label="Decrease font size"
        title="Decrease font size"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <text x="1" y="11" fill="currentColor" font-size="9" font-family="monospace">A</text>
          <line x1="8" y1="8" x2="13" y2="8" stroke="currentColor" stroke-width="1.3"
                stroke-linecap="round"/>
        </svg>
      </button>

      <!-- Font size label -->
      <span class="toolbar-label" aria-label="Font size">{fontSize}px</span>

      <!-- Font size increase -->
      <button
        class="toolbar-btn"
        onclick={increaseFontSize}
        aria-label="Increase font size"
        title="Increase font size"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <text x="1" y="11" fill="currentColor" font-size="9" font-family="monospace">A</text>
          <line x1="8" y1="8" x2="13" y2="8" stroke="currentColor" stroke-width="1.3"
                stroke-linecap="round"/>
          <line x1="10.5" y1="5.5" x2="10.5" y2="10.5" stroke="currentColor" stroke-width="1.3"
                stroke-linecap="round"/>
        </svg>
      </button>

      <!-- Divider -->
      <div class="toolbar-divider" aria-hidden="true"></div>

      <!-- Clear -->
      <button
        class="toolbar-btn"
        onclick={clearTerminal}
        aria-label="Clear terminal"
        title="Clear terminal  Ctrl+L"
      >
        <svg width="14" height="14" viewBox="0 0 14 14" fill="none" aria-hidden="true">
          <path d="M2 4h10M5 4V2.5a.5.5 0 0 1 .5-.5h3a.5.5 0 0 1 .5.5V4M3 4l.7 7.2a.5.5 0 0 0 .5.3h5.6a.5.5 0 0 0 .5-.3L11 4"
                stroke="currentColor" stroke-width="1.2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
      </button>
    </div>
  </header>

  <!-- ── Search overlay ───────────────────────────────────────────────────────── -->
  {#if searchVisible}
    <div class="search-bar" role="search" aria-label="Terminal search">
      <svg class="search-icon" width="13" height="13" viewBox="0 0 13 13" fill="none" aria-hidden="true">
        <circle cx="5" cy="5" r="3.5" stroke="rgba(255,255,255,0.4)" stroke-width="1.2"/>
        <line x1="8" y1="8" x2="12" y2="12" stroke="rgba(255,255,255,0.4)" stroke-width="1.2"
              stroke-linecap="round"/>
      </svg>
      <input
        bind:this={searchInputEl}
        class="search-input"
        type="text"
        placeholder="Search terminal..."
        value={searchQuery}
        oninput={handleSearchInput}
        onkeydown={handleSearchKeydown}
        aria-label="Search terminal output"
        spellcheck="false"
        autocomplete="off"
      />
      <div class="search-actions">
        <button class="search-nav-btn" onclick={searchPrev} aria-label="Previous match">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M3 7.5L6 4.5L9 7.5" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>
        <button class="search-nav-btn" onclick={searchNext} aria-label="Next match">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M3 4.5L6 7.5L9 4.5" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round" stroke-linejoin="round"/>
          </svg>
        </button>
        <button class="search-close-btn" onclick={closeSearch} aria-label="Close search">
          <svg width="12" height="12" viewBox="0 0 12 12" fill="none" aria-hidden="true">
            <path d="M2 2L10 10M10 2L2 10" stroke="currentColor" stroke-width="1.3"
                  stroke-linecap="round"/>
          </svg>
        </button>
      </div>
    </div>
  {/if}

  <!-- ── Terminal body ─────────────────────────────────────────────────────────── -->
  <div class="term-body">
    <!-- xterm mount point -->
    <div
      bind:this={terminalEl}
      class="xterm-container"
      aria-label="Terminal"
      role="application"
    ></div>

    <!-- Executing indicator -->
    {#if isExecuting}
      <div class="exec-indicator" aria-live="polite" aria-label="Executing command">
        <span class="exec-dot"></span>
        <span class="exec-dot"></span>
        <span class="exec-dot"></span>
      </div>
    {/if}
  </div>
</div>

<style>
  /* ── Page shell ─────────────────────────────────────────────────────────── */

  .terminal-page {
    display: flex;
    flex-direction: column;
    height: 100%;
    width: 100%;
    background: #0a0a0c;
    overflow: hidden;
  }

  /* ── Header ─────────────────────────────────────────────────────────────── */

  .term-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    padding: 0 12px;
    height: 40px;
    flex-shrink: 0;
    background: rgba(255, 255, 255, 0.04);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    user-select: none;
  }

  .term-header__left {
    display: flex;
    align-items: center;
    gap: 8px;
  }

  .term-header__title {
    font-size: 13px;
    font-weight: 500;
    color: rgba(255, 255, 255, 0.7);
    letter-spacing: 0.01em;
  }

  .term-header__toolbar {
    display: flex;
    align-items: center;
    gap: 2px;
  }

  .toolbar-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 28px;
    height: 28px;
    border: none;
    background: transparent;
    color: rgba(255, 255, 255, 0.45);
    border-radius: 6px;
    cursor: pointer;
    transition: background 140ms ease, color 140ms ease;
  }

  .toolbar-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.85);
  }

  .toolbar-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  .toolbar-btn--active {
    background: rgba(59, 130, 246, 0.18);
    color: #60a5fa;
  }

  .toolbar-btn--active:hover {
    background: rgba(59, 130, 246, 0.25);
    color: #93c5fd;
  }

  .toolbar-label {
    font-size: 11px;
    color: rgba(255, 255, 255, 0.35);
    min-width: 28px;
    text-align: center;
    font-variant-numeric: tabular-nums;
  }

  .toolbar-divider {
    width: 1px;
    height: 16px;
    background: rgba(255, 255, 255, 0.08);
    margin: 0 4px;
  }

  /* ── Search bar ─────────────────────────────────────────────────────────── */

  .search-bar {
    display: flex;
    align-items: center;
    gap: 8px;
    padding: 6px 12px;
    background: rgba(255, 255, 255, 0.04);
    border-bottom: 1px solid rgba(255, 255, 255, 0.07);
    flex-shrink: 0;
  }

  .search-icon {
    flex-shrink: 0;
  }

  .search-input {
    flex: 1;
    background: rgba(255, 255, 255, 0.06);
    border: 1px solid rgba(255, 255, 255, 0.1);
    border-radius: 6px;
    padding: 4px 10px;
    font-size: 13px;
    font-family: var(--font-sans);
    color: rgba(255, 255, 255, 0.85);
    outline: none;
    min-width: 0;
    transition: border-color 140ms ease;
  }

  .search-input::placeholder {
    color: rgba(255, 255, 255, 0.25);
  }

  .search-input:focus {
    border-color: rgba(59, 130, 246, 0.5);
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.12);
  }

  .search-actions {
    display: flex;
    align-items: center;
    gap: 2px;
    flex-shrink: 0;
  }

  .search-nav-btn,
  .search-close-btn {
    display: flex;
    align-items: center;
    justify-content: center;
    width: 24px;
    height: 24px;
    border: none;
    background: transparent;
    color: rgba(255, 255, 255, 0.45);
    border-radius: 5px;
    cursor: pointer;
    transition: background 120ms ease, color 120ms ease;
  }

  .search-nav-btn:hover,
  .search-close-btn:hover {
    background: rgba(255, 255, 255, 0.08);
    color: rgba(255, 255, 255, 0.85);
  }

  .search-nav-btn:focus-visible,
  .search-close-btn:focus-visible {
    outline: 2px solid var(--accent-primary);
    outline-offset: 2px;
  }

  /* ── Terminal body ──────────────────────────────────────────────────────── */

  .term-body {
    flex: 1;
    position: relative;
    overflow: hidden;
  }

  .xterm-container {
    width: 100%;
    height: 100%;
    padding: 8px 4px 4px 4px;
  }

  /* Override xterm.js internal styles for seamless integration */
  :global(.xterm) {
    height: 100%;
    padding: 0 !important;
  }

  :global(.xterm-viewport) {
    border-radius: 0 !important;
    overflow-y: auto !important;
  }

  :global(.xterm-viewport::-webkit-scrollbar) {
    width: 5px;
  }

  :global(.xterm-viewport::-webkit-scrollbar-thumb) {
    background: rgba(255, 255, 255, 0.1);
    border-radius: 9999px;
  }

  :global(.xterm-viewport::-webkit-scrollbar-thumb:hover) {
    background: rgba(255, 255, 255, 0.18);
  }

  :global(.xterm-screen) {
    padding-left: 8px !important;
  }

  /* ── Executing indicator ─────────────────────────────────────────────────── */

  .exec-indicator {
    position: absolute;
    bottom: 12px;
    right: 16px;
    display: flex;
    align-items: center;
    gap: 4px;
    pointer-events: none;
  }

  .exec-dot {
    width: 5px;
    height: 5px;
    border-radius: 50%;
    background: rgba(59, 130, 246, 0.7);
    animation: exec-pulse 1s ease-in-out infinite;
  }

  .exec-dot:nth-child(2) { animation-delay: 0.2s; }
  .exec-dot:nth-child(3) { animation-delay: 0.4s; }

  @keyframes exec-pulse {
    0%, 80%, 100% { opacity: 0.2; transform: scale(0.85); }
    40%           { opacity: 1;   transform: scale(1); }
  }

</style>
