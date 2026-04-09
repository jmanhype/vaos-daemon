export const EXPECTED_STATE = {
  publishedKitVersion: "2.57.0",
  publishedCookieRange: "^0.6.0",
  installedKitVersion: "2.57.0",
  installedCookieVersion: "0.6.0",
  lowSeverityCount: 3,
  advisoryUrl: "https://github.com/advisories/GHSA-pxg6-pf52-xh8x",
};

export function evaluateAdvisoryState(
  { auditReport, dependencyTree, publishedKitVersion, publishedDependencies },
  expectedState = EXPECTED_STATE,
) {
  const result = {
    installedKitVersion: findPackageVersion(dependencyTree, "@sveltejs/kit"),
    installedCookieVersion: findPackageVersion(dependencyTree, "cookie"),
    publishedKitVersion,
    publishedCookieRange: publishedDependencies.cookie ?? "missing",
    lowSeverityCount: auditReport.metadata?.vulnerabilities?.low ?? 0,
    advisoryPresent: hasAdvisory(auditReport, expectedState.advisoryUrl),
  };
  const mismatches = [];

  compareState(
    mismatches,
    "installed @sveltejs/kit version",
    expectedState.installedKitVersion,
    result.installedKitVersion,
  );
  compareState(
    mismatches,
    "installed cookie version",
    expectedState.installedCookieVersion,
    result.installedCookieVersion,
  );
  compareState(
    mismatches,
    "published @sveltejs/kit version",
    expectedState.publishedKitVersion,
    result.publishedKitVersion,
  );
  compareState(
    mismatches,
    "published cookie range",
    expectedState.publishedCookieRange,
    result.publishedCookieRange,
  );
  compareState(
    mismatches,
    "npm audit low-severity count",
    String(expectedState.lowSeverityCount),
    String(result.lowSeverityCount),
  );

  if (!result.advisoryPresent) {
    mismatches.push(
      `npm audit no longer reports ${expectedState.advisoryUrl} for cookie`,
    );
  }

  return {
    ...result,
    mismatches,
    status: mismatches.length === 0 ? "unchanged" : "changed",
  };
}

export function findPackageVersion(node, packageName) {
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

function compareState(mismatches, label, expected, actual) {
  if (expected !== actual) {
    mismatches.push(`${label} expected ${expected} but found ${actual}`);
  }
}

function hasAdvisory(auditReport, advisoryUrl) {
  return auditReport.vulnerabilities?.cookie?.via?.some(
    (entry) =>
      typeof entry === "object" && entry !== null && entry.url === advisoryUrl,
  );
}
