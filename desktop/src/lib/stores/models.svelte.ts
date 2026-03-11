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
  "ollama-cloud": {
    slug: "ollama-cloud",
    label: "Ollama (Cloud)",
    letter: "C",
    color: "#8b5cf6",
  },
};

// ── Cloud Model Catalogs ──────────────────────────────────────────────────────
// Static catalogs of SOTA models for each cloud provider.
// These are shown in the model browser so users can see what's available
// before configuring API keys. The backend handles actual API routing.

export const CLOUD_MODEL_CATALOG: Model[] = [
  // ── Anthropic (Claude) ──────────────────────────────────────────────────────
  {
    name: "claude-opus-4-6",
    provider: "anthropic",
    size: "Opus 4.6",
    active: false,
    context_window: 200_000,
    description:
      "Most capable Claude model. Elite reasoning, code generation, and tool use. Extended thinking support.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "claude-sonnet-4-6",
    provider: "anthropic",
    size: "Sonnet 4.6",
    active: false,
    context_window: 200_000,
    description:
      "Latest Sonnet. Fast, strong code generation, tool use, and reasoning.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "claude-opus-4-0-20250514",
    provider: "anthropic",
    size: "Opus 4",
    active: false,
    context_window: 200_000,
    description:
      "Previous gen Opus. Elite reasoning, code generation, and tool use.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "claude-sonnet-4-5-20250514",
    provider: "anthropic",
    size: "Sonnet 4.5",
    active: false,
    context_window: 200_000,
    description:
      "Hybrid extended thinking. Strong multi-step reasoning and code.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "claude-haiku-4-5-20251001",
    provider: "anthropic",
    size: "Haiku 4.5",
    active: false,
    context_window: 200_000,
    description:
      "Fastest Claude model. Great for quick tasks, classification, and high-throughput use cases.",
    requires_api_key: true,
    is_local: false,
  },

  // ── OpenAI ──────────────────────────────────────────────────────────────────
  {
    name: "gpt-4.1",
    provider: "openai",
    size: "GPT-4.1",
    active: false,
    context_window: 1_000_000,
    description:
      "Latest GPT-4 class model. Best for coding, instruction following, and long context.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "gpt-4.1-mini",
    provider: "openai",
    size: "GPT-4.1 Mini",
    active: false,
    context_window: 1_000_000,
    description:
      "Cost-efficient GPT-4.1. Great balance of capability and speed.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "gpt-4.1-nano",
    provider: "openai",
    size: "GPT-4.1 Nano",
    active: false,
    context_window: 1_000_000,
    description: "Fastest, cheapest GPT-4 class model. High throughput tasks.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "o3",
    provider: "openai",
    size: "o3",
    active: false,
    context_window: 200_000,
    description:
      "Reasoning model. Multi-step math, science, and code. Extended thinking.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "o4-mini",
    provider: "openai",
    size: "o4-mini",
    active: false,
    context_window: 200_000,
    description:
      "Fast reasoning model. Cost-efficient for coding and analysis tasks.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "gpt-4o",
    provider: "openai",
    size: "GPT-4o",
    active: false,
    context_window: 128_000,
    description:
      "Multimodal GPT-4. Vision, audio, and text. Strong tool use and code.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "gpt-4o-mini",
    provider: "openai",
    size: "GPT-4o Mini",
    active: false,
    context_window: 128_000,
    description: "Affordable multimodal model. Good for most everyday tasks.",
    requires_api_key: true,
    is_local: false,
  },

  // ── Groq ────────────────────────────────────────────────────────────────────
  {
    name: "llama-3.3-70b-versatile",
    provider: "groq",
    size: "Llama 3.3 70B",
    active: false,
    context_window: 128_000,
    description:
      "Meta Llama 3.3 70B on Groq. Versatile, fast inference. Strong tool use and code.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "llama-3.1-8b-instant",
    provider: "groq",
    size: "Llama 3.1 8B",
    active: false,
    context_window: 128_000,
    description:
      "Ultra-fast 8B model. Great for quick responses, classification, and simple tasks.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "llama-4-scout-17b-16e-instruct",
    provider: "groq",
    size: "Llama 4 Scout 17B",
    active: false,
    context_window: 512_000,
    description:
      "Llama 4 Scout MoE on Groq. 17B active params, 16 experts. Excellent long context.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "qwen-qwq-32b",
    provider: "groq",
    size: "Qwen QwQ 32B",
    active: false,
    context_window: 128_000,
    description:
      "Qwen reasoning model on Groq. Strong math, code, and analytical reasoning.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "deepseek-r1-distill-llama-70b",
    provider: "groq",
    size: "DeepSeek R1 70B",
    active: false,
    context_window: 128_000,
    description:
      "DeepSeek R1 distilled to Llama 70B on Groq. Advanced reasoning at high speed.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "mixtral-8x7b-32768",
    provider: "groq",
    size: "Mixtral 8x7B",
    active: false,
    context_window: 32_768,
    description:
      "Mixtral MoE on Groq. Good general purpose model with fast inference.",
    requires_api_key: true,
    is_local: false,
  },
  {
    name: "gemma2-9b-it",
    provider: "groq",
    size: "Gemma 2 9B",
    active: false,
    context_window: 8_192,
    description:
      "Google Gemma 2 on Groq. Efficient for quick tasks and lightweight inference.",
    requires_api_key: true,
    is_local: false,
  },
];

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
      // Merge backend models with cloud catalog.
      // Backend models take priority (they have real active state).
      // Cloud catalog entries fill in providers the backend doesn't serve.
      const backendNames = new Set(result.map((m) => m.name));
      const catalogExtras = CLOUD_MODEL_CATALOG.filter(
        (cm) => !backendNames.has(cm.name),
      );
      this.models = [...result, ...catalogExtras];
    } catch (err) {
      // Backend offline — show cloud catalog so users can still browse
      this.models = [...CLOUD_MODEL_CATALOG];
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
