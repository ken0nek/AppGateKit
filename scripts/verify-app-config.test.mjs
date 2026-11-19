import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

import {
  checkFloorsAgainstLive,
  compareVersions,
  createReport,
  isParseableVersion,
  run,
  verifyShape,
} from "./verify-app-config.mjs";

const SCRIPT_PATH = fileURLToPath(new URL("./verify-app-config.mjs", import.meta.url));

// Keep this corpus in sync by hand with the `rejects` arguments in
// Tests/AppGateCoreTests/AppVersionTests.swift.
test("isParseableVersion accepts what AppVersion accepts", () => {
  for (const input of ["2", "2.1", "2.10.0", "007.1", "9223372036854775807"]) {
    assert.equal(isParseableVersion(input), true, input);
  }
});

test("isParseableVersion rejects what AppVersion rejects", () => {
  for (const input of [
    "2.x",
    "",
    "1.2.3-beta",
    "2.",
    "2..0",
    ".2",
    "+1",
    "-1",
    " 1",
    "1 ",
    "2.０", // full-width zero, U+FF10
    "99999999999999999999",
    "9223372036854775808",
  ]) {
    assert.equal(isParseableVersion(input), false, input);
  }
});

test("isParseableVersion rejects non-strings", () => {
  for (const input of [null, undefined, 3, ["1.0"], {}]) {
    assert.equal(isParseableVersion(input), false, String(input));
  }
});

test("compareVersions gets what a string compare gets backwards", () => {
  assert.equal(compareVersions("2.10.0", "2.9.0"), 1);
});

test("compareVersions treats a missing trailing component as zero", () => {
  assert.equal(compareVersions("2.1", "2.1.0"), 0);
});

test("compareVersions: padding is not truncation", () => {
  assert.equal(compareVersions("2.1", "2.1.3"), -1);
});

// `Number` loses precision above 2^53, so as numbers this pair compares equal.
test("compareVersions stays exact past 2^53", () => {
  assert.equal(compareVersions("1.9007199254740993", "1.9007199254740992"), 1);
});

test("compareVersions is exact at the Int64 ceiling", () => {
  assert.equal(compareVersions("9223372036854775807", "9223372036854775806"), 1);
});

// A digits-only check accepts a floor above Int64 as parseable. The app reads
// that floor as absent, with no error.
test("verifyShape rejects a floor the app's parser cannot hold", () => {
  const report = createReport();
  verifyShape({ min_supported: "99999999999999999999" }, report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "unparseable-floor");
});

test("verifyShape accepts a floor at the Int64 ceiling", () => {
  const report = createReport();
  verifyShape({ min_supported: "9223372036854775807" }, report);
  assert.equal(report.violations.length, 0);
});

test("verifyShape accepts the README's own example config", () => {
  const report = createReport();
  verifyShape({ min_supported: "1.3.0", feature_floors: { share: "2.2.0" } }, report);
  assert.equal(report.violations.length, 0);
  assert.equal(report.warnings.length, 0);
});

test("verifyShape treats an explicit null floor as absent", () => {
  const report = createReport();
  verifyShape({ min_supported: null }, report);
  assert.equal(report.violations.length, 0);
});

test("verifyShape rejects a non-string floor", () => {
  const report = createReport();
  verifyShape({ min_supported: 130 }, report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "wrong-type");
});

test("verifyShape calls a non-string feature floor a wrong type, null included", () => {
  for (const floor of [2, null, ["2.0"], {}, true]) {
    const report = createReport();
    verifyShape({ feature_floors: { share: floor } }, report);
    assert.equal(report.violations.length, 1, JSON.stringify(floor));
    assert.equal(report.violations[0].kind, "wrong-type");
    assert.match(report.violations[0].detail, /reject the whole config/);
  }
});

test("verifyShape still calls an unparseable string an unparseable floor", () => {
  const report = createReport();
  verifyShape({ min_supported: "2.x" }, report);
  assert.equal(report.violations[0].kind, "unparseable-floor");
});

test("verifyShape warns, but does not fail, on an unknown key", () => {
  const report = createReport();
  verifyShape({ rollout: { percent: 10 } }, report);
  assert.equal(report.violations.length, 0);
  assert.equal(report.warnings.length, 1);
  assert.match(report.warnings[0], /unknown key/);
});

test("verifyShape warns, but does not fail, on maintenance in its reserved shape", () => {
  const report = createReport();
  verifyShape({ maintenance: { until: "2026-12-01T09:00:00Z" } }, report);
  assert.equal(report.violations.length, 0);
  assert.equal(report.warnings.length, 1);
  assert.match(report.warnings[0], /reserved/);
});

test("verifyShape rejects maintenance in any other shape", () => {
  const shapes = [
    null,
    "down until Monday",
    42,
    [],
    {},
    { until: 1764579600 },
    { until: null },
    { until: "2026-12-01T09:00:00Z", message: "Back soon" },
  ];
  for (const maintenance of shapes) {
    const report = createReport();
    verifyShape({ maintenance }, report);
    assert.equal(report.violations.length, 1, JSON.stringify(maintenance));
    assert.equal(report.violations[0].kind, "maintenance-shape", JSON.stringify(maintenance));
  }
});

test("verifyShape rejects a non-object config", () => {
  const report = createReport();
  verifyShape([], report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "not-an-object");
});

test("verifyShape rejects a feature_floors that is not an object", () => {
  const report = createReport();
  verifyShape({ feature_floors: [] }, report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "floors-shape");
});

test("verifyShape rejects an unparseable feature floor", () => {
  const report = createReport();
  verifyShape({ feature_floors: { share: "2.x" } }, report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "unparseable-feature-floor");
});

test("checkFloorsAgainstLive flags min_supported above live", () => {
  const report = createReport();
  checkFloorsAgainstLive({ min_supported: "9.0.0" }, "2.0.0", report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "floor-above-live");
});

test("checkFloorsAgainstLive passes min_supported at or below live", () => {
  const report = createReport();
  checkFloorsAgainstLive({ min_supported: "1.0.0" }, "2.0.0", report);
  assert.equal(report.violations.length, 0);
});

// A feature floor above the live version disables that feature for every
// install, so it gets the same check as `min_supported`.
test("checkFloorsAgainstLive flags a feature floor above live", () => {
  const report = createReport();
  checkFloorsAgainstLive({ feature_floors: { share: "9.0.0" } }, "2.0.0", report);
  assert.equal(report.violations.length, 1);
  assert.equal(report.violations[0].kind, "feature-floor-above-live");
  assert.match(report.violations[0].detail, /feature_floors\.share/);
});

test("checkFloorsAgainstLive checks every floor independently", () => {
  const report = createReport();
  checkFloorsAgainstLive(
    { min_supported: "9.0.0", feature_floors: { share: "9.0.0", pro: "1.0.0" } },
    "2.0.0",
    report,
  );
  assert.deepEqual(
    report.violations.map((v) => v.kind),
    ["floor-above-live", "feature-floor-above-live"],
  );
  assert.ok(!report.violations.some((v) => v.detail.includes("pro")));
});

test("checkFloorsAgainstLive treats equal as not above", () => {
  const report = createReport();
  checkFloorsAgainstLive(
    { min_supported: "2.0", feature_floors: { share: "2.0.0" } },
    "2.0.0",
    report,
  );
  assert.equal(report.violations.length, 0);
});

test("checkFloorsAgainstLive does not double-count an unparseable floor", () => {
  const report = createReport();
  checkFloorsAgainstLive({ feature_floors: { share: "2.x" } }, "2.0.0", report);
  assert.equal(report.violations.length, 0);
});

const CONFIG_URL = "https://example.com/app-config.json";
const APP_ID = "123456789";

/** A fake `fetch`. `config` and `lookup` are each `{status, type, body}`, or
 *  an Error to throw. */
function fakeFetch({ config, lookup }) {
  return async (url) => {
    const answer = String(url).includes("itunes.apple.com") ? lookup : config;
    if (answer instanceof Error) throw answer;
    return new Response(answer.body, {
      status: answer.status ?? 200,
      headers: { "content-type": answer.type ?? "application/json" },
    });
  };
}

function quiet() {
  const lines = { error: [], warn: [], log: [] };
  return {
    lines,
    out: {
      error: (line) => lines.error.push(line),
      warn: (line) => lines.warn.push(line),
      log: (line) => lines.log.push(line),
    },
  };
}

const GOOD_CONFIG = { body: '{"min_supported":"1.3.0"}' };
const GOOD_LOOKUP = { body: '{"resultCount":1,"results":[{"version":"2.0.0"}]}' };

async function runWith(answers, extraArgs = []) {
  const { lines, out } = quiet();
  const code = await run([CONFIG_URL, APP_ID, ...extraArgs], { fetch: fakeFetch(answers), out });
  return { code, lines };
}

test("run passes a good config against a good lookup", async () => {
  const { code } = await runWith({ config: GOOD_CONFIG, lookup: GOOD_LOOKUP });
  assert.equal(code, 0);
});

test("run fails a config that is not served with status 200", async () => {
  const { code, lines } = await runWith({
    config: { status: 404, body: "{}" },
    lookup: GOOD_LOOKUP,
  });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[status\]/);
});

test("run fails a config that is not served as application/json", async () => {
  const { code, lines } = await runWith({
    config: { type: "text/html", body: '{"min_supported":"1.3.0"}' },
    lookup: GOOD_LOOKUP,
  });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[content-type\]/);
});

test("run fails a body that is not JSON", async () => {
  const { code, lines } = await runWith({ config: { body: "<html></html>" }, lookup: GOOD_LOOKUP });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[not-json\]/);
});

test("run fails a config that cannot be fetched", async () => {
  const { code, lines } = await runWith({ config: new Error("offline"), lookup: GOOD_LOOKUP });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[unreachable\]/);
});

test("run fails a floor above the live version", async () => {
  const { code, lines } = await runWith({
    config: { body: '{"min_supported":"3.0.0"}' },
    lookup: GOOD_LOOKUP,
  });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[floor-above-live\]/);
});

test("run only warns when the lookup is unreachable", async () => {
  const { code, lines } = await runWith({ config: GOOD_CONFIG, lookup: new Error("offline") });
  assert.equal(code, 0);
  assert.equal(lines.warn.length, 1);
});

test("run only warns when the lookup answers with a server error", async () => {
  const { code, lines } = await runWith({ config: GOOD_CONFIG, lookup: { status: 503, body: "" } });
  assert.equal(code, 0);
  assert.equal(lines.warn.length, 1);
});

test("run fails when the lookup answers and knows no such app", async () => {
  const { code, lines } = await runWith({
    config: GOOD_CONFIG,
    lookup: { body: '{"resultCount":0,"results":[]}' },
  });
  assert.equal(code, 1);
  assert.match(lines.error.join("\n"), /\[app-not-found\]/);
});

test("run only warns about an unknown app when told the app is not released yet", async () => {
  const { code, lines } = await runWith(
    { config: GOOD_CONFIG, lookup: { body: '{"resultCount":0,"results":[]}' } },
    ["--not-yet-released"],
  );
  assert.equal(code, 0);
  assert.equal(lines.warn.length, 1);
});

test("run does not ask the lookup when the config sets no floor", async () => {
  const { code, lines } = await runWith({
    config: { body: "{}" },
    lookup: new Error("must not be called"),
  });
  assert.equal(code, 0);
  assert.equal(lines.warn.length, 0, "a lookup that was asked and threw would have warned");
});

// Node resolves symlinks in the entry point's URL and leaves argv[1] as typed.
// Comparing the raw values would make a symlinked invocation exit 0 without
// checking anything.
test("a symlinked invocation still runs main, not exits 0 silently", () => {
  const dir = mkdtempSync(join(tmpdir(), "verify-app-config-symlink-"));
  const linkPath = join(dir, "vac-link.mjs");
  try {
    symlinkSync(realpathSync(SCRIPT_PATH), linkPath);
    const result = spawnSync(process.execPath, [linkPath], { encoding: "utf8" });
    assert.equal(result.status, 2);
    assert.match(result.stderr, /usage:/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
