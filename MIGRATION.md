# repokeep → gearflow

Gearflow is the maintained project for both monitoring and gear package updates.
Repokeep's Git history is merged into this repository. Its original release tags
are retained under `repokeep/v0.1.0`, `repokeep/v0.1.1` and `repokeep/v0.2.0`.
Original release downloads remain available in the archived
[OutHelix/repokeep repository](https://github.com/OutHelix/repokeep/releases).

The import uses repokeep commit `af5b98232298e7d2b1d98ffe5d5588ca2730939b`.
The existing MIT license covers both codebases. Monitoring source now lives under
`src/gearflow/monitor/`; its fixtures are preserved under `tests/monitor/fixtures/`.

## Commands

| Previous command | Unified command |
| --- | --- |
| `repokeep update -m scala` | `gearflow check -m scala` |
| `repokeep task -m scala --all` | `gearflow task -m scala --all` |
| `repokeep task show 123` | `gearflow task show 123` |
| `gear-update-upstream` | `gearflow update` |
| `gear-update-upstream URL` | `gearflow update URL` |
| `gear-update-upstream --prepare-package DIR` | `gearflow prepare DIR` |
| `gear-update-upstream --resume DIR` | `gearflow resume DIR` |
| `gear-update-upstream --progress DIR` | `gearflow progress DIR` |
| `gear-update-upstream --scan-task 123 --dry-run` | `gearflow rebuild 123 --dry-run` |

`gearflow update DIR` uses an existing local checkout. Monitoring commands never
start the package update workflow. `gearflow` without arguments prints help.
Legacy `repokeep`, `python -m repokeep` and root workflow flags such as
`gearflow --resume DIR` continue to work. The standalone `gear-update-upstream`
file and its installed entry point were removed for gearflow 0.0.1; use the
commands above. Compatibility Python imports forward to the same monitoring
modules rather than a second code copy.

## Install and configuration

Install into a fresh venv using the README instructions. If reusing an environment
with repokeep installed, uninstall that distribution before installing gearflow:
both provide the compatibility `repokeep` command and Python import package.

`gearflow check` reads `$XDG_CONFIG_HOME/gearflow/config.json` (by default
`~/.config/gearflow/config.json`). If absent, it reads the existing repokeep config.
The legacy `repokeep` CLI retains its original config path. Explicit `--config`
always takes precedence. The JSON schema and CLI overrides remain unchanged.

Workflow environment variables and saved Git config checkpoints retain their
original names and formats. Existing in-progress updates can be resumed.
