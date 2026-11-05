import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SHELL = ROOT / "src" / "gearflow" / "shell" / "main.sh"


class RepositoryTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="gearflow test ")
        self.addCleanup(self.directory.cleanup)
        self.repo = Path(self.directory.name)
        self.env = os.environ.copy()
        self.env.update(
            {
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GEARFLOW_PYTHON": sys.executable,
                "GEARFLOW_TEST_REPOSITORY": str(self.repo),
            }
        )
        for name in (
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_COMMON_DIR",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        ):
            self.env.pop(name, None)
        self.git("init", "-b", "sisyphus")
        self.git("config", "user.name", "Gearflow Test")
        self.git("config", "user.email", "gearflow@example.invalid")
        self.git("config", "commit.gpgsign", "false")

    def git(self, *args):
        return subprocess.run(
            ["git", *args],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            check=True,
        ).stdout.strip()

    def write(self, path, text):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text)
        return target

    def commit(self):
        self.git("add", "-A")
        self.git("commit", "-m", "fixture")

    def shell(self, code, *args):
        return subprocess.run(
            [
                "bash",
                "-c",
                'source "$1"; shift; ' + code,
                "gearflow-test",
                str(SHELL),
                *args,
            ],
            cwd=self.repo,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def assertSuccess(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
