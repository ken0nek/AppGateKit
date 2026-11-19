#!/usr/bin/env node
/**
 * Reference check for an app gate config.
 *
 * Run it in the CI of whatever serves the file:
 *
 *     node verify-app-config.mjs https://example.com/app-config.json 123456789
 *
 * The most important check is that no floor exceeds the version live on the
 * App Store. A `min_supported` above it walls every user, and a
 * `feature_floors` entry above it disables that feature for every install.
 * Both last until each install fetches a corrected config. The script reads
 * the live version from the same lookup the app reads, so the check and the
 * app agree on what "live" means.
 *
 * Exits 1 on a violation and 0 otherwise. A lookup that does not answer is a
 * warning and not a violation, so an unrelated change is not blocked by
 * Apple's uptime. When the config sets a floor, a lookup that answers and
 * lists no such app is a violation, because a mistyped id would otherwise
 * turn the most important check off.
 * Pass `--not-yet-released` after the id while the app is not on sale.
 */

import { realpathSync } from "node:fs";
import { fileURLToPath } from "node:url";

const TIMEOUT_MS = 10_000;
/** The app's version syntax: dot-separated non-negative integers, at least one. */
const VERSION_RE = /^\d+(\.\d+)*$/;
/** Every key this version of the config format defines. */
const KNOWN_KEYS = new Set(["min_supported", "feature_floors"]);

/** The largest value Swift's `Int` holds. The app's parser returns nil for a
 *  larger component, so the app reads the whole version as absent and applies
 *  no gate, with no error. */
const MAX_COMPONENT = 9223372036854775807n;

/** Whether the shipped app can parse this value. Must stay identical to
 *  `AppVersion.init?(_:)`: dot-separated ASCII digits, at least one component,
 *  every component within `Int`. */
export function isParseableVersion(value) {
  if (typeof value !== "string" || !VERSION_RE.test(value)) return false;
  return value.split(".").every((part) => BigInt(part) <= MAX_COMPONENT);
}

/** Collects one run's findings. Created per run and not at module level, so a
 *  test can run one check in isolation. */
export function createReport() {
  const violations = [];
  const warnings = [];
  return {
    violations,
    warnings,
    fail: (kind, detail) => violations.push({ kind, detail }),
    warn: (detail) => warnings.push(detail),
  };
}

/** Returns -1, 0 or +1. Compares per component and pads the shorter side with
 *  zeros. Uses `BigInt`, because a plain string compare orders "2.10.0" before
 *  "2.9.0", and `Number` loses precision above 2^53 and compares two different
 *  versions as equal. */
export function compareVersions(a, b) {
  const left = a.split(".").map(BigInt);
  const right = b.split(".").map(BigInt);
  for (let i = 0; i < Math.max(left.length, right.length); i++) {
    const l = left[i] ?? 0n;
    const r = right[i] ?? 0n;
    if (l !== r) return l < r ? -1 : 1;
  }
  return 0;
}

async function get(url, fetchImpl) {
  return await fetchImpl(url, { signal: AbortSignal.timeout(TIMEOUT_MS) });
}

async function readConfig(configURL, report, fetchImpl) {
  let response;
  try {
    response = await get(configURL, fetchImpl);
  } catch (error) {
    report.fail("unreachable", `${configURL} could not be fetched: ${error.message}`);
    return null;
  }
  if (response.status !== 200) {
    report.fail("status", `${configURL} answered ${response.status}, expected 200`);
    return null;
  }
  const contentType = (response.headers.get("content-type") ?? "").split(";")[0].trim();
  if (contentType !== "application/json") {
    report.fail("content-type", `Content-Type is "${contentType}", expected application/json`);
  }
  const body = await response.text();
  try {
    return JSON.parse(body);
  } catch (error) {
    report.fail("not-json", `body did not parse as JSON: ${error.message}`);
    return null;
  }
}

const WHOLE_CONFIG_REJECTED =
  "builds of the app that are already installed reject the whole config when one value " +
  "has the wrong type, and keep their previous cached config for up to 24 hours";

function wrongType(label, value) {
  return `${label} is ${JSON.stringify(value)}, which is not a string; ${WHOLE_CONFIG_REJECTED}`;
}

/** `maintenance` is reserved for one shape, `{"until": "<string>"}`, and no
 *  build reads it yet. Any other value fails, so the name cannot be taken by a
 *  shape the reserved one would then have to stay compatible with. */
function verifyMaintenance(value, report) {
  const isReservedShape =
    value !== null &&
    typeof value === "object" &&
    !Array.isArray(value) &&
    Object.keys(value).length === 1 &&
    typeof value.until === "string";
  if (!isReservedShape) {
    report.fail(
      "maintenance-shape",
      `maintenance is ${JSON.stringify(value)}; the name is reserved for ` +
        '{"until": "<ISO 8601 time>"} and takes no other shape',
    );
    return;
  }
  report.warn('"maintenance" is reserved and no build reads it yet');
}

export function verifyShape(config, report) {
  if (config === null || typeof config !== "object" || Array.isArray(config)) {
    report.fail("not-an-object", "the config must be a JSON object");
    return;
  }
  if ("maintenance" in config) verifyMaintenance(config.maintenance, report);
  for (const key of Object.keys(config)) {
    if (key === "maintenance") continue;
    if (!KNOWN_KEYS.has(key)) {
      // An unknown key is allowed, because an old build ignores it. A new key
      // changes the config format, so add it to KNOWN_KEYS on purpose.
      report.warn(`unknown key "${key}"; add it here when it is deliberate`);
    }
  }
  if ("min_supported" in config && config.min_supported !== null) {
    if (typeof config.min_supported !== "string") {
      report.fail("wrong-type", wrongType("min_supported", config.min_supported));
    } else if (!isParseableVersion(config.min_supported)) {
      report.fail(
        "unparseable-floor",
        `min_supported ${JSON.stringify(config.min_supported)} is not dotted-numeric; ` +
          "the app reads it as absent and never walls",
      );
    }
  }
  const floors = config.feature_floors;
  if (floors !== undefined && floors !== null) {
    if (typeof floors !== "object" || Array.isArray(floors)) {
      report.fail(
        "floors-shape",
        "feature_floors must be an object of name to version; " + WHOLE_CONFIG_REJECTED,
      );
    } else {
      for (const [feature, floor] of Object.entries(floors)) {
        if (typeof floor !== "string") {
          report.fail("wrong-type", wrongType(`feature_floors.${feature}`, floor));
        } else if (!isParseableVersion(floor)) {
          report.fail(
            "unparseable-feature-floor",
            `feature_floors.${feature} is ${JSON.stringify(floor)}, not dotted-numeric; ` +
              "the app reads it as absent and never gates that feature",
          );
        }
      }
    }
  }
}

/** Every parseable floor the config sets, with the label to use in a message. */
function floorsOf(config) {
  const floors = [];
  if (isParseableVersion(config?.min_supported)) {
    floors.push({ label: "min_supported", value: config.min_supported });
  }
  const features = config?.feature_floors;
  if (features && typeof features === "object" && !Array.isArray(features)) {
    for (const [feature, floor] of Object.entries(features)) {
      if (isParseableVersion(floor)) {
        floors.push({ label: `feature_floors.${feature}`, value: floor });
      }
    }
  }
  return floors;
}

/** Checks every floor against the live version. A feature floor above the live
 *  version disables that feature for every install, including the newest. */
export function checkFloorsAgainstLive(config, live, report) {
  const floors = floorsOf(config);
  if (floors.length === 0) return;
  for (const { label, value } of floors) {
    if (compareVersions(value, live) > 0) {
      report.fail(
        label === "min_supported" ? "floor-above-live" : "feature-floor-above-live",
        `${label} ${value} is ABOVE the live App Store version ${live}. Publishing this ` +
          (label === "min_supported"
            ? "walls every user, including those who just updated, until each install " +
              "fetches a corrected config."
            : "disables that feature for every install, including the newest, until the " +
              "floor is lowered again."),
      );
    } else {
      console.log(`✓ ${label} ${value} is at or below the live App Store version ${live}`);
    }
  }
}

async function verifyAgainstLiveVersion(config, appStoreID, notYetReleased, report, fetchImpl) {
  if (floorsOf(config).length === 0) return;

  let payload;
  try {
    const response = await get(`https://itunes.apple.com/lookup?id=${appStoreID}`, fetchImpl);
    if (!response.ok) throw new Error(`lookup answered ${response.status}`);
    payload = await response.json();
  } catch (error) {
    report.warn(
      `could not read the live App Store version (${error.message}); no floor was ` +
        "checked against it. Re-run with a network before raising any floor.",
    );
    return;
  }

  const live = payload?.results?.[0]?.version;
  if (!live) {
    const detail =
      `the lookup answered and lists no version for app id ${appStoreID} on its default ` +
      "storefront, so no floor was checked against a live version";
    if (notYetReleased) {
      report.warn(`${detail}. Remove --not-yet-released once the app is on sale.`);
    } else {
      report.fail(
        "app-not-found",
        `${detail}. Check the id. If the app is not on sale yet, pass --not-yet-released.`,
      );
    }
    return;
  }
  if (!isParseableVersion(live)) {
    report.warn(`the App Store reported an unparseable version "${live}"; the floor was not checked`);
    return;
  }
  checkFloorsAgainstLive(config, live, report);
}

/** Runs the whole check and returns the exit code. `fetch` and `out` (an
 *  object with `error`, `warn` and `log`) are parameters, so a test can run it
 *  with no network. */
export async function run(argv, { fetch: fetchImpl = globalThis.fetch, out = console } = {}) {
  const [configURL, appStoreID, ...flags] = argv;
  const notYetReleased = flags.includes("--not-yet-released");
  if (!configURL || !appStoreID) {
    out.error("usage: node verify-app-config.mjs <config-url> <app-store-id> [--not-yet-released]");
    return 2;
  }

  const report = createReport();
  const config = await readConfig(configURL, report, fetchImpl);
  if (config !== null) {
    verifyShape(config, report);
    await verifyAgainstLiveVersion(config, appStoreID, notYetReleased, report, fetchImpl);
  }

  for (const line of report.warnings) out.warn(`⚠︎  ${line}`);

  if (report.violations.length > 0) {
    out.error(`\n✗ app-config: ${report.violations.length} violation(s)\n`);
    for (const { kind, detail } of report.violations) out.error(`  [${kind}] ${detail}`);
    return 1;
  }
  out.log("✓ app-config: shape, route and floor all check out");
  return 0;
}

// Uses `process.argv[1]` and not `import.meta.main`, which needs a newer Node
// than some CI hosts have, and this file is meant to be copied into other
// repositories. Compares against the realpath, because Node resolves symlinks
// in the entry point's URL and leaves `argv[1]` as typed. Comparing the raw
// values would make a symlinked invocation exit 0 without checking anything.
if (process.argv[1] && fileURLToPath(import.meta.url) === realpathSync(process.argv[1])) {
  process.exit(await run(process.argv.slice(2)));
}
