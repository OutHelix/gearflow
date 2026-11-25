"""Query and validate ALTRepo reverse dependency plans."""

import json
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass
from typing import Any, Sequence
from urllib.error import HTTPError

from .girar import package_name


@dataclass(frozen=True)
class SourceRelease:
    name: str
    version: str
    release: str

    def __post_init__(self) -> None:
        package_name(self.name)
        for field in (self.version, self.release):
            if not isinstance(field, str) or not re.fullmatch(
                r"[\w.+~^%-]+", field, re.ASCII
            ):
                raise ValueError(f"invalid version or release for {self.name}")

    @property
    def tag(self) -> str:
        return f"{self.version}-{self.release}"


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


def _rows(data: Any, key: str) -> list:
    if not isinstance(data, dict) or not isinstance(data.get(key), list):
        raise ValueError(f"response has no {key} list")
    rows = data[key]
    if type(data.get("length")) is not int or data["length"] != len(rows):
        raise ValueError(f"incomplete {key} response")
    if any(not isinstance(row, dict) for row in rows):
        raise ValueError(f"invalid {key} record")
    return rows


def _rebuild_rows(data: Any, packages: Sequence[str]) -> list[dict]:
    ordered, seen, found_roots = [], set(), set()
    for row in _rows(data, "dependencies"):
        name = package_name(row.get("name"))
        if type(row.get("depth")) is not int or row["depth"] < 0:
            raise ValueError("invalid dependency depth")
        if row["depth"] == 0:
            found_roots.add(name)
        if name not in seen and name not in packages:
            seen.add(name)
            ordered.append(row)
    missing = set(packages) - found_roots
    if missing:
        raise ValueError(
            "source packages absent from RDB: " + " ".join(sorted(missing))
        )
    return ordered


def rebuild_candidates(data: Any, packages: Sequence[str]) -> list[str]:
    return [row["name"] for row in _rebuild_rows(data, packages)]


def _request_json(url: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/json",
            "User-Agent": "gearflow",
        },
    )
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.load(response)


def query_rebuilds(
    base: str, depth: str, dptype: str, branch: str, packages: Sequence[str]
) -> list[str]:
    data = _request_json(dependency_url(base, depth, dptype, branch, packages))
    # Do not return a partial plan if any dependency record is invalid.
    return rebuild_candidates(data, packages)


def _source_release(row: dict) -> SourceRelease:
    return SourceRelease(row.get("name"), row.get("version"), row.get("release"))


def local_rebuild_plan(
    base: str, depth: str, dptype: str, branch: str, package: str, *, ftbfs: bool
) -> list[SourceRelease]:
    data = _request_json(dependency_url(base, depth, dptype, branch, [package]))
    plan = [_source_release(row) for row in _rebuild_rows(data, [package])]
    if ftbfs or not plan:
        return plan

    query = urllib.parse.urlencode({"branch": branch})
    try:
        failures = _request_json(f"{base.rstrip('/')}/export/beehive/ftbfs?{query}")
    except HTTPError as error:
        if error.code != 404:
            raise
        return plan
    failing = {_source_release(row) for row in _rows(failures, "ftbfs")}
    return [release for release in plan if release not in failing]
