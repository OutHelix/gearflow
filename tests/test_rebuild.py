import json
import os
import signal
import tempfile
import unittest
from contextlib import nullcontext
from pathlib import Path
from unittest.mock import patch

from gearflow import rebuild
from gearflow.rdb import SourceRelease


class LocalRebuildTests(unittest.TestCase):
    def test_clone_and_build_failures_continue_and_resume_retries_interruption(self):
        plan = [
            SourceRelease("missing", "1", "alt1"),
            SourceRelease("broken", "2", "alt2"),
            SourceRelease("paused", "3", "alt3"),
            SourceRelease("cglib", "3.3.0", "alt1_7jpp11"),
        ]
        attempts = []

        def run(command, cwd, output, *, stop_on_signal):
            self.assertTrue(stop_on_signal)
            if cwd == source:
                attempts.append(("source", cwd.name))
                self.assertEqual(command, rebuild.BUILD_COMMAND)
                return 0
            if command[0] == "hsh":
                attempts.append(("init", cwd.name))
                self.assertEqual(command, ["hsh", "--initroot-only"])
                return 0
            if command[:2] == ["git", "checkout"]:
                attempts.append(("checkout", command[-1]))
                self.assertTrue(cwd.is_dir())
                self.assertEqual(command[2], "--detach")
                return 0
            if command[:2] == ["git", "clone"]:
                url, target = command[-2:]
                package = next(
                    item for item in plan if url.endswith(f"/{item.name}.git")
                )
                self.assertEqual(
                    (cwd / rebuild.LOG).read_text().splitlines()[-1],
                    f"[{plan.index(package) + 1}/4] BUILDING {package.name}.git={package.tag}",
                )
                origin = url.split("/")[3]
                attempts.append((origin, f"{package.name}.git"))
                self.assertIn(origin, ("gears", "srpms"))
                self.assertEqual(command[command.index("--branch") + 1], package.tag)
                if package.name == "missing" or (
                    package.name == "cglib" and origin == "gears"
                ):
                    Path(target).mkdir()
                    return 128
                self.assertFalse(Path(target).exists())
                Path(target).mkdir()
                return 0
            attempts.append(("build", cwd.name))
            package = next(item for item in plan if cwd.name == item.name + ".git")
            self.assertEqual(
                command,
                [
                    "gear",
                    "--commit",
                    "--hasher",
                    "--",
                    "hsh",
                    "--no-sisyphus-check=gpg",
                    "-v",
                    "--mountpoints=/proc",
                ],
            )
            if package.name == "broken":
                return 130
            if (
                package.name == "paused"
                and attempts.count(("build", "paused.git")) == 1
            ):
                raise rebuild.BuildInterrupted(signal.SIGINT)
            return 0

        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            source = root / "demo.git"
            (source / ".gear").mkdir(parents=True)
            (source / ".gear/rules").touch()
            (source / ".git").mkdir()
            work = root / "demo-rebuild"
            with (
                patch("builtins.input", side_effect=["1", "нет"]) as prompt,
                patch.object(rebuild, "_describe", return_value="canonical-name"),
                patch.object(rebuild, "_require_tools"),
                patch.object(
                    rebuild, "local_rebuild_plan", return_value=plan
                ) as get_plan,
                patch.object(rebuild, "run_build_command", side_effect=run),
                patch("builtins.print"),
            ):
                status = rebuild.rebuild_packages(root, resume=False, ftbfs=None)
                self.assertEqual(status, 130)
                self.assertEqual(prompt.call_count, 2)
                self.assertEqual(get_plan.call_args.args[-1], "canonical-name")
                self.assertFalse(get_plan.call_args.kwargs["ftbfs"])
                self.assertEqual(
                    (work / rebuild.LOG).read_text().splitlines(),
                    [
                        "[1/4] FAILED   missing.git=1-alt1",
                        "[2/4] FAILED   broken.git=2-alt2",
                        "[3/4] BUILDING paused.git=3-alt3",
                    ],
                )
                (work / rebuild.LOG).write_text("stale log\n")
                self.assertEqual(
                    rebuild.rebuild_packages(root, resume=True, ftbfs=None), 1
                )
                get_plan.assert_called_once()
                self.assertEqual(prompt.call_count, 2)
            self.assertEqual(
                (work / rebuild.LOG).read_text().splitlines(),
                [
                    "[1/4] FAILED   missing.git=1-alt1",
                    "[2/4] FAILED   broken.git=2-alt2",
                    "[3/4] DONE     paused.git=3-alt3",
                    "[4/4] DONE     cglib.git=3.3.0-alt1_7jpp11",
                ],
            )
            self.assertEqual(
                attempts,
                [
                    ("source", "demo.git"),
                    ("init", "demo-rebuild"),
                    ("gears", "missing.git"),
                    ("srpms", "missing.git"),
                    ("gears", "broken.git"),
                    ("checkout", "refs/tags/2-alt2"),
                    ("build", "broken.git"),
                    ("gears", "paused.git"),
                    ("checkout", "refs/tags/3-alt3"),
                    ("build", "paused.git"),
                    ("build", "paused.git"),
                    ("gears", "cglib.git"),
                    ("srpms", "cglib.git"),
                    ("checkout", "refs/tags/3.3.0-alt1_7jpp11"),
                    ("build", "cglib.git"),
                ],
            )

    def test_legacy_checkpoint_resumes_preparation_after_failure_and_interruption(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            source = root / "demo"
            (source / ".gear").mkdir(parents=True)
            (source / ".gear/rules").touch()
            (source / ".git").mkdir()
            workspace = root / "demo-rebuild"
            workspace.mkdir()
            checkpoint = workspace / rebuild.CHECKPOINT
            checkpoint.write_text(
                json.dumps(
                    {
                        "format": 1,
                        "plan": [
                            {"name": "finished", "version": "1", "release": "alt1"},
                            {"name": "waiting", "version": "2", "release": "alt1"},
                        ],
                        "results": ["DONE"],
                    }
                ),
                encoding="utf-8",
            )
            with (
                patch.object(rebuild, "_require_tools"),
                patch.object(rebuild, "_build", return_value=0) as build,
                patch.object(
                    rebuild,
                    "run_build_command",
                    side_effect=[7, 0, rebuild.BuildInterrupted(signal.SIGINT), 0],
                ) as run,
                patch("builtins.print"),
            ):
                self.assertEqual(
                    rebuild.rebuild_packages(root, resume=True, ftbfs=None), 7
                )
                self.assertEqual(
                    json.loads(checkpoint.read_text())["preparation"], "source"
                )
                self.assertEqual(
                    rebuild.rebuild_packages(root, resume=True, ftbfs=None), 130
                )
                self.assertEqual(
                    json.loads(checkpoint.read_text())["preparation"], "init"
                )
                build.assert_not_called()
                self.assertEqual(
                    rebuild.rebuild_packages(root, resume=True, ftbfs=None), 0
                )
                self.assertEqual(
                    json.loads(checkpoint.read_text())["preparation"], "ready"
                )
                self.assertEqual(
                    [(call.args[0], call.args[1]) for call in run.call_args_list],
                    [
                        (rebuild.BUILD_COMMAND, source),
                        (rebuild.BUILD_COMMAND, source),
                        (["hsh", "--initroot-only"], workspace),
                        (["hsh", "--initroot-only"], workspace),
                    ],
                )
                build.assert_called_once_with(
                    workspace, SourceRelease("waiting", "2", "alt1")
                )

    def test_log_columns_stay_aligned_as_index_grows(self):
        release = SourceRelease("cglib", "3.3.0", "alt1_7jpp11")
        self.assertEqual(
            [
                rebuild._result_line(index, 194, release, status)
                for index, status in [(1, "DONE"), (10, "FAILED"), (194, "BUILDING")]
            ],
            [
                "[  1/194] DONE     cglib.git=3.3.0-alt1_7jpp11",
                "[ 10/194] FAILED   cglib.git=3.3.0-alt1_7jpp11",
                "[194/194] BUILDING cglib.git=3.3.0-alt1_7jpp11",
            ],
        )

    def test_clear_asks_for_each_workspace_and_accepts_only_an_explicit_yes(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            remove = root / "delete-rebuild"
            keep = root / "keep-rebuild"
            source = root / "source-rebuild"
            nested = root / "elsewhere" / "nested-rebuild"
            for directory in (remove, keep, source / ".git", nested):
                directory.mkdir(parents=True)
            (remove / rebuild.LOG).touch()
            (root / "file-rebuild").touch()
            if os.name == "posix":
                (root / "link-rebuild").symlink_to(nested, target_is_directory=True)
            with (
                patch("builtins.input", side_effect=["да", ""]) as prompt,
                patch("builtins.print"),
                patch.object(
                    rebuild, "_rebuild_lock", side_effect=lambda _: nullcontext()
                ),
            ):
                self.assertEqual(rebuild.clear_rebuilds(root), 0)
            self.assertEqual(prompt.call_count, 2)
            self.assertIn(repr(str(remove)), prompt.call_args_list[0].args[0])
            self.assertIn(repr(str(keep)), prompt.call_args_list[1].args[0])
            self.assertFalse(remove.exists())
            for directory in (keep, source, nested):
                self.assertTrue(directory.is_dir())
            self.assertEqual(list(root.glob(".clear-rebuild-*")), [])

    @unittest.skipUnless(os.name == "posix", "requires a real POSIX rebuild lock")
    def test_clear_keeps_a_locked_workspace_and_continues(self):
        with tempfile.TemporaryDirectory() as path:
            root = Path(path)
            active = root / "active-rebuild"
            idle = root / "idle-rebuild"
            active.mkdir()
            idle.mkdir()
            with (
                rebuild._rebuild_lock(active),
                patch("builtins.input", return_value="yes"),
                patch("builtins.print"),
            ):
                self.assertEqual(rebuild.clear_rebuilds(root), 1)
            self.assertTrue(active.exists())
            self.assertFalse(idle.exists())
