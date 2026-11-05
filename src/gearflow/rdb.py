"""Query and validate ALTRepo reverse dependency plans."""

import json
import re
import urllib.parse
import urllib.request
from typing import Any, Sequence

from .girar import package_name


def dependency_url(
    base: str, depth: str, dptype: str, branch: str, packages: Sequence[str]
) -> str:
    if not re.fullmatch(r"[1-9][0-9]*", depth):
        raise ValueError("REBUILD_DEPTH must be a positive integer")
    if dptype not in ("source", "binary", "both"):
        raise ValueError("REBUILD_DPTYPE must be source, binary or both")
    if not base.startswith(("https://", "http://")):
        raise ValueError("RDB_API_URL must be an HTTP(S) URL")
    if not packages:
        raise ValueError("at least one source package is required")
    params = [
        ("branch", branch),
        ("depth", depth),
        ("dptype", dptype),
        ("use_last_tasks", "true"),
    ]
    params.extend(("packages", package_name(package)) for package in packages)
    return (
        base.rstrip("/") + "/package/what_depends_src?" + urllib.parse.urlencode(params)
    )


def rebuild_candidates(data: Any, packages: Sequence[str]) -> list[str]:
    if not isinstance(data, dict) or not isinstance(data.get("dependencies"), list):
        raise ValueError("response has no dependencies list")
    rows = data["dependencies"]
    if type(data.get("length")) is not int or data["length"] != len(rows):
        raise ValueError("incomplete dependencies response")
    names, seen, found_roots = [], set(), set()
    for row in rows:
        if not isinstance(row, dict):
            raise ValueError("invalid dependency record")
        name = package_name(row.get("name"))
        if type(row.get("depth")) is not int or row["depth"] < 0:
            raise ValueError("invalid dependency depth")
        if row["depth"] == 0:
            found_roots.add(name)
        if name not in seen:
            seen.add(name)
            names.append(name)
    missing = set(packages) - found_roots
    if missing:
        raise ValueError(
            "source packages absent from RDB: " + " ".join(sorted(missing))
        )
    return [name for name in names if name not in packages]


def query_rebuilds(
    base: str, depth: str, dptype: str, branch: str, packages: Sequence[str]
) -> list[str]:
    url = dependency_url(base, depth, dptype, branch, packages)
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "gearflow",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        data = json.load(response)
    # Do not return a partial plan if any dependency record is invalid.
    return rebuild_candidates(data, packages)
