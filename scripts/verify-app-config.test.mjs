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
  assert.equal(report.violations[0].kind, "unparseable-floor");
});

test("verifyShape warns, but does not fail, on an unknown key", () => {
  const report = createReport();
  verifyShape({ maintenance: { until: "…" } }, report);
  assert.equal(report.violations.length, 0);
  assert.equal(report.warnings.length, 1);
  assert.match(report.warnings[0], /unknown key/);
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
