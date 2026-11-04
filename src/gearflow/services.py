"""Internal text protocol between Bash and the Python service modules."""

import argparse
import sys
from typing import Optional, Sequence

from .girar import parse_task
from .rdb import query_rebuilds


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    task = commands.add_parser("parse-task")
    task.add_argument("task_id")
    rebuilds = commands.add_parser("rebuilds")
    for name in ("base", "depth", "dptype", "branch"):
        rebuilds.add_argument(name)
    rebuilds.add_argument("packages", nargs="+")
    args = parser.parse_args(argv)
    try:
        if args.command == "parse-task":
            snapshot = parse_task(sys.stdin.read(), args.task_id)
            for notice in snapshot.notices:
                print(notice, file=sys.stderr)
            print(snapshot.records())
        else:
            names = query_rebuilds(
                args.base, args.depth, args.dptype, args.branch, args.packages
            )
            for name in names:
                print(name)
    except (OSError, ValueError) as error:
        prefix = (
            "Cannot scan Girar task" if args.command == "parse-task"
            else "RDB dependency lookup failed"
        )
        print(f"{prefix}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
