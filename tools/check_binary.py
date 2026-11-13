"""Exercise the release executable outside the checkout, without Python on PATH."""

import http.server
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from pathlib import Path


def check(binary):
    with tempfile.TemporaryDirectory(prefix="gearflow binary ") as directory:
        root = Path(directory)
        tools = root / "bin"
        tools.mkdir()
        for name in ("bash", "sh", "git", "dirname", "cat"):
            location = shutil.which(name)
            if location is None:
                raise RuntimeError(f"Required test tool not found: {name}")
            (tools / name).symlink_to(location)
        env = dict(
            os.environ,
            PATH=str(tools),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_AUTHOR_NAME="Binary check",
            GIT_AUTHOR_EMAIL="check@example.invalid",
            GIT_COMMITTER_NAME="Binary check",
            GIT_COMMITTER_EMAIL="check@example.invalid",
        )
        for key in (
            "PYTHONPATH",
            "PYTHONHOME",
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_COMMON_DIR",
        ):
            env.pop(key, None)

        def run(*args, expected=0, input=None, program=binary):
            result = subprocess.run(
                [str(program), *args],
                cwd=root,
                env=env,
                input=input,
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode != expected:
                raise AssertionError(
                    (args, result.returncode, result.stdout, result.stderr)
                )
            return result

        assert run("--version").stdout.startswith("gearflow ")
        for args in (
            ("--help",),
            ("check", "--help"),
            ("task", "show", "--help"),
            ("update", "--help"),
            ("build", "--help"),
            ("publish", "--help"),
            ("workflow-help",),
        ):
            run(*args)

        def git(*args):
            return run(*args, program=tools / "git").stdout.strip()

        git("init", "-b", "sisyphus")
        (root / ".gear").mkdir()
        (root / ".gear/rules").write_text("tar: .\n")
        (root / "source.txt").write_text("original\n")
        git("add", "-A")
        git("-c", "commit.gpgsign=false", "commit", "-m", "fixture")
        (root / "source.txt").write_text("prepared\n")

        # This is the same self-invocation used from the packaged Bash workflow.
        run("-m", "gearflow.services", "stage")
        assert git("diff", "--cached", "--name-only") == "source.txt"
        run("progress", str(root))
        for name, body in (
            (
                "gear",
                'printf "stdout marker\\n"; printf "stderr marker\\n" >&2; exec hsh',
            ),
            ("hsh", 'exit "$BUILD_STATUS"'),
        ):
            target = tools / name
            target.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            target.chmod(0o755)
        log = root / "build.log"
        for status in (43, 0):
            env["BUILD_STATUS"] = str(status)
            result = run("build", str(root), "--log", str(log), expected=status)
            assert not result.stdout and not result.stderr
            assert log.read_text() == "stdout marker\nstderr marker\n"
            assert "build.log" not in git("diff", "--cached", "--name-only")

        # Exercise frozen multiprocessing against a local rejecting HTTPS proxy.
        # It must return the HTTP error, without recursion or external requests.
        requests = []

        class Proxy(http.server.BaseHTTPRequestHandler):
            def do_CONNECT(self):
                requests.append(self.path)
                self.send_error(403, "Offline binary check")

            def log_message(self, *args):
                pass

        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            proxy = f"http://127.0.0.1:{server.server_port}"
            env.update(https_proxy=proxy, HTTPS_PROXY=proxy, no_proxy="", NO_PROXY="")
            try:
                result = run(
                    "task", "-m", "scala", "--json", "--timeout", "5", expected=1
                )
                assert requests and "403" in result.stderr, result.stderr
                assert "worker exited" not in result.stderr, result.stderr
            finally:
                server.shutdown()
                thread.join()
    print("Standalone binary checks passed (no Python on PATH).")


if __name__ == "__main__":
    check(Path(sys.argv[1]).resolve(strict=True))
