#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import process from "node:process";

const EXPECTED_STATE = {
  publishedKitVersion: "2.57.0",
  publishedCookieRange: "^0.6.0",
  installedKitVersion: "2.57.0",
  installedCookieVersion: "0.6.0",
  lowSeverityCount: 3,
  advisoryUrl: "https://github.com/advisories/GHSA-pxg6-pf52-xh8x",
};

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

const installedKitVersion = findPackageVersion(dependencyTree, "@sveltejs/kit");
const installedCookieVersion = findPackageVersion(dependencyTree, "cookie");
const publishedCookieRange = publishedDependencies.cookie ?? "missing";
const lowSeverityCount = auditReport.metadata?.vulnerabilities?.low ?? 0;
const advisoryPresent = auditReport.vulnerabilities?.cookie?.via?.some(
  (entry) =>
    typeof entry === "object" &&
    entry !== null &&
    entry.url === EXPECTED_STATE.advisoryUrl,
);

console.log(`Installed @sveltejs/kit: ${installedKitVersion}`);
console.log(`Installed cookie: ${installedCookieVersion}`);
console.log(`Published @sveltejs/kit: ${publishedKitVersion}`);
console.log(`Published cookie range: ${publishedCookieRange}`);
console.log(`npm audit low-severity count: ${lowSeverityCount}`);
console.log(`cookie advisory present: ${advisoryPresent ? "yes" : "no"}`);

const mismatches = [];

compareState(
  mismatches,
  "installed @sveltejs/kit version",
  EXPECTED_STATE.installedKitVersion,
  installedKitVersion,
);
compareState(
  mismatches,
  "installed cookie version",
  EXPECTED_STATE.installedCookieVersion,
  installedCookieVersion,
);
compareState(
  mismatches,
  "published @sveltejs/kit version",
  EXPECTED_STATE.publishedKitVersion,
  publishedKitVersion,
);
compareState(
  mismatches,
  "published cookie range",
  EXPECTED_STATE.publishedCookieRange,
  publishedCookieRange,
);
compareState(
  mismatches,
  "npm audit low-severity count",
  String(EXPECTED_STATE.lowSeverityCount),
  String(lowSeverityCount),
);

if (!advisoryPresent) {
  mismatches.push(
    `npm audit no longer reports ${EXPECTED_STATE.advisoryUrl} for cookie`,
  );
}

if (mismatches.length === 0) {
  console.log(
    "Status: upstream remains unchanged. The residual cookie advisory is still inherited from the latest published @sveltejs/kit release.",
  );
  process.exit(0);
}

console.error(
  "Status: advisory state changed. Re-run the desktop dependency audit and revisit vas-swarm-6hv.",
);

for (const mismatch of mismatches) {
  console.error(`- ${mismatch}`);
}

process.exit(1);

function compareState(mismatches, label, expected, actual) {
  if (expected !== actual) {
    mismatches.push(`${label} expected ${expected} but found ${actual}`);
  }
}

function findPackageVersion(node, packageName) {
  if (!node?.dependencies) {
    return "missing";
  }

  const pending = Object.entries(node.dependencies);

  while (pending.length > 0) {
    const [currentName, current] = pending.shift();

    if (!current) {
      continue;
    }

    if (currentName === packageName) {
      return current.version ?? "missing";
    }

    if (current.dependencies) {
      pending.push(...Object.entries(current.dependencies));
    }
  }

  return "missing";
}

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
