import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from gearflow import cli
from gearflow.monitor import cli as monitor_cli
from gearflow.monitor import updates


class UnifiedCliTests(unittest.TestCase):
    def test_invalid_workflow_arguments_never_start_the_workflow(self):
        cases = [
            ["update", "/nonexistent-gearflow-release-test"],
            ["update", "one", "two"],
            ["resume", "one", "two"],
            ["rebuild", "0"],
            ["rebuild", "-1"],
            ["rebuild", "invalid"],
            ["rebuild", "123", "--unknown"],
            ["update", "--resume", "https://example.invalid/demo.git"],
            ["update", "--resume", "--continue"],
        ]
        for args in cases:
            with self.subTest(args=args), patch("gearflow.cli.launch_update") as run:
                with patch("sys.stderr"), self.assertRaises(SystemExit) as error:
                    cli.main(args)
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_update_accepts_https_and_scp_repository_urls(self):
        for target in (
            "https://example.invalid/demo.git",
            "git@example.invalid:packages/demo.git",
        ):
            with (
                self.subTest(target=target),
                patch("gearflow.cli.launch_update", return_value=0) as run,
            ):
                self.assertEqual(cli.main(["update", target]), 0)
                run.assert_called_once_with([target])

    def test_update_resume_and_advanced_help(self):
        with patch("gearflow.cli.launch_update", return_value=0) as run:
            cli.main(["update", "--resume", "path with spaces"])
            run.assert_called_once_with(["--resume", "path with spaces"])
        with patch("gearflow.cli.launch_update", return_value=0) as run:
            cli.main(["workflow-help"])
            run.assert_called_once_with(["--help"])

    def test_check_and_task_use_python_monitor_without_bash(self):
        for args in (["check", "-m", "scala"], ["task", "show", "123"]):
            with (
                self.subTest(args=args),
                patch("gearflow.monitor.cli.main", return_value=0) as monitor,
                patch("gearflow.cli.launch_update") as workflow,
            ):
                self.assertEqual(cli.main(args), 0)
                monitor.assert_called_once_with(
                    args, prog="gearflow", check_command="check"
                )
                workflow.assert_not_called()

    def test_new_workflow_commands_preserve_arguments(self):
        cases = [
            (["resume", "path with spaces"], ["--resume", "path with spaces"]),
            (["prepare", "./demo"], ["--prepare-package", "./demo"]),
            (["rebuild", "123", "--dry-run"], ["--scan-task", "123", "--dry-run"]),
        ]
        for args, expected in cases:
            with (
                self.subTest(args=args),
                patch("gearflow.cli.launch_update", return_value=0) as run,
            ):
                self.assertEqual(cli.main(args), 0)
                run.assert_called_once_with(expected)

    def test_update_uses_selected_local_directory(self):
        with tempfile.TemporaryDirectory(prefix="gearflow local package ") as repo:
            with patch("gearflow.cli.launch_update", return_value=0) as run:
                self.assertEqual(cli.main(["update", repo]), 0)
                run.assert_called_once_with([], repository=repo)

    def test_check_dispatch_uses_existing_validation_and_returns_its_exit_code(self):
        with patch.object(updates, "main", return_value=2) as check:
            self.assertEqual(
                monitor_cli.main(
                    ["check", "-m", " ScAlA ", "--updates-only"],
                    prog="gearflow",
                    check_command="check",
                ),
                2,
            )
        args = check.call_args.args[0]
        self.assertEqual(args.maintainer, "scala")
        self.assertEqual(args.config_namespace, "gearflow")

    def test_new_config_takes_precedence_and_legacy_config_remains_supported(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}),
        ):
            root = Path(directory)
            legacy = root / "repokeep/config.json"
            legacy.parent.mkdir()
            legacy.write_text(json.dumps({"packages": {"demo": {"repo": "old/repo"}}}))
            parser, _ = monitor_cli.parser(prog="gearflow", check_command="check")
            args = parser.parse_args(["check", "-m", "scala"])
            self.assertEqual(
                updates.load_rules(args, parser)["demo"]["repo"], "old/repo"
            )
            current = root / "gearflow/config.json"
            current.parent.mkdir()
            current.write_text(json.dumps({"packages": {"demo": {"repo": "new/repo"}}}))
            args = parser.parse_args(["check", "-m", "scala"])
            self.assertEqual(
                updates.load_rules(args, parser)["demo"]["repo"], "new/repo"
            )

    def test_legacy_imports_point_to_the_same_implementation(self):
        from gearflow.monitor import tasks as current
        from repokeep import tasks

        self.assertIs(tasks, current)
