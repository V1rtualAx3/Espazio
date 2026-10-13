// Conventional Commits, enforced in CI (job "Commits"). See docs/RELEASING.md.
module.exports = {
  extends: ["@commitlint/config-conventional"],
  rules: {
    "header-max-length": [2, "always", 100],
    // Bodies and footers carry wrapped prose, URLs and attribution lines.
    "body-max-line-length": [0],
    "footer-max-line-length": [0],
    "subject-case": [0],
  },
};
