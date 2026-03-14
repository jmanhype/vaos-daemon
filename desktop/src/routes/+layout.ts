// Disable SSR globally — this is a Tauri SPA served as static files.
// The static adapter uses index.html as the SPA fallback, so all routing
// is handled client-side in the WebView. No server-side rendering occurs.
export const ssr = false;
export const prerender = false;
