'use strict';
// Replace the JS launcher with the native binary so `nano-coder` runs without a
// Node process in front of it. Best-effort: on any failure the launcher stays
// and still works.
const fs = require('node:fs');
const { binaryPath, launcher } = require('./lib/platform.js');

try {
  const bin = binaryPath();
  const tmp = `${launcher}.tmp-${process.pid}`;
  fs.copyFileSync(bin, tmp);
  fs.chmodSync(tmp, 0o755);
  fs.renameSync(tmp, launcher);
} catch (err) {
  console.warn(`nano-coder: keeping the Node launcher (${err.message})`);
}
