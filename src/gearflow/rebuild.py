"""Persist and run a local queue of package rebuilds."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from dataclasses import asdict
from pathlib import Path
from typing import Optional
from urllib.parse import quote

from .build import HASHER_ARGS, BuildInterrupted, run_build_command
from .girar import package_name
from .rdb import SourceRelease, local_rebuild_plan

CHECKPOINT = "progress.json"
LOG = "rebuild.log"
SUFFIX = "-rebuild"


def _choose(directories: list[Path], *, resume: bool) -> Path:
    if not directories:
        if resume:
            raise ValueError("no saved rebuild directories in the current directory")
        raise ValueError("no gear package directories in the current directory")
    if resume and len(directories) == 1:
        return directories[0]
    for index, directory in enumerate(directories, 1):
        print(f"  {index}. {directory.name}")
    while True:
        number = input(
            "Select a rebuild directory: " if resume else "Select a package: "
        )
        try:
            index = int(number)
        except ValueError:
            index = 0
        if 1 <= index <= len(directories):
            return directories[index - 1]
        print("Enter a number from the list.")


def _include_ftbfs() -> bool:
    while True:
        answer = input("Include packages already failing in Beehive? [y/N]: ")
        answer = answer.strip().lower()
        if answer in ("y", "yes", "д", "да"):
            return True
        if answer in ("", "n", "no", "н", "нет"):
            return False
        print("Enter yes or no.")


def _require_tools(*commands: str) -> None:
    for command in commands:
        if shutil.which(command) is None:
            raise ValueError(f"required command not found: {command}")


def _describe(directory: Path) -> str:
    result = subprocess.run(
        ["gear", "--describe", "--commit"],
        cwd=directory,
        capture_output=True,
        text=True,
    )
    fields = result.stdout.split()
    if result.returncode or len(fields) != 3:
        detail = result.stderr.strip() or "gear --describe returned no package name"
        raise ValueError(f"cannot identify {directory.name}: {detail}")
    return package_name(fields[0])


def _write_atomic(path: Path, content: str) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False
    ) as temporary:
        temporary_path = Path(temporary.name)
        try:
            temporary.write(content)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary.close()
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)


def _load(directory: Path) -> tuple[list[SourceRelease], list[str]]:
    document = json.loads((directory / CHECKPOINT).read_text(encoding="utf-8"))
    try:
        plan = [SourceRelease(**row) for row in document["plan"]]
        results = document["results"]
        valid = (
            document["format"] == 1
            and isinstance(results, list)
            and len(results) <= len(plan)
            and all(status in ("DONE", "FAILED") for status in results)
            and len({package.name for package in plan}) == len(plan)
        )
    except (KeyError, TypeError):
        valid = False
    if not valid:
        raise ValueError("invalid saved rebuild progress")
    return plan, results


def _result_line(index: int, total: int, package: SourceRelease, status: str) -> str:
    width = len(str(total))
    return f"[{index:>{width}}/{total}] {status:<8} {package.name}.git={package.tag}"


def _write_log(
    directory: Path, plan: list[SourceRelease], results: list[str], *, building=False
) -> None:
    statuses = [*results, "BUILDING"] if building else results
    _write_atomic(
        directory / LOG,
        "".join(
            _result_line(index, len(plan), package, status) + "\n"
            for index, (package, status) in enumerate(zip(plan, statuses), 1)
        ),
    )


def _clone(directory: Path, destination: Path, package: SourceRelease) -> int:
    name = quote(package.name, safe="")
    for collection in ("gears", "srpms"):
        url = f"https://git.altlinux.org/{collection}/{name[0]}/{name}.git"
        # A failed attempt cannot leave a partial checkout for the next source.
        with tempfile.TemporaryDirectory(prefix=".clone-", dir=directory) as temp:
            checkout = Path(temp) / "package"
            status = run_build_command(
                ["git", "clone", "--branch", package.tag, "--", url, str(checkout)],
                directory,
                None,
                stop_on_signal=True,
            )
            if status == 0:
                checkout.rename(destination)
                return 0
        if collection == "gears":
            print(f"{package.name}: trying the SRPM repository", flush=True)
    return status


def _build(directory: Path, package: SourceRelease) -> int:
    destination = directory / f"{package.name}.git"
    if destination.is_symlink():
        raise ValueError(f"unexpected symlink: {destination}")
    if not destination.exists():
        status = _clone(directory, destination, package)
        if status:
            return status
    command = [
        "gear",
        f"--tree-ish=refs/tags/{package.tag}",
        *HASHER_ARGS,
    ]
    return run_build_command(command, destination, None, stop_on_signal=True)


def _run_queue(directory: Path, new_plan: Optional[list[SourceRelease]]) -> int:
    import fcntl

    lock_path = directory / ".rebuild.lock"
    with os.fdopen(
        os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "rb"
    ) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f"a rebuild is already running in {directory}") from None
        if new_plan is None:
            plan, results = _load(directory)
        else:
            plan, results = new_plan, []

        def save_progress() -> None:
            _write_atomic(
                directory / CHECKPOINT,
                json.dumps({"format": 1, "plan": records, "results": results}) + "\n",
            )

        records = [asdict(package) for package in plan]
        if new_plan is not None:
            save_progress()
        if new_plan is not None or len(results) == len(plan):
            _write_log(directory, plan, results)
        if len(results) < len(plan):
            _require_tools("git", "gear", "hsh")
        for index, package in enumerate(plan[len(results) :], len(results) + 1):
            _write_log(directory, plan, results, building=True)
            print(_result_line(index, len(plan), package, "BUILDING"), flush=True)
            try:
                status = _build(directory, package)
            except BuildInterrupted as error:
                print(
                    "Rebuild interrupted. Use --resume to retry this package.",
                    file=sys.stderr,
                )
                return error.status
            except (OSError, ValueError) as error:
                print(f"{package.name}: {error}", file=sys.stderr)
                status = 1
            result = "DONE" if status == 0 else "FAILED"
            results.append(result)
            save_progress()
            _write_log(directory, plan, results)
            print(_result_line(index, len(plan), package, result), flush=True)
    print(f"Results: {directory / LOG}")
    return int("FAILED" in results)


def rebuild_packages(cwd: Path, *, resume: bool, ftbfs: Optional[bool]) -> int:
    try:
        directories = sorted(
            (path for path in cwd.iterdir() if path.is_dir() and not path.is_symlink()),
            key=lambda path: path.name.casefold(),
        )
        if resume:
            saved = [
                path
                for path in directories
                if path.name.endswith(SUFFIX) and (path / CHECKPOINT).is_file()
            ]
            return _run_queue(_choose(saved, resume=True), None)

        packages = [
            path
            for path in directories
            if (path / ".git").exists()
            and ((path / ".gear/rules").is_file() or (path / ".gear-rules").is_file())
        ]
        package = _choose(packages, resume=False)
        directory = package.with_name(f"{package.name.removesuffix('.git')}{SUFFIX}")
        if directory.exists() or directory.is_symlink():
            raise ValueError(
                f"{directory} already exists. Use --resume to continue it."
            )
        _require_tools("git", "gear", "hsh")
        source = _describe(package)
        if ftbfs is None:
            ftbfs = _include_ftbfs()
        plan = local_rebuild_plan(
            os.environ.get("RDB_API_URL") or "https://rdb.altlinux.org/api",
            os.environ.get("REBUILD_DEPTH") or "1",
            os.environ.get("REBUILD_DPTYPE") or "both",
            os.environ.get("TARGET_BRANCH") or "sisyphus",
            source,
            ftbfs=ftbfs,
        )
        directory.mkdir()
        return _run_queue(directory, plan)
    except (OSError, ValueError, EOFError) as error:
        print(f"Cannot rebuild: {error or 'no input'}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print(
            "\nRebuild interrupted. Use --resume if progress was saved.",
            file=sys.stderr,
        )
        return 130
