import signal
import tempfile
import unittest
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
            SourceRelease("last", "4", "alt4"),
        ]
        attempts = []

        def run(command, cwd, output, *, stop_on_signal):
            self.assertTrue(stop_on_signal)
            if command[0] == "git":
                url, target = command[-2:]
                package = next(
                    item for item in plan if url.endswith(f"/{item.name}.git")
                )
                self.assertEqual(
                    (cwd / rebuild.LOG).read_text().splitlines()[-1],
                    f"[{plan.index(package) + 1}/4] {package.name}.git={package.tag} BUILDING",
                )
                attempts.append(("clone", url.split("/")[-1]))
                self.assertTrue(url.startswith("https://git.altlinux.org/gears/"))
                if url.endswith("/missing.git"):
                    return 128
                Path(target).mkdir()
                return 0
            attempts.append(("build", cwd.name))
            package = next(item for item in plan if cwd.name == item.name + ".git")
            self.assertIn(f"--tree-ish=refs/tags/{package.tag}", command)
            self.assertEqual(command[command.index("--") + 1], "hsh")
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
                        "[1/4] missing.git=1-alt1 FAILED",
                        "[2/4] broken.git=2-alt2 FAILED",
                        "[3/4] paused.git=3-alt3 BUILDING",
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
                    "[1/4] missing.git=1-alt1 FAILED",
                    "[2/4] broken.git=2-alt2 FAILED",
                    "[3/4] paused.git=3-alt3 DONE",
                    "[4/4] last.git=4-alt4 DONE",
                ],
            )
            self.assertEqual(
                attempts,
                [
                    ("clone", "missing.git"),
                    ("clone", "broken.git"),
                    ("build", "broken.git"),
                    ("clone", "paused.git"),
                    ("build", "paused.git"),
                    ("build", "paused.git"),
                    ("clone", "last.git"),
                    ("build", "last.git"),
                ],
            )
