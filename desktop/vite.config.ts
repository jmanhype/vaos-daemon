// vite.config.ts
import { defineConfig } from "vite";
import { sveltekit } from "@sveltejs/kit/vite";

// Tauri dev server must run on a fixed port
const TAURI_DEV_PORT = 5173;

// The Tauri CLI sets this env var during `tauri dev`
const isTauriDev = process.env.TAURI_ENV_DEBUG !== undefined;

export default defineConfig({
  plugins: [sveltekit()],

  // Vite dev server config
  server: {
    port: TAURI_DEV_PORT,
    strictPort: true, // Fail if port is taken — don't auto-increment

    // Proxy API calls to Elixir backend during development
    // In production, the frontend calls localhost:8089 directly
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8089",
        changeOrigin: true,
        // Do NOT rewrite — Elixir API paths start with /api
      },
      "/stream": {
        target: "http://127.0.0.1:8089",
        changeOrigin: true,
        // SSE needs these headers to work through the proxy
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
    // Tauri uses Chromium/WebKit — target modern JS, no legacy transpilation
    target: isTauriDev ? "esnext" : ["chrome105", "safari15"],
    // Smaller chunks — Tauri loads from local FS, not network
    minify: !isTauriDev ? "esbuild" : false,
    sourcemap: isTauriDev,
    chunkSizeWarningLimit: 1000,
  },

  // Prevent Vite from clearing the terminal in Tauri context
  clearScreen: false,

  // Expose Tauri env variables to the frontend
  envPrefix: ["VITE_", "TAURI_"],

  // Optimize deps — avoid full-page reload for these in dev
  optimizeDeps: {
    include: ["@xterm/xterm", "@xterm/addon-fit", "@xterm/addon-web-links"],
  },
});
