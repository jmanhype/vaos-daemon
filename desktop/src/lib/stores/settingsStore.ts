/**
 * Settings store — in-memory state for OSA Desktop settings.
 * Source of truth is the Elixir HTTP API at localhost:9089.
 * This store holds the client-side mirror of that state.
 */
import { writable } from "svelte/store";

export interface UserProfile {
  name: string;
  email: string;
  avatarUrl?: string;
}

export interface SettingsState {
  initialized: boolean;
  user: UserProfile | null;
}

function createSettingsStore() {
  const { subscribe, set, update } = writable<SettingsState>({
    initialized: false,
    user: null,
  });

  return {
    subscribe,
    setUser(user: UserProfile | null) {
      update((s) => ({ ...s, user }));
    },
    setInitialized() {
      update((s) => ({ ...s, initialized: true }));
    },
    reset() {
      set({ initialized: false, user: null });
    },
  };
}

export const settingsStore = createSettingsStore();
