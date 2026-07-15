import assert from "node:assert/strict";
import test from "node:test";
import { compareVersions } from "../../chrome-extension/willdeep-browser/update_checker.js";

test("rc releases sort by rc number", () => {
  assert.equal(compareVersions("1.157.0-rc2", "1.157.0-rc1"), 1);
  assert.equal(compareVersions("1.157.0-rc1", "1.157.0-rc2"), -1);
});

test("stable release sorts after its prerelease", () => {
  assert.equal(compareVersions("1.157.0", "1.157.0-rc4"), 1);
});

test("numeric components do not use lexical order", () => {
  assert.equal(compareVersions("1.160.0", "1.99.0"), 1);
});
