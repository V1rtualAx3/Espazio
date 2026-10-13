// semantic-release configuration.
// - main            → releases 1.0.0, 1.1.0… (tag vX.Y.Z)
// - work branches   → betas 1.0.0-beta.1, 1.0.0-beta.2… until the next release on main
// Only the branch being built is declared as the prerelease branch, so every work branch can use
// the plain "beta" identifier (semantic-release requires one unique identifier per declared branch).
const current = process.env.GITHUB_REF_NAME || "";
const workBranch = /^(claude|feature|feat|fix)\//.test(current);

module.exports = {
  branches: ["main", ...(workBranch ? [{ name: current, prerelease: "beta" }] : [])],
  tagFormat: "v${version}",
  plugins: [
    ["@semantic-release/commit-analyzer", {
      preset: "conventionalcommits",
      releaseRules: [
        { type: "perf", release: "patch" },
        { type: "refactor", release: "patch" },
        { type: "build", release: "patch" },
      ],
    }],
    ["@semantic-release/release-notes-generator", { preset: "conventionalcommits" }],
    ["@semantic-release/exec", { prepareCmd: "scripts/release-build.sh ${nextRelease.version}" }],
    ["@semantic-release/github", {
      assets: [
        { path: "build/Espazio-*.dmg", label: "Espazio ${nextRelease.version} (DMG)" },
        { path: "build/Espazio-*.pkg", label: "Espazio ${nextRelease.version} (PKG)" },
      ],
      successCommentCondition: false,
      failCommentCondition: false,
      releasedLabels: false,
    }],
  ],
};
