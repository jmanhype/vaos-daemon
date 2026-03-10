import type { DetectionResult } from "./types";

export async function detectLocalProviders(): Promise<DetectionResult> {
  const [ollamaResult, lmstudioResult] = await Promise.allSettled([
    fetch("http://localhost:11434/api/tags", {
      signal: AbortSignal.timeout(2000),
    }).then((r) => r.ok),
    fetch("http://localhost:1234/v1/models", {
      signal: AbortSignal.timeout(2000),
    }).then((r) => r.ok),
  ]);

  return {
    ollama: ollamaResult.status === "fulfilled" && ollamaResult.value === true,
    lmstudio:
      lmstudioResult.status === "fulfilled" && lmstudioResult.value === true,
  };
}
