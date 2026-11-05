# gearflow

Release checks, security advisories, package updates and build tasks for ALT Linux
maintainers. Checks GitHub tags and OSV, builds gear packages with hasher and
tracks Girar tasks. No third-party Python runtime dependencies.

## Install

Python 3.9+. From the project directory:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install .
```

Release checks need Git; package builds need gear and hasher. The full update and
publication workflow also requires Bash 4.4+, SSH, `gear-store-tags`, `gear-commit`,
`gear-create-tag`, `add_changelog`, working signing and SSH hosts `gitery`/`gyle`.

## Usage

```sh
gearflow check -m scala --updates-only
gearflow check -m scala --vulnerable-only
gearflow task -m scala --all
gearflow task -m scala -w 3
gearflow task show 435564
```

Replace `scala` with your maintainer login. Checks default to Sisyphus; task lists
cover all branches and exclude DONE. Add `--json` or `--no-color` to checks and
task commands. Watch mode stops with `q` or Ctrl+C. OSV checks upstream versions
and cannot account for ALT backports.

## Prepare, build, publish

For updates, prepare metadata first:

```sh
gearflow update --prepare-only ./maven
```

This stops after merge, rules/spec/changelog and stored tags, with progress saved
before the build. Inspect patches and restore disabled components, then build:

```sh
gearflow build ./maven --log /tmp/maven-build.log
```

`build` stages the prepared tree and writes both output streams to the log without
terminal output. It overwrites the log on each attempt, returns the builder's exit
code and stops after hasher. Use it directly for initial builds and retries; no
release tag or saved update is required. Build logs and editor backups are excluded
from staging. An unusable or protected log destination is reported on stderr.

Review the exit status and log before publishing:

```sh
gearflow publish ./maven --gitery-only
```

Publication stages current fixes, runs `gear-commit`, creates a signed tag, switches
`origin` to `gitery:packages/<package>` and pushes the branch/tag. It does not build
or create/start a Girar task. Retry an interrupted publication with the same command
or `gearflow resume ./maven`; Gitery-only intent is preserved.

For the complete interactive update/build/Girar workflow, use `gearflow update DIR`
or `gearflow update URL`. Other helpers: `prepare`, `check-layout`, `migrate-layout`,
`progress` and `rebuild TASK --dry-run`. The latter reads Girar/RDB and displays a
rebuild plan without modifying the task; dependency plans are not ABI comparisons.

Run `gearflow COMMAND --help` for options or `gearflow workflow-help` for advanced
modes and environment settings. The `repokeep` compatibility command remains
available; see [migration notes](MIGRATION.md).

## Development

```sh
python3 -m unittest discover -s tests -t .
```

Tests use fixtures, temporary Git repositories and local HTTP servers.
See [development notes](DEVELOPMENT.md), [fixture provenance](tests/monitor/fixtures/README.md),
[changelog](CHANGELOG.md) and [improvement ideas](SUGGESTIONS.md). [MIT License](LICENSE).
