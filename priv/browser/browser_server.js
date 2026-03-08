#!/usr/bin/env node
/**
 * browser_server.js — Playwright browser automation server for OSA.
 *
 * Protocol: reads newline-delimited JSON commands from stdin,
 * writes newline-delimited JSON responses to stdout.
 *
 * Commands:
 *   { "action": "navigate", "url": "..." }
 *   { "action": "get_text", "selector": "..." }
 *   { "action": "get_html", "selector": "..." }
 *   { "action": "screenshot" }
 *   { "action": "click", "selector": "..." }
 *   { "action": "type", "selector": "...", "text": "..." }
 *   { "action": "evaluate", "script": "..." }
 *   { "action": "close" }
 *
 * Responses:
 *   { "ok": true, "result": "..." }
 *   { "ok": false, "error": "..." }
 */

const { chromium } = require("playwright");
const readline = require("readline");

let browser = null;
let page = null;
let idleTimer = null;

const IDLE_TIMEOUT_MS = 5 * 60 * 1000; // 5 minutes

function resetIdleTimer() {
  if (idleTimer) clearTimeout(idleTimer);
  idleTimer = setTimeout(async () => {
    await cleanup();
    process.exit(0);
  }, IDLE_TIMEOUT_MS);
}

async function cleanup() {
  try {
    if (browser) {
      await browser.close();
      browser = null;
      page = null;
    }
  } catch (_) {
    // ignore cleanup errors
  }
}

async function ensureBrowser() {
  if (!browser) {
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      userAgent: "OSA/1.0 Browser Tool",
    });
    page = await context.newPage();
  }
  return page;
}

function respond(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

async function handleCommand(cmd) {
  resetIdleTimer();

  try {
    switch (cmd.action) {
      case "navigate": {
        if (!cmd.url) return respond({ ok: false, error: "Missing url" });
        const p = await ensureBrowser();
        await p.goto(cmd.url, {
          waitUntil: "domcontentloaded",
          timeout: 30000,
        });
        const title = await p.title();
        return respond({
          ok: true,
          result: `Navigated to ${cmd.url} — title: ${title}`,
        });
      }

      case "get_text": {
        const p = await ensureBrowser();
        let text;
        if (cmd.selector) {
          const el = await p.$(cmd.selector);
          if (!el)
            return respond({
              ok: false,
              error: `Selector not found: ${cmd.selector}`,
            });
          text = await el.innerText();
        } else {
          text = await p.innerText("body");
        }
        // Truncate to 50KB
        if (text.length > 50000)
          text = text.substring(0, 50000) + "\n...[truncated]";
        return respond({ ok: true, result: text });
      }

      case "get_html": {
        const p = await ensureBrowser();
        let html;
        if (cmd.selector) {
          const el = await p.$(cmd.selector);
          if (!el)
            return respond({
              ok: false,
              error: `Selector not found: ${cmd.selector}`,
            });
          html = await el.innerHTML();
        } else {
          html = await p.content();
        }
        if (html.length > 50000)
          html = html.substring(0, 50000) + "\n...[truncated]";
        return respond({ ok: true, result: html });
      }

      case "screenshot": {
        const p = await ensureBrowser();
        const buf = await p.screenshot({ fullPage: false });
        const b64 = buf.toString("base64");
        return respond({ ok: true, result: b64, format: "base64_png" });
      }

      case "click": {
        if (!cmd.selector)
          return respond({ ok: false, error: "Missing selector" });
        const p = await ensureBrowser();
        await p.click(cmd.selector, { timeout: 10000 });
        return respond({ ok: true, result: `Clicked: ${cmd.selector}` });
      }

      case "type": {
        if (!cmd.selector)
          return respond({ ok: false, error: "Missing selector" });
        if (!cmd.text) return respond({ ok: false, error: "Missing text" });
        const p = await ensureBrowser();
        await p.fill(cmd.selector, cmd.text, { timeout: 10000 });
        return respond({ ok: true, result: `Typed into ${cmd.selector}` });
      }

      case "evaluate": {
        if (!cmd.script) return respond({ ok: false, error: "Missing script" });
        const p = await ensureBrowser();
        const result = await p.evaluate(cmd.script);
        return respond({ ok: true, result: JSON.stringify(result) });
      }

      case "close": {
        await cleanup();
        return respond({ ok: true, result: "Browser closed" });
      }

      default:
        return respond({ ok: false, error: `Unknown action: ${cmd.action}` });
    }
  } catch (err) {
    return respond({ ok: false, error: err.message || String.valueOf(err) });
  }
}

// Main loop
const rl = readline.createInterface({ input: process.stdin, terminal: false });

rl.on("line", async (line) => {
  line = line.trim();
  if (!line) return;
  try {
    const cmd = JSON.parse(line);
    await handleCommand(cmd);
  } catch (err) {
    respond({ ok: false, error: `Invalid JSON: ${err.message}` });
  }
});

rl.on("close", async () => {
  await cleanup();
  process.exit(0);
});

process.on("SIGTERM", async () => {
  await cleanup();
  process.exit(0);
});

resetIdleTimer();
