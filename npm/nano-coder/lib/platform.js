'use strict';
const path = require('node:path');

const PLATFORMS = {
  'darwin-arm64': '@nanobpm/nano-coder-darwin-arm64',
  'darwin-x64': '@nanobpm/nano-coder-darwin-x64',
  'linux-arm64': '@nanobpm/nano-coder-linux-arm64',
  'linux-x64': '@nanobpm/nano-coder-linux-x64',
};

function platformPackage() {
  const key = `${process.platform}-${process.arch}`;
  const pkg = PLATFORMS[key];
  if (!pkg) throw new Error(`no prebuilt binary for ${key} (supported: ${Object.keys(PLATFORMS).join(', ')}); try \`cargo install nano-coder\``);
  return pkg;
}

function binaryPath() {
  const pkg = platformPackage();
  try {
    return require.resolve(`${pkg}/bin/nano-coder`);
  } catch {
    throw new Error(`the platform package ${pkg} is not installed (was it skipped with --no-optional?); reinstall @nanobpm/nano-coder`);
  }
}

module.exports = { PLATFORMS, platformPackage, binaryPath, launcher: path.join(__dirname, '..', 'bin', 'nano-coder') };
