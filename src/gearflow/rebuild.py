"""Persist and run a local queue of package rebuilds."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Optional
from urllib.parse import quote

from .build import BUILD_COMMAND, BuildInterrupted, run_build_command
from .girar import package_name
from .rdb import SourceRelease, local_rebuild_plan

CHECKPOINT = "progress.json"
LOG = "rebuild.log"
SUFFIX = "-rebuild"
LOCK = ".rebuild.lock"


@dataclass
class RebuildProgress:
    plan: list[SourceRelease]
    results: list[str]
    source: Optional[str] = None
    preparation: str = "source"


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


def _confirm(prompt: str) -> bool:
    while True:
        answer = input(f"{prompt} [y/N]: ")
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


def _load(directory: Path) -> RebuildProgress:
    document = json.loads((directory / CHECKPOINT).read_text(encoding="utf-8"))
    try:
        plan = [SourceRelease(**row) for row in document["plan"]]
        results = document["results"]
        source = document.get("source")
        preparation = document.get(
            "preparation", "ready" if len(results) == len(plan) else "source"
        )
        valid = (
            document["format"] == 1
            and isinstance(results, list)
            and len(results) <= len(plan)
            and all(status in ("DONE", "FAILED") for status in results)
            and len({package.name for package in plan}) == len(plan)
            and (
                source is None
                or (
                    isinstance(source, str)
                    and Path(source).name == source
                    and source.removesuffix(".git") + SUFFIX == directory.name
                )
            )
            and preparation in ("source", "init", "ready")
            and (preparation != "init" or source is not None)
        )
    except (AttributeError, KeyError, TypeError):
        valid = False
    if not valid:
        raise ValueError("invalid saved rebuild progress")
    return RebuildProgress(plan, results, source, preparation)


def _is_gear_checkout(path: Path) -> bool:
    return (
        path.is_dir()
        and not path.is_symlink()
        and (path / ".git").exists()
        and ((path / ".gear/rules").is_file() or (path / ".gear-rules").is_file())
    )


def _source_checkout(directory: Path, source: Optional[str]) -> Path:
    if source is not None:
        path = directory.with_name(source)
        if not _is_gear_checkout(path):
            raise ValueError(f"source package directory is missing or invalid: {path}")
        return path
    # Checkpoints created before source builds only identify the checkout by folder.
    name = directory.name.removesuffix(SUFFIX)
    candidates = [
        path
        for path in (directory.with_name(name), directory.with_name(name + ".git"))
        if _is_gear_checkout(path)
    ]
    if len(candidates) == 1:
        return candidates[0]
    if not candidates:
        raise ValueError(f"no source package directory found for {directory.name}")
    return _choose(candidates, resume=False)


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
                status = run_build_command(
                    ["git", "checkout", "--detach", f"refs/tags/{package.tag}"],
                    checkout,
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
    return run_build_command(BUILD_COMMAND, destination, None, stop_on_signal=True)


@contextmanager
def _rebuild_lock(directory: Path):
    import fcntl

    with os.fdopen(
        os.open(directory / LOCK, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600), "rb"
    ) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError(f"a rebuild is already running in {directory}") from None
        if not os.path.samestat(os.fstat(lock.fileno()), (directory / LOCK).lstat()):
            raise ValueError(f"the rebuild directory changed: {directory}")
        yield


def _run_queue(directory: Path, progress: Optional[RebuildProgress] = None) -> int:
    with _rebuild_lock(directory):
        fresh = progress is not None
        if progress is None:
            progress = _load(directory)
        plan, results = progress.plan, progress.results

        def save_progress() -> None:
            _write_atomic(
                directory / CHECKPOINT,
                json.dumps(
                    {
                        "format": 1,
                        "plan": records,
                        "results": results,
                        "source": progress.source,
                        "preparation": progress.preparation,
                    }
                )
                + "\n",
            )

        records = [asdict(package) for package in plan]
        if fresh:
            save_progress()
        if fresh or len(results) == len(plan):
            _write_log(directory, plan, results)
        if len(results) < len(plan) or progress.preparation == "source":
            _require_tools("git", "gear", "hsh")
        if progress.preparation == "source":
            source = _source_checkout(directory, progress.source)
            progress.source = source.name
            save_progress()
            print(f"Building source package: {source.name}", flush=True)
            status = run_build_command(BUILD_COMMAND, source, None, stop_on_signal=True)
            if status:
                print(
                    "Source package build failed. Use --resume to retry.",
                    file=sys.stderr,
                )
                return status
            progress.preparation = "init"
            save_progress()
        if progress.preparation == "init":
            _require_tools("hsh")
            print("Initializing hasher", flush=True)
            status = run_build_command(
                ["hsh", "--initroot-only"], directory, None, stop_on_signal=True
            )
            if status:
                print(
                    "Hasher initialization failed. Use --resume to retry.",
                    file=sys.stderr,
                )
                return status
            progress.preparation = "ready"
            save_progress()
        for index, package in enumerate(plan[len(results) :], len(results) + 1):
            _write_log(directory, plan, results, building=True)
            print(_result_line(index, len(plan), package, "BUILDING"), flush=True)
            try:
                status = _build(directory, package)
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


def _child_directories(cwd: Path) -> list[Path]:
    return sorted(
        (path for path in cwd.iterdir() if path.is_dir() and not path.is_symlink()),
        key=lambda path: path.name.casefold(),
    )


def clear_rebuilds(cwd: Path) -> int:
    try:
        directories = [
            path
            for path in _child_directories(cwd)
            if path.name.endswith(SUFFIX) and not (path / ".git").exists()
        ]
        if not directories:
            print("No rebuild directories in the current directory.")
        failed = False
        for directory in directories:
            try:
                original = directory.lstat()
                if not _confirm(f"Delete rebuild directory {str(directory)!r}?"):
                    continue
                if not os.path.samestat(original, directory.lstat()):
                    raise ValueError("the directory changed after it was listed")
                with tempfile.TemporaryDirectory(
                    prefix=".clear-rebuild-", dir=cwd
                ) as temporary:
                    with _rebuild_lock(directory):
                        if not os.path.samestat(original, directory.lstat()):
                            raise ValueError(
                                "the directory changed after it was listed"
                            )
                        # Remove it from the queue list while still holding its lock.
                        directory.rename(Path(temporary) / directory.name)
                print(f"Deleted {directory}")
            except (OSError, ValueError) as error:
                print(f"Cannot delete {directory}: {error}", file=sys.stderr)
                failed = True
        return int(failed)
    except (OSError, EOFError) as error:
        print(f"Cannot clear rebuilds: {error or 'no input'}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nRebuild cleanup interrupted.", file=sys.stderr)
        return 130


def rebuild_packages(cwd: Path, *, resume: bool, ftbfs: Optional[bool]) -> int:
    try:
        directories = _child_directories(cwd)
        if resume:
            saved = [
                path
                for path in directories
                if path.name.endswith(SUFFIX) and (path / CHECKPOINT).is_file()
            ]
            return _run_queue(_choose(saved, resume=True))

        packages = [path for path in directories if _is_gear_checkout(path)]
        package = _choose(packages, resume=False)
        directory = package.with_name(f"{package.name.removesuffix('.git')}{SUFFIX}")
        if directory.exists() or directory.is_symlink():
            raise ValueError(
                f"{directory} already exists. Use --resume to continue it."
            )
        _require_tools("git", "gear", "hsh")
        source = _describe(package)
        if ftbfs is None:
            ftbfs = _confirm("Include packages already failing in Beehive?")
        plan = local_rebuild_plan(
            os.environ.get("RDB_API_URL") or "https://rdb.altlinux.org/api",
            os.environ.get("REBUILD_DEPTH") or "1",
            os.environ.get("REBUILD_DPTYPE") or "both",
            os.environ.get("TARGET_BRANCH") or "sisyphus",
            source,
            ftbfs=ftbfs,
        )
        directory.mkdir()
        return _run_queue(directory, RebuildProgress(plan, [], package.name))
    except (OSError, ValueError, EOFError) as error:
        print(f"Cannot rebuild: {error or 'no input'}", file=sys.stderr)
        return 1
    except BuildInterrupted as error:
        print("Rebuild interrupted. Use --resume to continue.", file=sys.stderr)
        return error.status
    except KeyboardInterrupt:
        print(
            "\nRebuild interrupted. Use --resume if progress was saved.",
            file=sys.stderr,
        )
        return 130
