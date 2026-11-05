"""Build a prepared gear tree, keeping build output and publication separate."""

import os
import shutil
import signal
import subprocess
import sys
import threading
from pathlib import Path
from typing import Optional

LOG_CONFIG_KEY = "gearflow.build-log"
BUILD_COMMAND = [
    "gear",
    "--commit",
    "--hasher",
    "--",
    "hsh",
    "--no-sisyphus-check=gpg",
    "-v",
    "--mountpoints=/proc",
]


class BuildError(ValueError):
    """Invalid repository or failed preparation before invoking the builder."""


def _run_builder(root: Path, output) -> int:
    with subprocess.Popen(
        BUILD_COMMAND,
        cwd=root,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    ) as process:
        previous = {}

        def forward(signum, _frame):
            try:
                os.killpg(process.pid, signum)
            except ProcessLookupError:
                pass

        try:
            if threading.current_thread() is threading.main_thread():
                for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
                    previous[signum] = signal.signal(signum, forward)
            status = process.wait()
            return status if status >= 0 else 128 - status
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def _git(directory: Path, *args: str, check: bool = True):
    result = subprocess.run(
        ["git", *args],
        cwd=directory,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and result.returncode:
        raise BuildError(result.stderr.strip() or f"git {args[0]} failed")
    return result


def repository_root(directory: Path) -> Path:
    return Path(
        _git(directory, "rev-parse", "--show-toplevel").stdout.strip()
    ).resolve()


def stage_changes(directory: Optional[Path] = None) -> None:
    """Stage the working tree while excluding registered logs and editor backups."""
    root = repository_root(directory or Path.cwd())
    result = _git(root, "config", "--null", "--get-all", LOG_CONFIG_KEY, check=False)
    if result.returncode not in (0, 1):
        raise BuildError(result.stderr.strip())
    log_paths = set()
    for value in result.stdout.split("\0"):
        if not value:
            continue
        try:
            relative = (root / value).relative_to(root).as_posix()
        except ValueError:
            continue
        if relative != ".":
            log_paths.add(relative)
    pathspecs = [".", ":(exclude,glob)**/*~"]
    pathspecs.extend(f":(exclude,literal){path}" for path in sorted(log_paths))
    _git(root, "add", "-A", "--", *pathspecs)

    # Exclusions also apply to files staged before this command was called.
    staged = _git(root, "diff", "--cached", "--name-only", "-z").stdout.split("\0")
    excluded = [
        path for path in staged if path and (path.endswith("~") or path in log_paths)
    ]
    if excluded:
        if _git(root, "rev-parse", "--verify", "HEAD", check=False).returncode == 0:
            _git(root, "reset", "-q", "HEAD", "--", *excluded)
        else:
            _git(root, "rm", "--cached", "--force", "--", *excluded)


def _check_log_destination(root: Path, destination: Path) -> None:
    metadata = [root / ".git"]
    for option in ("--absolute-git-dir", "--git-common-dir"):
        path = Path(_git(root, "rev-parse", option).stdout.strip())
        metadata.append((root / path).resolve())
    for path in metadata:
        if destination == path or path in destination.parents:
            raise BuildError("the build log must be outside Git metadata")
    try:
        relative = destination.relative_to(root).as_posix()
    except ValueError:
        return
    tracked = _git(
        root, "ls-files", "--error-unmatch", "--", f":(literal){relative}", check=False
    )
    if tracked.returncode == 0:
        raise BuildError("the build log must not overwrite a tracked package file")
    if tracked.returncode != 1:
        raise BuildError(tracked.stderr.strip())


def build_package(directory: str, log_file: str) -> int:
    """Run one build, returning its status with both streams redirected to the log."""
    try:
        destination = Path(log_file).expanduser().resolve()
    except (OSError, RuntimeError) as error:
        print(f"ERROR: Cannot open build log: {error}", file=sys.stderr)
        return 1
    root = None
    preflight_error = None
    try:
        root = repository_root(Path(directory).expanduser())
    except (OSError, BuildError) as error:
        preflight_error = str(error)
    if root is not None:
        try:
            _check_log_destination(root, destination)
        except (OSError, BuildError) as error:
            # A protected destination cannot be opened to report its own error.
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
    try:
        output = destination.open("wb")
    except OSError as error:
        print(f"ERROR: Cannot open build log: {error}", file=sys.stderr)
        return 1
    with output:
        try:
            if root is None:
                raise BuildError(preflight_error or "Repository not found")
            for command in ("gear", "hsh"):
                if shutil.which(command) is None:
                    raise BuildError(f"Required command not found: {command}")
            if not (root / ".gear/rules").is_file():
                raise BuildError(".gear/rules not found")
            if _git(root, "diff", "--name-only", "--diff-filter=U").stdout.strip():
                raise BuildError("resolve merge conflicts before building")
            if (
                _git(
                    root, "rev-parse", "-q", "--verify", "MERGE_HEAD", check=False
                ).returncode
                == 0
            ):
                raise BuildError("finish the upstream merge before building")
            logs = _git(
                root, "config", "--null", "--get-all", LOG_CONFIG_KEY, check=False
            )
            if logs.returncode not in (0, 1):
                raise BuildError(logs.stderr.strip())
            try:
                relative_log = destination.relative_to(root).as_posix()
            except ValueError:
                relative_log = None
            if relative_log is not None and relative_log not in logs.stdout.split("\0"):
                _git(
                    root,
                    "config",
                    "--local",
                    "--add",
                    LOG_CONFIG_KEY,
                    relative_log,
                )
            stage_changes(root)
            return _run_builder(root, output)
        except (OSError, BuildError) as error:
            output.write(f"ERROR: {error}\n".encode())
            return 1
        except KeyboardInterrupt:
            output.write(b"Build interrupted.\n")
            return 130
