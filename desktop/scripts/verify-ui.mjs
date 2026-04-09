#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import path from "node:path";
import process from "node:process";

const prettierExtensions = new Set([
  ".css",
  ".js",
  ".json",
  ".md",
  ".mjs",
  ".svelte",
  ".ts",
  ".yaml",
  ".yml",
]);

const eslintExtensions = new Set([".js", ".mjs", ".svelte", ".ts"]);

const requestedFiles = process.argv.slice(2);
const candidateFiles =
  requestedFiles.length > 0 ? requestedFiles : getChangedFiles();

const normalizedFiles = [...new Set(candidateFiles.map(normalizeFilePath))]
  .filter(Boolean)
  .filter((file) => existsSync(path.join(process.cwd(), file)));

const prettierFiles = normalizedFiles.filter((file) => {
  if (path.basename(file) === "package.json") {
    return true;
  }

  return prettierExtensions.has(path.extname(file));
});

const eslintFiles = normalizedFiles.filter((file) =>
  eslintExtensions.has(path.extname(file)),
);

if (prettierFiles.length > 0) {
  run("npx", ["prettier", "--check", "--ignore-unknown", ...prettierFiles]);
} else {
  console.log("verify:ui: no Prettier-targeted files selected");
}

if (eslintFiles.length > 0) {
  run("npx", ["eslint", ...eslintFiles]);
} else {
  console.log("verify:ui: no ESLint-targeted files selected");
}

run("npx", [
  "svelte-check",
  "--tsconfig",
  "./tsconfig.json",
  "--threshold",
  "error",
]);

function getChangedFiles() {
  const diffFiles = readLines("git", [
    "diff",
    "--name-only",
    "--diff-filter=ACMR",
    "HEAD",
    "--",
    ".",
  ]);
  const untrackedFiles = readLines("git", [
    "ls-files",
    "--others",
    "--exclude-standard",
    "--",
    ".",
  ]);

  return [...diffFiles, ...untrackedFiles];
}

function normalizeFilePath(file) {
  if (!file) {
    return null;
  }

  const absolute = path.resolve(process.cwd(), file);
  const relative = path.relative(process.cwd(), absolute);

  if (relative.startsWith("..")) {
    return null;
  }

  return relative;
}

function readLines(command, args) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: "utf8",
  });

  if (result.status !== 0) {
    return [];
  }

  return result.stdout
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
}

function run(command, args) {
  const printable = [command, ...args].join(" ");
  console.log(`verify:ui: ${printable}`);

  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    stdio: "inherit",
  });

  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
