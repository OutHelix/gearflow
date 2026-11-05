import os
import subprocess
import sys
import unittest
from unittest.mock import patch

from gearflow import __version__
from gearflow.cli import main
from tests.support import ROOT


class CliTests(unittest.TestCase):
    def run_cli(self, *args, env=None):
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(ROOT / "src")
        if env:
            environment.update(env)
        return subprocess.run(
            [sys.executable, "-m", "gearflow", *args],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
            timeout=20,
        )

    def test_help_does_not_require_gear_tools(self):
        result = self.run_cli("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gearflow --resume", result.stdout)
        self.assertNotIn("Required command not found", result.stderr)

    def test_version_does_not_require_bash(self):
        result = self.run_cli("--version", env={"PATH": ""})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), f"gearflow {__version__}")

    def test_unknown_option_is_rejected_before_dependency_checks(self):
        result = self.run_cli("--does-not-exist")
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("unrecognized arguments", result.stderr)
        self.assertNotIn("Required command not found", result.stderr)

    def test_missing_bash_is_reported_without_traceback(self):
        result = self.run_cli("update", env={"PATH": ""})
        self.assertEqual(result.returncode, 1)
        self.assertIn("Bash 4.4", result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_module_works_from_another_directory(self):
        env = os.environ.copy()
        env["PYTHONPATH"] = str(ROOT / "src")
        result = subprocess.run(
            [sys.executable, "-m", "gearflow", "--help"],
            cwd=ROOT.parent,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("gearflow", result.stdout)

    def test_command_help_is_specific_and_does_not_require_bash(self):
        for command, expected in (
            ("update", "DIR|URL"),
            ("resume", "DIR"),
            ("rebuild", "TASK"),
        ):
            with self.subTest(command=command):
                result = self.run_cli(command, "--help", env={"PATH": ""})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"gearflow {command}", result.stdout)
                self.assertIn(expected, result.stdout)
                self.assertNotIn("Required command not found", result.stderr)

    def test_launch_preserves_arguments_and_uses_current_interpreter(self):
        class ReplacedProcess(Exception):
            pass

        with (
            patch("gearflow.cli.shutil.which", return_value="/bin/bash"),
            patch("gearflow.cli.os.execve", side_effect=ReplacedProcess) as execute,
            patch.object(sys, "argv", ["/tmp/path with spaces/gearflow"]),
        ):
            with self.assertRaises(ReplacedProcess):
                main(["--check-layout", "/tmp/package with spaces"])
        binary, args, env = execute.call_args.args
        self.assertEqual(binary, "/bin/bash")
        self.assertEqual(args[-2:], ["--check-layout", "/tmp/package with spaces"])
        self.assertEqual(env["GEARFLOW_PYTHON"], sys.executable)
        self.assertEqual(env["GEARFLOW_COMMAND"], "'/tmp/path with spaces/gearflow'")

    def test_shell_files_have_valid_syntax(self):
        for script in sorted((ROOT / "src/gearflow/shell").glob("*.sh")):
            with self.subTest(script=script.name):
                result = subprocess.run(
                    ["bash", "-n", str(script)], capture_output=True, text=True
                )
                self.assertEqual(result.returncode, 0, result.stderr)
