// vite.config.ts
import { defineConfig } from "vite";
import { sveltekit } from "@sveltejs/kit/vite";

// Use a high port unlikely to conflict with other dev servers
const TAURI_DEV_PORT = 5199;

// The Tauri CLI sets this env var during `tauri dev`
const isTauriDev = process.env.TAURI_ENV_DEBUG !== undefined;

export default defineConfig({
  plugins: [sveltekit()],

  // Vite dev server config
  server: {
    port: TAURI_DEV_PORT,
    strictPort: true, // Fail if port is taken — don't auto-increment

    // Proxy API calls to Elixir backend during development
    proxy: {
      "/api": {
        target: "http://127.0.0.1:9089",
        changeOrigin: true,
      },
      "/stream": {
        target: "http://127.0.0.1:9089",
        changeOrigin: true,
        configure: (proxy) => {
          proxy.on("proxyReq", (proxyReq) => {
            proxyReq.setHeader("Cache-Control", "no-cache");
            proxyReq.setHeader("X-Accel-Buffering", "no");
          });
        },
      },
    },

    // Allow connections from Tauri WebView
    host: "127.0.0.1",
  },

  // Tauri-specific build optimizations
  build: {
    target: isTauriDev ? "esnext" : ["chrome105", "safari15"],
    minify: !isTauriDev ? "esbuild" : false,
    sourcemap: isTauriDev,
    chunkSizeWarningLimit: 1000,
  },

  clearScreen: false,

  envPrefix: ["VITE_", "TAURI_"],

  optimizeDeps: {
    include: ["@xterm/xterm", "@xterm/addon-fit", "@xterm/addon-web-links"],
  },
});
