# Development

The `gearflow` Python package provides one CLI for monitoring and package updates.
There are no third-party runtime dependencies.

## Layout

- `src/gearflow/cli.py`: common CLI and dispatch to monitoring or updates.
- `src/gearflow/monitor/`: release/OSV checks, task status, rendering and workers,
  imported from repokeep. Its CLI also serves the legacy `repokeep` command.
- `src/gearflow/girar.py`, `rdb.py`: live SSH task parsing and rebuild plans.
- `src/gearflow/services.py`: internal text protocol used by Bash.
- `src/gearflow/shell/`: Git/gear operations, packaging layout, spec/tag handling,
  builds, saved state and interactive update workflow.
- `src/repokeep/`: compatibility imports; uses the same monitoring implementation.
- `tests/monitor/`: imported monitoring tests, fixture provenance and network guard.
- `tests/test_*.py`: update workflow and unified CLI regression checks.

The monitor reads Taskoteka/ALTRepo HTTP responses; the update workflow reads live
Girar SSH state before changing a task. These sources have different freshness and
formats, so their parsers remain separate. Bash modules share workflow state and
load relative to `shell/main.sh`. Python services use the launcher's interpreter.

## Checks

```sh
python3 -m unittest discover -s tests -t .
```

The default suite blocks external network access. Worker/watch tests use loopback
HTTP servers and real child processes. Workflow tests use temporary Git repos;
no test runs hasher, signs release tags, pushes packages or submits Girar builds.
Only explicitly marked temporary fixtures can invoke local Git through the audit
guard. API fixtures and hashes are preserved from repokeep.

Optional live checks require explicit selection:

```sh
GEARFLOW_LIVE_TESTS=1 python3 -m unittest tests.monitor.live_checks
```

The legacy `REPOKEEP_LIVE_TESTS=1` variable is also supported.

Install editable with `python -m pip install -e .`. Install the `build` development
tool and run `python -m build` for wheel/sdist archives. CI tests Python 3.9, 3.13
and 3.14, then installs both archives outside the checkout and checks all entry
points. Run directly from a checkout with `PYTHONPATH=src python3 -m gearflow` or
`./gear-update-upstream --help`.

Keep the `gear-update-upstream.resume` and `gear-update-upstream.last-update`
Git config keys and legacy checkpoint reader compatible. An unknown Girar
submission result must require a user decision before submission is repeated.
