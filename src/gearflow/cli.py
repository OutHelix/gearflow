"""Launch the packaged Bash workflow with the current Python interpreter."""

import argparse
import os
from pathlib import Path
import shlex
import shutil
import sys
from typing import Optional, Sequence

from . import __version__


def launch_update(argv: Optional[Sequence[str]] = None, repository=None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args == ["--version"]:
        print(f"gearflow {__version__}")
        return 0

    bash = shutil.which("bash")
    if bash is None:
        print("ERROR: gearflow requires Bash 4.4 or newer.", file=sys.stderr)
        return 1

    env = os.environ.copy()
    # Services must use the same interpreter as this entry point, including venvs.
    env["GEARFLOW_PYTHON"] = sys.executable
    if Path(sys.argv[0]).name == "__main__.py":
        env["GEARFLOW_PROGRAM"] = "gearflow"
        env["GEARFLOW_COMMAND"] = shlex.join([sys.executable, "-m", "gearflow"])
    else:
        env["GEARFLOW_PROGRAM"] = Path(sys.argv[0]).name
        env["GEARFLOW_COMMAND"] = shlex.quote(os.path.abspath(sys.argv[0]))

    script = Path(__file__).resolve().parent / "shell" / "main.sh"
    # Replace the process so interactive input, signals and exit codes pass through.
    try:
        if repository is not None:
            os.chdir(repository)
        os.execve(bash, [bash, str(script), *args], env)
    except OSError as error:
        print(f"ERROR: Could not start the gearflow workflow: {error}", file=sys.stderr)
        return 1


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="gearflow",
        description="Release checks, security advisories, gear updates and Girar tasks for ALT Linux.",
        epilog="Legacy workflow flags remain available: gearflow --resume DIR, --progress DIR, --scan-task TASK.",
    )
    root.add_argument("--version", action="version", version=f"%(prog)s {__version__}")
    commands = root.add_subparsers(dest="command")
    for name, help_text in (
        ("check", "check upstream releases and OSV advisories"),
        ("update", "update and build a local gear package or clone a repository URL"),
        ("task", "list or inspect Girar tasks; supports watch mode"),
        ("prepare", "prepare packaging files under altlinux/"),
        ("check-layout", "check package layout without changes"),
        ("migrate-layout", "migrate packaging layout interactively"),
        ("resume", "continue a saved package update"),
        ("progress", "show saved update progress"),
        ("rebuild", "plan and add reverse dependency rebuilds for a Girar task"),
    ):
        commands.add_parser(name, help=help_text, add_help=False)
    return root


def legacy_update_main() -> int:
    """Preserve the original gear-update-upstream interface."""
    return launch_update()


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args in (["-h"], ["--help"]):
        parser().print_help()
        return 0
    if args[0] in ("check", "task"):
        from .monitor.cli import main as monitor_main

        return monitor_main(args, prog="gearflow", check_command="check")
    if args[0] == "update":
        rest = args[1:]
        if rest and Path(rest[0]).is_dir():
            if len(rest) != 1:
                parser().error("update DIR accepts one directory; use resume DIR to continue")
            return launch_update([], repository=rest[0])
        return launch_update(rest)
    modes = {
        "prepare": "--prepare-package", "check-layout": "--check-layout",
        "migrate-layout": "--migrate-layout", "resume": "--resume",
        "progress": "--progress", "rebuild": "--scan-task",
    }
    if args[0] in modes:
        if args[1:] in (["-h"], ["--help"]):
            return launch_update(["--help"])
        return launch_update([modes[args[0]], *args[1:]])
    if args[0].startswith("-") or "://" in args[0]:
        return launch_update(args)
    parser().error(f"unknown command: {args[0]}")
