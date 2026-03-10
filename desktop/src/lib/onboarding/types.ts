export type Provider = "ollama" | "lmstudio" | "anthropic" | "openai" | "groq";
export type OnboardingStep = 1 | 2 | 3 | "complete";

export interface DetectionResult {
  ollama: boolean;
  lmstudio: boolean;
}

export interface OnboardingState {
  step: OnboardingStep;
  provider: Provider | null;
  detectedProviders: DetectionResult;
  detecting: boolean;
  apiKey: string;
  workingDirectory: string;
}

export interface ProviderMeta {
  id: Provider;
  name: string;
  tagline: string;
  requiresKey: boolean;
  keyPlaceholder: string;
  keyDocsUrl: string;
}

export const PROVIDERS: ProviderMeta[] = [
  {
    id: "ollama",
    name: "Ollama",
    tagline: "Local · Free",
    requiresKey: false,
    keyPlaceholder: "",
    keyDocsUrl: "",
  },
  {
    id: "lmstudio",
    name: "LM Studio",
    tagline: "Local · Free",
    requiresKey: false,
    keyPlaceholder: "",
    keyDocsUrl: "",
  },
  {
    id: "anthropic",
    name: "Anthropic",
    tagline: "Claude models",
    requiresKey: true,
    keyPlaceholder: "sk-ant-api03-...",
    keyDocsUrl: "https://console.anthropic.com/settings/keys",
  },
  {
    id: "openai",
    name: "OpenAI",
    tagline: "GPT models",
    requiresKey: true,
    keyPlaceholder: "sk-...",
    keyDocsUrl: "https://platform.openai.com/api-keys",
  },
  {
    id: "groq",
    name: "Groq",
    tagline: "Fast inference",
    requiresKey: true,
    keyPlaceholder: "gsk_...",
    keyDocsUrl: "https://console.groq.com/keys",
  },
];
