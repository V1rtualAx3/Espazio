// semantic-release configuration.
// - main          → release X.Y.Z (tag vX.Y.Z), CHANGELOG.md committed, beta pre-releases deleted
// - work branches → pre-release X.Y.Z-beta.N on every releasable commit (no changelog commit)
// Only the branch being built is declared as the prerelease branch, so every work branch can use
// the plain "beta" identifier (semantic-release requires one unique identifier per declared branch).
const current = process.env.GITHUB_REF_NAME || "";
const isMain = current === "main";
const workBranch = /^(claude|feature|feat|fix)\//.test(current);

const assets = [
  { path: "build/Espazio-*.dmg", label: "Espazio ${nextRelease.version} (DMG)" },
  { path: "build/Espazio-*.pkg", label: "Espazio ${nextRelease.version} (PKG)" },
];

module.exports = {
  branches: ["main", ...(workBranch ? [{ name: current, prerelease: "beta" }] : [])],
  tagFormat: "v${version}",
  plugins: [
    ["@semantic-release/commit-analyzer", {
      // Conventional Commits (enforced by commitlint in CI): feat → minor, fix → patch,
      // feat!/BREAKING CHANGE → major; perf, refactor and build also produce a patch.
      preset: "conventionalcommits",
      releaseRules: [
        { type: "perf", release: "patch" },
        { type: "refactor", release: "patch" },
        { type: "build", release: "patch" },
      ],
    }],
    ["@semantic-release/release-notes-generator", {
      preset: "conventionalcommits",
      presetConfig: {
        types: [
          { type: "feat", section: "Fonctionnalités" },
          { type: "fix", section: "Corrections" },
          { type: "perf", section: "Performance" },
          { type: "refactor", section: "Restructuration" },
          { type: "build", section: "Build et distribution" },
          { type: "docs", section: "Documentation", hidden: true },
          { type: "test", hidden: true },
          { type: "ci", hidden: true },
          { type: "chore", hidden: true },
          { type: "style", hidden: true },
        ],
      },
    }],
    ...(isMain ? [["@semantic-release/changelog", { changelogFile: "CHANGELOG.md", changelogTitle: "# Changelog" }]] : []),
    ["@semantic-release/exec", {
      prepareCmd: "scripts/release-build.sh ${nextRelease.version}",
      // Stable releases only: DMG and PKG also published to GitHub Packages (ghcr.io).
      ...(isMain ? { publishCmd: "scripts/publish-package.sh ${nextRelease.version}" } : {}),
      // Betas are superseded by the stable release; on work branches, only drop the legacy
      // branch-named pre-releases.
      successCmd: isMain ? "scripts/cleanup-prereleases.sh --all" : "scripts/cleanup-prereleases.sh --legacy",
    }],
    ...(isMain ? [["@semantic-release/git", {
      assets: ["CHANGELOG.md"],
      message: "chore(release): ${nextRelease.version} [skip ci]\n\n${nextRelease.notes}",
    }]] : []),
    ["@semantic-release/github", {
      assets,
      successCommentCondition: false,
      failCommentCondition: false,
      releasedLabels: false,
    }],
  ],
};
