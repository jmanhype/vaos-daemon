import { load, type Store } from "@tauri-apps/plugin-store";
import { homeDir } from "@tauri-apps/api/path";
import type { Provider } from "./types";

let _store: Store | null = null;

async function getStore(): Promise<Store> {
  if (!_store) {
    _store = await load("store.json", { autoSave: true, defaults: {} });
  }
  return _store;
}

export async function isOnboardingComplete(): Promise<boolean> {
  const store = await getStore();
  return (await store.get<boolean>("onboardingComplete")) ?? false;
}

export async function getDefaultWorkingDirectory(): Promise<string> {
  return homeDir();
}

export async function completeOnboarding(opts: {
  provider: Provider;
  workingDirectory: string;
  apiKey: string;
}): Promise<void> {
  const store = await getStore();
  await store.set("onboardingComplete", true);
  await store.set("provider", opts.provider);
  await store.set("workingDirectory", opts.workingDirectory);
  await store.set("apiKey", opts.apiKey);
  await store.set("onboardingCompletedAt", new Date().toISOString());
  await store.save();

  // Notify the backend of the selected provider, model, and API key
  try {
    await fetch("http://127.0.0.1:8089/onboarding/setup", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        provider: opts.provider,
        model: null,
        api_key: opts.apiKey || null,
      }),
    });
  } catch {
    // Backend may not yet be ready — non-fatal, setup can be retried
  }
}
