import os
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from unittest.mock import patch

from tests.support import ROOT, RepositoryTest

SPEC = "Name: demo\nVersion: 1.0\nRelease: alt1\nVcs: {url}\n\n%changelog\n"


class SplitWorkflowTest(RepositoryTest):
    def setUp(self):
        super().setUp()
        self.tools = tempfile.TemporaryDirectory(prefix="gearflow-tools-")
        self.addCleanup(self.tools.cleanup)
        self.tool_dir = Path(self.tools.name)
        self.trace = self.tool_dir / "calls"
        self.env["PATH"] = str(self.tool_dir) + os.pathsep + self.env.get("PATH", "")
        self.env["PYTHONPATH"] = (
            str(ROOT / "src") + os.pathsep + self.env.get("PYTHONPATH", "")
        )
        self.env["GEARFLOW_TEST_TRACE"] = str(self.trace)
        self.env["GEARFLOW_TEST_BUILD_RC"] = "0"
        self.env["GEARFLOW_TEST_STORE_RC"] = "0"
        self.env["TARGET_BRANCH"] = "sisyphus"
        self.env["RELEASE"] = "alt1"
        self.tool(
            "gear",
            """
printf 'gear\\n' >> "$GEARFLOW_TEST_TRACE"
printf 'gear stdout\\n'
printf 'gear stderr\\n' >&2
[ "$*" = '--commit --hasher -- hsh --no-sisyphus-check=gpg -v --mountpoints=/proc' ] || exit 98
exec hsh
""",
        )
        self.tool(
            "hsh",
            """
printf 'hsh\\n' >> "$GEARFLOW_TEST_TRACE"
printf 'hasher stdout\\n'
printf 'hasher stderr\\n' >&2
exit "$GEARFLOW_TEST_BUILD_RC"
""",
        )
        self.tool(
            "gear-store-tags",
            """
printf 'store-tags\\n' >> "$GEARFLOW_TEST_TRACE"
[ "$GEARFLOW_TEST_STORE_RC" = 0 ] || exit "$GEARFLOW_TEST_STORE_RC"
mkdir -p .gear/tags
printf 'stored upstream tag\\n' > .gear/tags/list
""",
        )
        self.tool(
            "add_changelog",
            """
printf 'changelog\\n' >> "$GEARFLOW_TEST_TRACE"
printf '* Thu Nov 05 2026 Tester <test@example.invalid> 2.0-alt1\\n%s\\n' "$3" >> "$1"
""",
        )
        for command in ("gear-commit", "gear-create-tag", "ssh"):
            self.tool(
                command,
                f'printf "forbidden {command}\\n" >> "$GEARFLOW_TEST_TRACE"; exit 97\n',
            )

    def tool(self, name, body):
        path = self.tool_dir / name
        path.write_text("#!/bin/sh\nset -eu\n" + body)
        path.chmod(0o755)

    def calls(self):
        return self.trace.read_text().splitlines() if self.trace.exists() else []

    def command(self, *args, input=None):
        return subprocess.run(
            [sys.executable, "-m", "gearflow", *args],
            cwd=self.repo,
            env=self.env,
            input=input,
            text=True,
            capture_output=True,
            timeout=30,
        )

    def initial_package(self):
        self.write("source.txt", "original source\n")
        self.write("altlinux/demo.spec", SPEC.format(url=self.repo.as_uri()))
        self.write(".gear/rules", "spec: altlinux/demo.spec\ntar: .\n")
        self.commit()
        self.write("source.txt", "prepared source\n")

    def update_package(self):
        upstream = self.tool_dir / "upstream"
        upstream.symlink_to(self.repo, target_is_directory=True)
        self.write("source.txt", "upstream 1\n")
        self.commit()
        self.git("tag", "v1.0")
        self.write("altlinux/demo.spec", SPEC.format(url=upstream.as_uri()))
        self.write(".gear/rules", "spec: altlinux/demo.spec\ntar: v@version@:.\n")
        self.commit()
        self.git("tag", "1.0-alt1")
        self.git("switch", "-c", "upstream-source", "v1.0")
        self.write("source.txt", "upstream 2\n")
        self.commit()
        self.git("tag", "v2.0")
        self.git("switch", "sisyphus")

    def publication_tools(self, version="1.0"):
        self.tool(
            "gear-commit",
            """
printf 'commit\\n' >> "$GEARFLOW_TEST_TRACE"
git commit -m 'prepared package'
""",
        )
        self.tool(
            "gear-create-tag",
            f"""
printf 'tag\\n' >> "$GEARFLOW_TEST_TRACE"
git tag -a {version}-alt1 -m 'Test tag
-----BEGIN PGP SIGNATURE-----
test-only signature fixture'
""",
        )
        remote = self.tool_dir / "gitery/demo"
        remote.parent.mkdir()
        self.git("init", "--bare", str(remote))
        self.git(
            "config",
            "--local",
            f"url.{remote.parent.as_uri()}/.insteadOf",
            "gitery:packages/",
        )
        return remote


class BuildTests(SplitWorkflowTest):
    def test_build_forwards_termination_to_the_builder_without_terminal_output(self):
        self.initial_package()
        marker = self.tool_dir / "builder.pid"
        sleeper = self.tool_dir / "sleep.py"
        sleeper.write_text(
            f"import os, time\nfrom pathlib import Path\nPath({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)\n"
        )
        self.tool(
            "hsh",
            f"exec {shlex.quote(sys.executable)} {shlex.quote(str(sleeper))}\n",
        )
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "gearflow",
                "build",
                ".",
                "--log",
                str(self.tool_dir / "build.log"),
            ],
            cwd=self.repo,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            deadline = time.monotonic() + 10
            while (
                not marker.exists()
                and process.poll() is None
                and time.monotonic() < deadline
            ):
                time.sleep(0.02)
            self.assertTrue(marker.exists())
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 143)
            self.assertEqual((stdout, stderr), (b"", b""))
            with self.assertRaises(ProcessLookupError):
                os.kill(int(marker.read_text()), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_unwritable_log_does_not_start_builder(self):
        self.initial_package()
        result = self.command(
            "build", ".", "--log", str(self.tool_dir / "missing/build.log")
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot open build log", result.stderr)
        self.assertEqual(self.calls(), [])
        loop = self.tool_dir / "loop.log"
        loop.symlink_to(loop)
        result = self.command("build", ".", "--log", str(loop))
        self.assertEqual(result.returncode, 1)
        self.assertIn("Cannot open build log", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertEqual(self.calls(), [])

    def test_staged_log_is_removed_from_index_before_later_publication(self):
        self.initial_package()
        log = self.repo / "build.log"
        self.assertSuccess(self.command("build", ".", "--log", str(log)))
        self.git("add", "build.log")
        self.publication_tools()
        self.assertSuccess(self.command("publish", ".", "--gitery-only"))
        self.assertNotIn("build.log", self.git("ls-files"))

    def test_initial_and_repeated_build_are_silent_and_return_hasher_status(self):
        self.initial_package()
        before = self.git("rev-parse", "HEAD")
        log = self.repo / "build [attempt]*.log"
        for status in (43, 0):
            with self.subTest(status=status):
                self.env["GEARFLOW_TEST_BUILD_RC"] = str(status)
                result = self.command("build", ".", "--log", str(log))
                self.assertEqual(result.returncode, status, result.stderr)
                self.assertEqual((result.stdout, result.stderr), ("", ""))
                self.assertEqual(
                    log.read_text().splitlines(),
                    [
                        "gear stdout",
                        "gear stderr",
                        "hasher stdout",
                        "hasher stderr",
                    ],
                )
                self.assertEqual(self.git("rev-parse", "HEAD"), before)
                self.assertEqual(self.git("tag", "--list"), "")
                self.assertNotIn(log.name, self.git("diff", "--cached", "--name-only"))
        self.assertEqual(self.calls(), ["gear", "hsh", "gear", "hsh"])

    def test_build_stages_new_changes_and_removals_but_excludes_backups(self):
        self.initial_package()
        self.write("source.txt~", "editor backup\n")
        self.git("add", "source.txt~")
        self.write("altlinux/restored.patch", "restored patch\n")
        (self.repo / "source.txt").unlink()
        result = self.command("build", ".", "--log", str(self.tool_dir / "build.log"))
        self.assertSuccess(result)
        self.assertEqual(
            self.git("diff", "--cached", "--name-only").splitlines(),
            [
                "altlinux/restored.patch",
                "source.txt",
            ],
        )
        self.assertTrue((self.repo / "source.txt~").exists())

    def test_invalid_repository_errors_are_written_to_log(self):
        log = self.tool_dir / "build.log"
        with tempfile.TemporaryDirectory(prefix="gearflow test ") as directory:
            with patch.dict(self.env, {"GEARFLOW_TEST_REPOSITORY": directory}):
                result = self.command("build", directory, "--log", str(log))
        self.assertEqual(result.returncode, 1)
        self.assertEqual((result.stdout, result.stderr), ("", ""))
        self.assertIn("not a git repository", log.read_text().lower())
        self.assertEqual(self.calls(), [])

    def test_build_cannot_overwrite_package_files_or_git_metadata(self):
        self.initial_package()
        for name in ("altlinux/demo.spec", ".git/config"):
            with self.subTest(name=name):
                path = self.repo / name
                before = path.read_bytes()
                result = self.command("build", ".", "--log", str(path))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(path.read_bytes(), before)
                self.assertIn("ERROR:", result.stderr)
                self.assertEqual(self.calls(), [])


class PreparationTests(SplitWorkflowTest):
    def test_prepare_only_merges_updates_metadata_and_stops_before_build(self):
        self.update_package()
        result = self.command("update", "--prepare-only", ".", input="yes\n2.0\n")
        self.assertSuccess(result)
        self.assertIn("Preparation complete", result.stdout)
        self.assertEqual((self.repo / "source.txt").read_text(), "upstream 2\n")
        spec = (self.repo / "altlinux/demo.spec").read_text()
        self.assertIn("Version: 2.0", spec)
        self.assertIn("Automatically updated to 2.0", spec)
        self.assertTrue((self.repo / ".gear/tags/list").exists())
        self.assertEqual(self.calls(), ["changelog", "store-tags"])
        self.assertIn("Next stage: build", self.command("--resume-status", ".").stdout)
        prepared_head = self.git("rev-parse", "HEAD")
        result = self.command("update", "--prepare-only", "--resume", ".")
        self.assertSuccess(result)
        self.assertEqual(self.git("rev-parse", "HEAD"), prepared_head)
        self.assertEqual((self.repo / "altlinux/demo.spec").read_text(), spec)
        self.assertEqual(self.calls(), ["changelog", "store-tags"])

    def test_failed_tag_storage_keeps_checkpoint_for_prepare_only_retry(self):
        self.update_package()
        self.env["GEARFLOW_TEST_STORE_RC"] = "45"
        result = self.command("update", "--prepare-only", ".", input="yes\n2.0\n")
        self.assertEqual(result.returncode, 45, result.stdout + result.stderr)
        self.assertIn("Next stage: tags", self.command("--resume-status", ".").stdout)
        self.env["GEARFLOW_TEST_STORE_RC"] = "0"
        self.assertSuccess(self.command("update", "--prepare-only", "--resume", "."))
        self.assertEqual(self.calls(), ["changelog", "store-tags", "store-tags"])


class PublicationTests(SplitWorkflowTest):
    def test_publish_refuses_unsigned_tag_before_any_push(self):
        self.initial_package()
        remote = self.publication_tools()
        self.tool("gear-create-tag", "git tag 1.0-alt1\n")
        result = self.command("publish", ".", "--gitery-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("annotated signed tag", result.stderr)
        self.assertFalse((remote / "refs/heads/sisyphus").exists())
        self.assertIn("Next stage: tag", self.command("--resume-status", ".").stdout)

    def test_clean_tree_cannot_create_an_empty_publication(self):
        self.initial_package()
        self.commit()
        self.publication_tools()
        head = self.git("rev-parse", "HEAD")
        result = self.command("publish", ".", "--gitery-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No packaging changes", result.stderr)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.calls(), [])

    def test_initial_build_then_publish_pushes_real_refs_and_excludes_log(self):
        self.initial_package()
        remote = self.publication_tools()
        log = self.repo / "build.log"
        self.assertSuccess(self.command("build", ".", "--log", str(log)))
        self.write("altlinux/restored.patch", "reviewed patch\n")
        result = self.command("publish", ".", "--gitery-only")
        self.assertSuccess(result)
        self.assertEqual(self.calls(), ["gear", "hsh", "commit", "tag"])
        self.assertEqual(
            (remote / "refs/heads/sisyphus").read_text().strip(),
            self.git("rev-parse", "HEAD"),
        )
        self.assertEqual(
            (remote / "refs/tags/1.0-alt1").read_text().strip(),
            self.git("rev-parse", "refs/tags/1.0-alt1"),
        )
        self.assertEqual(
            self.git("show", "HEAD:altlinux/restored.patch"), "reviewed patch"
        )
        self.assertNotIn("build.log", self.git("ls-files"))
        progress = self.command("progress", ".")
        self.assertSuccess(progress)
        self.assertIn("Progress: 9/9", progress.stdout)
        self.assertIn("Girar submission was not requested", progress.stdout)
        self.assertSuccess(
            self.shell(
                "! git config --local --get gearflow.gitery-only && "
                "! git config --local --get gear-update-upstream.resume"
            )
        )

    def test_failed_push_can_resume_without_recommitting_or_submitting_to_girar(self):
        self.initial_package()
        remote = self.publication_tools()
        hook = remote / "hooks/pre-receive"
        hook.write_text(
            "#!/bin/sh\nwhile read old new ref; do\ncase $ref in refs/tags/*) exit 1;; esac\ndone\n"
        )
        hook.chmod(0o755)
        result = self.command("publish", ".", "--gitery-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git("config", "--get", "gearflow.gitery-only"), "true")
        self.assertIn(
            "Next stage: push-tag", self.command("--resume-status", ".").stdout
        )
        head = self.git("rev-parse", "HEAD")
        hook.unlink()
        self.assertSuccess(self.command("resume", "."))
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertEqual(self.calls(), ["commit", "tag"])
        self.assertTrue((remote / "refs/tags/1.0-alt1").exists())

    def test_prepared_update_failed_build_retry_and_gitery_only_publication(self):
        self.update_package()
        self.assertSuccess(
            self.command("update", "--prepare-only", ".", input="yes\n2.0\n")
        )
        self.env["GEARFLOW_TEST_BUILD_RC"] = "46"
        log = self.repo / "build.log"
        self.assertEqual(self.command("build", ".", "--log", str(log)).returncode, 46)
        self.assertIn("Next stage: build", self.command("--resume-status", ".").stdout)
        self.write("altlinux/restored.patch", "reviewed after failed build\n")
        self.env["GEARFLOW_TEST_BUILD_RC"] = "0"
        self.assertSuccess(self.command("build", ".", "--log", str(log)))
        remote = self.publication_tools(version="2.0")
        self.assertSuccess(self.command("publish", ".", "--gitery-only"))
        self.assertTrue((remote / "refs/tags/2.0-alt1").exists())
        self.assertEqual(
            self.calls(),
            ["changelog", "store-tags", "gear", "hsh", "gear", "hsh", "commit", "tag"],
        )
