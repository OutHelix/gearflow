"""Parse Girar's live task text without executing its contents."""

import hashlib
import json
import re
from dataclasses import dataclass


def package_name(value: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9+_.-]*", value
    ):
        raise ValueError(f"invalid source package name: {value!r}")
    return value


@dataclass(frozen=True)
class TaskSnapshot:
    branch: str
    signature: str
    roots: tuple[str, ...]
    present: tuple[str, ...]
    notices: tuple[str, ...]

    def records(self) -> str:
        lines = [f"branch\t{self.branch}", f"signature\t{self.signature}"]
        lines.extend(f"root\t{name}" for name in self.roots)
        lines.extend(f"present\t{name}" for name in self.present)
        return "\n".join(lines)


def parse_task(text: str, task_id: str) -> TaskSnapshot:
    lines = text.splitlines()
    if not lines or not lines[0].startswith("id="):
        raise ValueError("unrecognized task show response")
    header = dict(part.split("=", 1) for part in lines[0].split() if "=" in part)
    if header.get("id") != task_id:
        raise ValueError("task ID does not match the request")
    if header.get("locked") != "no":
        raise ValueError("task is locked; wait until it stops building")
    if header.get("state") not in ("NEW", "SWEPT", "TESTED", "EPERM", "FAILED"):
        raise ValueError(
            "task state does not allow adding rebuilds: "
            + header.get("state", "unknown")
        )
    branch = header.get("repo", "")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", branch):
        raise ValueError("invalid repository name")

    subtasks: dict[int, dict[str, str]] = {}
    for line in lines[1:]:
        match = re.fullmatch(r"\s+([0-9]+):([a-zA-Z0-9_]+)(?:=(.*))?", line)
        if match:
            number, field, value = match.groups()
            subtasks.setdefault(int(number), {})[field] = value or ""

    roots, present, actions, notices = set(), set(), [], []
    for number, subtask in sorted(subtasks.items()):
        # Deleted subtasks may retain userid and old build metadata.
        if not any(subtask.get(key) for key in ("dir", "srpm", "package")):
            continue
        actions.append(
            (
                number,
                {
                    key: subtask[key]
                    for key in (
                        "dir",
                        "srpm",
                        "package",
                        "tag_name",
                        "tag_id",
                        "rebuild_from",
                        "copy_repo",
                        "delete",
                        "type",
                        "pkgname",
                    )
                    if key in subtask
                },
            )
        )
        name = subtask.get("pkgname") or subtask.get("package")
        if not name and subtask.get("srpm"):
            filename = subtask["srpm"].rsplit("/", 1)[-1]
            parts = filename[:-8].rsplit("-", 2)
            if not filename.endswith(".src.rpm") or len(parts) != 3:
                raise ValueError(f"cannot identify SRPM in subtask #{number}")
            name = parts[0]
        if not name and subtask.get("dir"):
            name = subtask["dir"].rstrip("/").rsplit("/", 1)[-1]
            if name.endswith(".git"):
                name = name[:-4]
            notices.append(
                f"Subtask #{number}: not built yet; using gear repository name {name}"
            )
        name = package_name(name)
        present.add(name)
        # Existing rebuilds must not become roots during a repeated scan.
        if (subtask.get("dir") or subtask.get("srpm")) and not subtask.get(
            "rebuild_from"
        ):
            if subtask.get("type", "srpm") == "srpm":
                roots.add(name)

    signature = hashlib.sha256(
        json.dumps(
            [header.get("state"), header.get("test_only"), actions], sort_keys=True
        ).encode()
    ).hexdigest()
    return TaskSnapshot(
        branch, signature, tuple(sorted(roots)), tuple(sorted(present)), tuple(notices)
    )
