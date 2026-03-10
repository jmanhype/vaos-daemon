// src/lib/stores/models.svelte.ts
// Models store — Svelte 5 class with $state fields.
// Manages model list, active model, and provider grouping.

import type { Model, ModelProvider } from "$lib/api/types";
import { models as modelsApi } from "$lib/api/client";

// ── Provider metadata ─────────────────────────────────────────────────────────

export interface ProviderMeta {
  slug: ModelProvider;
  label: string;
  /** Single letter shown in the icon circle */
  letter: string;
  /** Tailwind-compatible hex colour for the circle background */
  color: string;
}

export const PROVIDER_META: Record<ModelProvider, ProviderMeta> = {
  anthropic: {
    slug: "anthropic",
    label: "Anthropic",
    letter: "A",
    color: "#7c3aed",
  },
  openai: {
    slug: "openai",
    label: "OpenAI",
    letter: "O",
    color: "#16a34a",
  },
  groq: {
    slug: "groq",
    label: "Groq",
    letter: "G",
    color: "#f97316",
  },
  openrouter: {
    slug: "openrouter",
    label: "OpenRouter",
    letter: "R",
    color: "#0ea5e9",
  },
  ollama: {
    slug: "ollama",
    label: "Ollama (Local)",
    letter: "L",
    color: "#64748b",
  },
};

// ── Provider group ─────────────────────────────────────────────────────────────

export interface ProviderGroup {
  meta: ProviderMeta;
  models: Model[];
  available: boolean;
}

// ── Store ──────────────────────────────────────────────────────────────────────

class ModelsStore {
  models = $state<Model[]>([]);
  loading = $state(false);
  switching = $state<string | null>(null); // model name currently being switched to
  error = $state<string | null>(null);
  switchError = $state<string | null>(null);

  // ── Derived ─────────────────────────────────────────────────────────────────

  current = $derived(this.models.find((m) => m.active) ?? null);

  currentLabel = $derived(
    this.current
      ? `${this.current.provider}/${this.current.name}`
      : "No model selected",
  );

  groupedByProvider = $derived((): ProviderGroup[] => {
    const map = new Map<ModelProvider, Model[]>();

    for (const model of this.models) {
      const existing = map.get(model.provider);
      if (existing) {
        existing.push(model);
      } else {
        map.set(model.provider, [model]);
      }
    }

    return Array.from(map.entries()).map(([slug, models]) => ({
      meta: PROVIDER_META[slug] ?? {
        slug,
        label: slug,
        letter: slug[0].toUpperCase(),
        color: "#555555",
      },
      models,
      available: models.some((m) => m.active),
    }));
  });

  searchFiltered(query: string): ProviderGroup[] {
    const q = query.trim().toLowerCase();
    if (!q) return this.groupedByProvider();

    return this.groupedByProvider()
      .map((group) => ({
        ...group,
        models: group.models.filter(
          (m) =>
            m.name.toLowerCase().includes(q) ||
            m.description?.toLowerCase().includes(q) ||
            group.meta.label.toLowerCase().includes(q),
        ),
      }))
      .filter((group) => group.models.length > 0);
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  async fetchModels(): Promise<void> {
    this.loading = true;
    this.error = null;
    try {
      const result = await modelsApi.list();
      this.models = result;
    } catch (err) {
      this.error =
        err instanceof Error ? err.message : "Failed to fetch models";
    } finally {
      this.loading = false;
    }
  }

  async activateModel(name: string): Promise<void> {
    this.switching = name;
    this.switchError = null;
    try {
      const updated = await modelsApi.activate(name);
      // Mark the activated model and clear others
      this.models = this.models.map((m) => ({
        ...m,
        active: m.name === updated.name && m.provider === updated.provider,
      }));
    } catch (err) {
      this.switchError =
        err instanceof Error ? err.message : "Failed to switch model";
    } finally {
      this.switching = null;
    }
  }

  async downloadModel(name: string): Promise<{ job_id: string }> {
    return modelsApi.download(name);
  }
}

export const modelsStore = new ModelsStore();
