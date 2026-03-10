// src/lib/stores/sessions.svelte.ts
// Dedicated session panel store — Svelte 5 class with $state runes.
// Wraps the sessions API and provides panel open/close state.

import type { Session } from "$api/types";
import { sessions as sessionsApi } from "$api/client";

// ── Sessions Store Class ───────────────────────────────────────────────────────

class SessionsStore {
  // All known sessions, newest first
  sessions = $state<Session[]>([]);

  // Currently active session id
  activeId = $state<string | null>(null);

  // Panel visibility
  isOpen = $state(false);

  // Async flags
  loading = $state(false);
  error = $state<string | null>(null);

  // ── Panel ────────────────────────────────────────────────────────────────────

  open(): void {
    this.isOpen = true;
  }

  close(): void {
    this.isOpen = false;
  }

  toggle(): void {
    this.isOpen = !this.isOpen;
  }

  // ── CRUD ─────────────────────────────────────────────────────────────────────

  async fetchSessions(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const data = await sessionsApi.list();
      this.sessions = data;
    } catch (e) {
      this.error = (e as Error).message;
    } finally {
      this.loading = false;
    }
  }

  async createSession(title?: string, model?: string): Promise<Session | null> {
    this.error = null;
    try {
      const { session } = await sessionsApi.create({ title, model });
      this.sessions = [session, ...this.sessions];
      return session;
    } catch (e) {
      this.error = (e as Error).message;
      return null;
    }
  }

  async deleteSession(id: string): Promise<void> {
    this.error = null;
    try {
      await sessionsApi.delete(id);
      this.sessions = this.sessions.filter((s) => s.id !== id);
      if (this.activeId === id) {
        this.activeId = this.sessions[0]?.id ?? null;
      }
    } catch (e) {
      this.error = (e as Error).message;
    }
  }

  async renameSession(id: string, title: string): Promise<void> {
    const trimmed = title.trim();
    if (!trimmed) return;
    this.error = null;
    try {
      const updated = await sessionsApi.rename(id, trimmed);
      this.sessions = this.sessions.map((s) => (s.id === id ? updated : s));
    } catch (e) {
      this.error = (e as Error).message;
    }
  }

  /**
   * Sets the active session and dispatches a custom DOM event so other
   * components (the chat view) can react without tight coupling.
   */
  switchSession(id: string): void {
    if (this.activeId === id) return;
    this.activeId = id;
    if (typeof window !== "undefined") {
      window.dispatchEvent(
        new CustomEvent("osa:session-switch", { detail: { sessionId: id } }),
      );
    }
  }

  // ── Sync helpers (called by chatStore to keep both stores in sync) ─────────

  /**
   * Merge in sessions that chatStore already fetched, avoiding a second
   * network call. Call this after chatStore.listSessions() resolves.
   */
  syncFromChatStore(sessions: Session[], activeId: string | null): void {
    this.sessions = sessions;
    this.activeId = activeId;
  }
}

// ── Singleton Export ───────────────────────────────────────────────────────────

export const sessionsStore = new SessionsStore();
