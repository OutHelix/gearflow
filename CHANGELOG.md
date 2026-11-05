# Changelog

## 0.0.1 — 2026-11-05

First gearflow release, combining repokeep monitoring and package update workflows.

- Check upstream GitHub releases and OSV advisories for ALT Linux packages.
- View Girar tasks, architectures, sources and approvals, with watch and JSON output.
- Prepare packaging layouts, update source tags/spec/changelog, build with hasher
  and submit packages and reverse dependency rebuilds to Girar.
- Resume interrupted updates using existing Git config checkpoints.
- Provide validated CLI arguments, command-specific help and installable wheel/sdist.
- Remove the standalone `gear-update-upstream` launcher; use `gearflow update`.

The historical `repokeep/v*` tags refer to repokeep releases, not gearflow versions.
