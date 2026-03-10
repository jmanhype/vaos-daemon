// svelte.config.js
import adapter from "@sveltejs/adapter-static";
import { vitePreprocess } from "@sveltejs/vite-plugin-svelte";

/** @type {import('@sveltejs/kit').Config} */
const config = {
  preprocess: vitePreprocess(),

  kit: {
    // Static adapter: Tauri serves pre-built static files from the bundle.
    // No SSR — everything runs client-side in the WebView.
    adapter: adapter({
      pages: "build",
      assets: "build",
      fallback: "index.html", // SPA fallback for client-side routing
      precompress: false, // Tauri doesn't benefit from pre-compression
      strict: false,
    }),

    // Disable SSR globally — Tauri WebView is a pure SPA
    // Individual routes can still export const ssr = false if needed
    alias: {
      $lib: "src/lib",
      $api: "src/lib/api",
      $stores: "src/lib/stores",
      $components: "src/lib/components",
    },
  },
};

export default config;
