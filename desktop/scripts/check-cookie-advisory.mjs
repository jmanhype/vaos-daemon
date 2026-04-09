#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import process from "node:process";
import { evaluateAdvisoryState } from "./check-cookie-advisory-lib.mjs";

const auditReport = readJson("npm", ["audit", "--json"], {
  allowFailure: true,
});
const dependencyTree = readJson("npm", [
  "ls",
  "--all",
  "--json",
  "@sveltejs/kit",
  "cookie",
]);
const publishedKitVersion = readText("npm", [
  "view",
  "@sveltejs/kit",
  "version",
]);
const publishedDependencies = readJson("npm", [
  "view",
  "@sveltejs/kit@latest",
  "dependencies",
  "--json",
]);

const result = evaluateAdvisoryState({
  auditReport,
  dependencyTree,
  publishedKitVersion,
  publishedDependencies,
});

console.log(`Installed @sveltejs/kit: ${result.installedKitVersion}`);
console.log(`Installed cookie: ${result.installedCookieVersion}`);
console.log(`Published @sveltejs/kit: ${result.publishedKitVersion}`);
console.log(`Published cookie range: ${result.publishedCookieRange}`);
console.log(`npm audit low-severity count: ${result.lowSeverityCount}`);
console.log(
  `cookie advisory present: ${result.advisoryPresent ? "yes" : "no"}`,
);

if (result.status === "unchanged") {
  console.log(
    "Status: upstream remains unchanged. The residual cookie advisory is still inherited from the latest published @sveltejs/kit release.",
  );
  process.exit(0);
}

console.error(
  "Status: advisory state changed. Re-run the desktop dependency audit and revisit vas-swarm-6hv.",
);

for (const mismatch of result.mismatches) {
  console.error(`- ${mismatch}`);
}

process.exit(1);

function readJson(command, args, options = {}) {
  const output = read(command, args, options);

  try {
    return JSON.parse(output);
  } catch (error) {
    console.error(`Failed to parse JSON from ${command} ${args.join(" ")}`);
    console.error(output);
    throw error;
  }
}

function readText(command, args) {
  return read(command, args).trim();
}

function read(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: process.cwd(),
    encoding: "utf8",
  });

  if (result.status !== 0 && !options.allowFailure) {
    console.error(result.stderr.trim());
    process.exit(result.status ?? 1);
  }

  const output = `${result.stdout ?? ""}`.trim();

  if (!output) {
    const errorOutput = `${result.stderr ?? ""}`.trim();

    if (errorOutput) {
      console.error(errorOutput);
    }

    process.exit(result.status ?? 1);
  }

  return output;
}
