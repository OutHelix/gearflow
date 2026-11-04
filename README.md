# gearflow

Release checks, security advisories, package updates and build tasks for ALT Linux
maintainers. Combines repokeep monitoring with the gear-update-upstream workflow:
GitHub tags, OSV, gear/hasher builds, resumable updates and Girar rebuilds.

## Install

Python 3.9+; no third-party Python runtime dependencies. From the project directory:

```sh
python3 -m venv .venv
. .venv/bin/activate
python -m pip install .
```

Release checks need Git. Package updates additionally require Bash 4.4+, SSH,
gear, hasher, `gear-store-tags`, `gear-commit`, `gear-create-tag`, `add_changelog`,
working Git signing and SSH hosts `gitery`/`gyle`.

## Usage

```sh
gearflow check -m scala --updates-only
gearflow check -m scala --vulnerable-only
gearflow update ./maven
gearflow update https://git.altlinux.org/gears/m/maven.git
gearflow task -m scala --all
gearflow task show 435564
gearflow resume ./maven
gearflow rebuild 123456 --dry-run
```

Replace `scala` with your maintainer login. `check` defaults to Sisyphus; task
lists cover all branches and exclude DONE. Add `--json` or `--no-color` to checks
and task commands. `task -m scala -w 3` watches until `q` or Ctrl+C.
Use `prepare`, `check-layout`, `migrate-layout` and `progress` for package helpers;
run `gearflow --help` or `gearflow COMMAND --help` for options.

Updates create commits and signed tags, switch `origin` to
`gitery:packages/<package>`, push and submit to Girar after build confirmation.
Resolve merge conflicts, finish `git commit --no-edit`, then run `gearflow resume`.
`rebuild --dry-run` reads Girar/RDB and displays the plan without changing the task.
OSV cannot account for ALT backports; dependency plans are not ABI comparisons.

Existing `repokeep` and `gear-update-upstream` commands remain available.
See [migration notes](MIGRATION.md) for old commands and config compatibility.

## Development

```sh
python3 -m unittest discover -s tests -t .
```

Tests use fixtures, temporary Git repositories and local HTTP servers.
See [development notes](DEVELOPMENT.md), [fixture provenance](tests/monitor/fixtures/README.md)
and [improvement ideas](SUGGESTIONS.md). [MIT License](LICENSE).
