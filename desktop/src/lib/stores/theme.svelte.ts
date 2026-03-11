// src/lib/stores/theme.svelte.ts
// Theme store — dark/light/system with OS preference detection.

export type ThemeMode = "dark" | "light" | "system";
export type ResolvedTheme = "dark" | "light";

const STORAGE_KEY = "osa-theme";

class ThemeStore {
  mode = $state<ThemeMode>("system");
  resolved = $state<ResolvedTheme>("dark");

  #mediaQuery: MediaQueryList | null = null;

  constructor() {
    if (typeof window === "undefined") return;

    // Restore preference
    const stored = localStorage.getItem(STORAGE_KEY);
    if (stored === "dark" || stored === "light" || stored === "system") {
      this.mode = stored;
    }

    // Listen for OS preference changes
    this.#mediaQuery = window.matchMedia("(prefers-color-scheme: dark)");
    this.#mediaQuery.addEventListener("change", this.#onSystemChange);

    this.#resolve();
  }

  setMode(mode: ThemeMode): void {
    this.mode = mode;
    if (typeof window !== "undefined") {
      localStorage.setItem(STORAGE_KEY, mode);
    }
    this.#resolve();
  }

  #onSystemChange = (): void => {
    if (this.mode === "system") {
      this.#resolve();
    }
  };

  #resolve(): void {
    if (this.mode === "system") {
      this.resolved = this.#mediaQuery?.matches ? "dark" : "light";
    } else {
      this.resolved = this.mode;
    }
    this.#applyToDOM();
  }

  #applyToDOM(): void {
    if (typeof document === "undefined") return;
    const root = document.documentElement;
    root.setAttribute("data-theme", this.resolved);

    // Also set the color-scheme for native form controls
    root.style.colorScheme = this.resolved;

    // Update Tauri window theme if available
    this.#updateTauriTheme();
  }

  async #updateTauriTheme(): Promise<void> {
    try {
      const { getCurrentWindow } = await import("@tauri-apps/api/window");
      const win = getCurrentWindow();
      await win.setTheme(this.resolved === "dark" ? "dark" : "light");
    } catch {
      // Not in Tauri or API not available
    }
  }
}

export const themeStore = new ThemeStore();
