"""Command-line interface for monitoring and interactive package updates."""

import argparse
import os
import re
import shlex
import shutil
import sys
from pathlib import Path
from typing import Optional, Sequence

from . import __version__

WORKFLOW_MODES = {
    "prepare": ("--prepare-package", "prepare packaging files under altlinux/"),
    "check-layout": ("--check-layout", "check package layout without changes"),
    "migrate-layout": ("--migrate-layout", "migrate packaging layout interactively"),
    "resume": ("--resume", "continue a saved package update"),
    "progress": ("--progress", "show saved update progress"),
}
LEGACY_MODES = {mode for mode, _ in WORKFLOW_MODES.values()} | {
    "--resume-after-merge",
    "--resume-status",
    "--clear-resume",
    "--continue",
    "--continue-update",
    "--continue-fix",
    "--scan-task",
}


def launch_update(argv: Sequence[str], repository: Optional[str] = None) -> int:
    """Replace this process with the workflow, preserving its terminal and signals."""
    bash = shutil.which("bash")
    if bash is None:
        print("ERROR: gearflow requires Bash 4.4 or newer.", file=sys.stderr)
        return 1

    env = os.environ.copy()
    env["GEARFLOW_PYTHON"] = sys.executable
    env["GEARFLOW_PROGRAM"] = "gearflow"
    if Path(sys.argv[0]).name == "__main__.py":
        env["GEARFLOW_COMMAND"] = shlex.join([sys.executable, "-m", "gearflow"])
    else:
        env["GEARFLOW_COMMAND"] = shlex.quote(os.path.abspath(sys.argv[0]))

    script = Path(__file__).resolve().parent / "shell" / "main.sh"
    try:
        if repository is not None:
            os.chdir(repository)
        os.execve(bash, [bash, str(script), *argv], env)
    except OSError as error:
        print(f"ERROR: Could not start the gearflow workflow: {error}", file=sys.stderr)
        return 1


def _add_version(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )


def _task_id(value: str) -> str:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("task ID must be a positive integer")
    return value


def _is_repository_url(value: str) -> bool:
    return bool(re.match(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", value)) or bool(
        re.match(r"^(?:[^/@:]+@)?[^/:]+:.+", value)
    )


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(
        prog="gearflow",
        description="Release checks, security advisories, gear updates and Girar tasks for ALT Linux.",
        epilog="Legacy workflow flags remain available: gearflow --resume DIR, --progress DIR, --scan-task TASK.",
    )
    _add_version(root)
    commands = root.add_subparsers(dest="command")
    for name, help_text in (
        ("check", "check upstream releases and OSV advisories"),
        ("task", "list or inspect Girar tasks; supports watch mode"),
    ):
        # These commands use the monitor's complete parsers, loaded on demand.
        commands.add_parser(name, help=help_text, add_help=False)

    update = commands.add_parser(
        "update",
        help="update and build a local gear package or clone a repository URL",
        description="Interactively update a gear package. Defaults to the current repository.",
    )
    _add_version(update)
    update.add_argument("target", nargs="?", metavar="DIR|URL")
    update.add_argument(
        "--prepare-only",
        action="store_true",
        help="stop after merge, rules, spec/changelog and stored tags; do not build or publish",
    )
    modes = update.add_mutually_exclusive_group()
    for option in (
        "--resume",
        "--resume-after-merge",
        "--continue",
        "--continue-update",
        "--continue-fix",
    ):
        modes.add_argument(
            option, dest="workflow_mode", action="store_const", const=option
        )

    for name, (_, help_text) in WORKFLOW_MODES.items():
        command = commands.add_parser(
            name, help=help_text, description=help_text.capitalize() + "."
        )
        _add_version(command)
        command.add_argument(
            "target",
            nargs="?",
            metavar="DIR|URL" if name == "prepare" else "DIR",
        )

    rebuild = commands.add_parser(
        "rebuild",
        help="plan and add reverse dependency rebuilds for a Girar task",
        description="Read Girar/RDB and add missing rebuilds after confirmation.",
    )
    _add_version(rebuild)
    rebuild.add_argument("task_id", nargs="?", type=_task_id, metavar="TASK")
    rebuild.add_argument(
        "--dry-run",
        action="store_true",
        help="display the plan without changing or starting the task",
    )

    workflow = commands.add_parser(
        "workflow-help",
        help="show advanced workflow modes and environment settings",
    )
    _add_version(workflow)

    build = commands.add_parser(
        "build", help="build a prepared tree in hasher and write both streams to a log"
    )
    _add_version(build)
    build.add_argument("directory", nargs="?", default=".", metavar="DIR")
    build.add_argument(
        "--log",
        required=True,
        metavar="FILE",
        help="overwrite FILE with build stdout/stderr; no terminal output",
    )

    publish = commands.add_parser(
        "publish", help="commit, tag and push a reviewed package to Gitery"
    )
    _add_version(publish)
    publish.add_argument("directory", nargs="?", default=".", metavar="DIR")
    publish.add_argument(
        "--gitery-only",
        required=True,
        action="store_true",
        help="publish to Gitery without building or submitting to Girar",
    )
    return root


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if args and args[0] in ("check", "task"):
        from .monitor.cli import main as monitor_main

        return monitor_main(args, prog="gearflow", check_command="check")
    if args and args[0] in LEGACY_MODES:
        return launch_update(args)
    if args and _is_repository_url(args[0]):
        args.insert(0, "update")

    root = parser()
    if not args:
        root.print_help()
        return 0
    options = root.parse_args(args)
    if options.command is None:
        root.print_help()
        return 0
    if options.command == "workflow-help":
        return launch_update(["--help"])
    if options.command == "build":
        from .build import build_package

        return build_package(options.directory, options.log)
    if options.command == "publish":
        return launch_update(["--publish-gitery-only", options.directory])
    if options.command == "update":
        target = options.target
        prefix = ["--prepare-only"] if options.prepare_only else []
        if options.workflow_mode:
            if options.prepare_only and options.workflow_mode.startswith("--continue"):
                root.error("--prepare-only cannot be combined with --continue modes")
            if target and _is_repository_url(target):
                root.error("resume/continue modes require a local repository directory")
            return launch_update(
                [*prefix, options.workflow_mode, *([target] if target else [])]
            )
        if target is None:
            return launch_update(prefix)
        path = Path(target).expanduser()
        if path.is_dir():
            return launch_update(prefix, repository=os.fspath(path))
        if _is_repository_url(target):
            return launch_update([*prefix, target])
        root.error(f"repository directory not found: {target}")
    if options.command == "rebuild":
        workflow_args = ["--scan-task"]
        if options.task_id:
            workflow_args.append(options.task_id)
        if options.dry_run:
            workflow_args.append("--dry-run")
        return launch_update(workflow_args)
    mode = WORKFLOW_MODES[options.command][0]
    return launch_update(
        [mode, *([options.target] if options.target is not None else [])]
    )
