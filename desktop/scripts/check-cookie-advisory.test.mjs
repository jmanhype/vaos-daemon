import assert from "node:assert/strict";
import test from "node:test";

import {
  EXPECTED_STATE,
  evaluateAdvisoryState,
  findPackageVersion,
} from "./check-cookie-advisory-lib.mjs";

function buildInputs(overrides = {}) {
  return {
    auditReport: {
      metadata: {
        vulnerabilities: {
          low: EXPECTED_STATE.lowSeverityCount,
        },
      },
      vulnerabilities: {
        cookie: {
          via: [{ url: EXPECTED_STATE.advisoryUrl }],
        },
      },
    },
    dependencyTree: {
      dependencies: {
        "@sveltejs/kit": {
          version: EXPECTED_STATE.installedKitVersion,
          dependencies: {
            cookie: {
              version: EXPECTED_STATE.installedCookieVersion,
            },
          },
        },
      },
    },
    publishedKitVersion: EXPECTED_STATE.publishedKitVersion,
    publishedDependencies: {
      cookie: EXPECTED_STATE.publishedCookieRange,
    },
    ...overrides,
  };
}

test("evaluateAdvisoryState returns unchanged status for the current expected state", () => {
  const result = evaluateAdvisoryState(buildInputs());

  assert.equal(result.status, "unchanged");
  assert.deepEqual(result.mismatches, []);
  assert.equal(result.advisoryPresent, true);
});

test("evaluateAdvisoryState flags when npm audit no longer reports the advisory", () => {
  const result = evaluateAdvisoryState(
    buildInputs({
      auditReport: {
        metadata: {
          vulnerabilities: {
            low: EXPECTED_STATE.lowSeverityCount,
          },
        },
        vulnerabilities: {},
      },
    }),
  );

  assert.equal(result.status, "changed");
  assert.deepEqual(result.mismatches, [
    `npm audit no longer reports ${EXPECTED_STATE.advisoryUrl} for cookie`,
  ]);
});

test("evaluateAdvisoryState reports version and range drift", () => {
  const result = evaluateAdvisoryState(
    buildInputs({
      publishedKitVersion: "2.58.0",
      publishedDependencies: {
        cookie: "^0.7.0",
      },
    }),
  );

  assert.equal(result.status, "changed");
  assert.deepEqual(result.mismatches, [
    "published @sveltejs/kit version expected 2.57.0 but found 2.58.0",
    "published cookie range expected ^0.6.0 but found ^0.7.0",
  ]);
});

test("findPackageVersion traverses nested dependencies", () => {
  const tree = {
    dependencies: {
      top: {
        version: "1.0.0",
        dependencies: {
          nested: {
            version: "2.0.0",
            dependencies: {
              cookie: {
                version: "0.6.0",
              },
            },
          },
        },
      },
    },
  };

  assert.equal(findPackageVersion(tree, "cookie"), "0.6.0");
  assert.equal(findPackageVersion(tree, "missing"), "missing");
});
