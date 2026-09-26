// Conventional Commits, enforced on PR commits (.github/workflows/commitlint.yml)
// and optionally locally (.githooks/commit-msg). semantic-release reads the
// types to pick the next version; see RELEASING.md.
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    // Bodies and footers carry URLs, logs and Co-authored-by trailers.
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
  // Release commits carry generated notes; Git's own merge/revert subjects.
  ignores: [(message) => message.startsWith('chore(release): ')],
};
