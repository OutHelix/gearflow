# Changelog

## 0.0.6 — 2026-11-25

- Build the selected package, initialize hasher once, and build dependencies
  with `hsh`. Save preparation progress.
- Add `rebuild --clear` to remove local rebuild directories after confirmation.
- Keep individual failure logs beside `rebuild.log`.
- Fall back to the SRPM import repository when a rebuild tag cannot be cloned
  from the gear repository.
- Align rebuild log columns and show the status before the package and version.

## 0.0.5 — 2026-11-25

- Move Girar reverse dependency planning and submission to `task rebuild`.
- Add local `rebuild` to clone and build reverse dependencies in RDB order
  with hasher, with optional filtering of existing Beehive failures.
- Save the rebuild queue and log each package as `BUILDING`, `DONE` or
  `FAILED`. Resume retries the interrupted package.
- Shorten the README command and option reference.

## 0.0.4 — 2026-11-23

- Include migrated packaging files in the layout commit even when their new paths
  match Git ignore rules. Report staging and commit failures immediately.
- Honor `update DIR` after a layout migration commit when the release tag still
  points to an earlier commit.
- Reuse an existing `gear-commit` during Gitery-only publication, recreate the
  signed release tag, and force-push the package branch and tag to Gitery.

## 0.0.2 — 2026-11-05

- Add `build DIR --log FILE`: quiet hasher builds of prepared trees with exact
  build exit status, including initial builds and retries.
- Add `update --prepare-only`: stop after preparing metadata and stored tags.
- Add `publish DIR --gitery-only`: commit, sign and push independently of builds
  and Girar, retaining progress and publication intent across interrupted pushes.
- Exclude registered build logs and editor backups from staging and publication.
- Forward build interruption signals to the builder process group.

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
