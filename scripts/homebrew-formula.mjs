#!/usr/bin/env node
// Write the Homebrew formula for a release (nanobpm/homebrew-tap, Formula/nano-coder.rb).
//
//   node scripts/homebrew-formula.mjs --version 0.67.0 --sums dist/SHA256SUMS --out nano-coder.rb
//
// SHA256SUMS is the file the release attaches (`<sha256>  nano-coder-<v>-<target>.tar.gz`
// per line). The formula installs the prebuilt binary for the platform.
import { readFileSync, writeFileSync } from 'node:fs';
import { parseArgs } from 'node:util';

const { values } = parseArgs({
  options: { version: { type: 'string' }, sums: { type: 'string' }, out: { type: 'string' } },
});
const { version, sums, out } = values;
if (!version || !sums || !out) {
  console.error('usage: homebrew-formula.mjs --version X.Y.Z --sums <SHA256SUMS> --out <file>');
  process.exit(2);
}
const sha = {};
for (const line of readFileSync(sums, 'utf8').split('\n')) {
  const m = line.trim().match(/^([0-9a-f]{64})\s+\*?(\S+)$/);
  if (m) sha[m[2]] = m[1];
}
const block = (target) => {
  const name = `nano-coder-${version}-${target}.tar.gz`;
  if (!sha[name]) {
    console.error(`no checksum for ${name} in ${sums}`);
    process.exit(1);
  }
  const url = `https://github.com/nanobpm/nano-coder/releases/download/v${version}/${name}`;
  return `      url "${url}"\n      sha256 "${sha[name]}"`;
};

writeFileSync(
  out,
  `# Generated on each release by scripts/homebrew-formula.mjs in nanobpm/nano-coder. Don't edit.
class NanoCoder < Formula
  desc "6MB coding agent. Run a fleet on your laptop"
  homepage "https://github.com/nanobpm/nano-coder"
  license "Apache-2.0"

  on_macos do
    on_arm do
${block('aarch64-apple-darwin')}
    end
    on_intel do
${block('x86_64-apple-darwin')}
    end
  end

  on_linux do
    on_arm do
${block('aarch64-unknown-linux-gnu')}
    end
    on_intel do
${block('x86_64-unknown-linux-gnu')}
    end
  end

  def install
    bin.install "nano-coder"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/nano-coder --version")
  end
end
`,
);
