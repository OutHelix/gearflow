import argparse
import multiprocessing
import os
import re
import signal
import sys

from . import __version__, tasks, updates


def _task_id(value):
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise argparse.ArgumentTypeError("task ID must be a positive integer")
    return value


def parser(prog="repokeep", check_command="update"):
    root = argparse.ArgumentParser(prog=prog, description="ALT Linux maintainer tools.")
    if hasattr(root, "color"):
        root.color = False
    root.add_argument("--version", action="version", version="%(prog)s " + __version__)
    commands = root.add_subparsers(dest="command", required=True)
    update_parser = commands.add_parser(
        check_command, help="check GitHub releases or OSV advisories"
    )
    namespace = "gearflow" if prog == "gearflow" else "repokeep"
    updates.configure_parser(update_parser, config_namespace=namespace)
    update_parser.set_defaults(config_namespace=namespace)
    task_parser = commands.add_parser("task", help="list or inspect Girar tasks")
    tasks.configure_parser(task_parser)
    actions = task_parser.add_subparsers(dest="task_action")
    show_parser = actions.add_parser("show", help="show one task with all details")
    tasks.configure_show_parser(show_parser)
    if prog == "gearflow":
        rebuild = actions.add_parser(
            "rebuild", help="plan and add reverse dependency rebuilds to a Girar task"
        )
        rebuild.add_argument("task_id", nargs="?", type=_task_id, metavar="TASK")
        rebuild.add_argument(
            "--dry-run",
            action="store_true",
            help="display the plan without changing or starting the task",
        )
        rebuild.add_argument(
            "--version", action="version", version="%(prog)s " + __version__
        )
    return root, {
        check_command: update_parser,
        "task": task_parser,
        "show": show_parser,
    }


def run(argv=None, *, prog="repokeep", check_command="update"):
    root, commands = parser(prog=prog, check_command=check_command)
    args = root.parse_args(argv)
    selected = commands[args.command]
    if args.command == check_command:
        updates.validate_args(args, selected)
        return updates.main(args, selected)
    if args.task_action == "rebuild":
        from ..cli import launch_update

        workflow_args = ["--scan-task"]
        if args.task_id is not None:
            workflow_args.append(args.task_id)
        if args.dry_run:
            workflow_args.append("--dry-run")
        return launch_update(workflow_args)
    tasks.validate_args(
        args, commands["show"] if args.task_action == "show" else selected
    )
    return tasks.main(args)


def main(argv=None, *, prog="repokeep", check_command="update"):
    multiprocessing.freeze_support()

    def terminate(signum, frame):
        raise SystemExit(128 + signum)

    previous_term = signal.signal(signal.SIGTERM, terminate)
    try:
        if argv is None and prog == "repokeep" and check_command == "update":
            return run()
        return run(argv, prog=prog, check_command=check_command)
    except KeyboardInterrupt:
        print("\nInterrupted.", file=sys.stderr)
        return 130
    except BrokenPipeError:
        os._exit(0)
    finally:
        signal.signal(signal.SIGTERM, previous_term)
