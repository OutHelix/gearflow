from pathlib import Path

from tests.support import RepositoryTest

SPEC = "Name: demo\nVersion: 1.0\nRelease: alt1\nVcs: git+https://example.invalid/demo.git\n\n%changelog\n"


class LayoutTests(RepositoryTest):
    def test_valid_layout_keeps_upstream_metadata_and_source_tree_paths(self):
        self.write("altlinux/demo.spec", SPEC)
        self.write(
            ".gear/rules",
            (
                "spec: altlinux/demo.spec\ntar: v@version@:src\n"
                "copy: .gear/upstream/filter-tag\n"
            ),
        )
        self.write(".gear/upstream/filter-tag", "filter\n")
        before = sorted(
            str(path.relative_to(self.repo)) for path in self.repo.rglob("*")
        )
        result = self.shell("check_altlinux_layout .")
        self.assertSuccess(result)
        self.assertIn("Layout is valid", result.stdout)
        self.assertEqual(
            before,
            sorted(str(path.relative_to(self.repo)) for path in self.repo.rglob("*")),
        )

    def test_migration_commits_only_its_paths(self):
        self.write("demo.spec", SPEC)
        self.write(
            ".gear/rules",
            "# keep comment\nspec: demo.spec\ntar: v@version@:.\ncopy: .gear/service\n",
        )
        self.write(".gitignore", "/altlinux/service*\n")
        self.write(".gear/service", "service\n")
        self.write("unrelated.txt", "before\n")
        self.commit()
        self.write("unrelated.txt", "staged change\n")
        self.git("add", "unrelated.txt")
        self.write("altlinux/service.local", "ignored local file\n")
        result = self.shell(
            "PROTECT_LAYOUT_COMMIT=1; "
            "if ! ensure_altlinux_layout_interactive .gear/rules demo <<< m; then exit 1; fi"
        )
        self.assertSuccess(result)
        self.assertTrue((self.repo / "altlinux/demo.spec").exists())
        self.assertEqual(self.git("show", "HEAD:altlinux/service"), "service")
        self.assertEqual(self.git("ls-files", "altlinux/service.local"), "")
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "unrelated.txt")
        self.assertEqual(self.git("show", "HEAD:unrelated.txt"), "before")
        rules = (self.repo / ".gear/rules").read_text()
        self.assertIn("# keep comment", rules)
        self.assertIn("tar: v@version@:.", rules)
        self.assertIn("spec: altlinux/demo.spec", rules)

    def test_failed_layout_commit_leaves_changes_staged_and_stops_update(self):
        self.write(".gear/demo.spec", SPEC)
        self.write(".gear/rules", "spec: .gear/demo.spec\ntar: v@version@:.\n")
        self.commit()
        head = self.git("rev-parse", "HEAD")
        self.git("tag", "1.0-alt1")
        hook = self.repo / ".git/hooks/pre-commit"
        hook.write_bytes(b"#!/bin/sh\nexit 1\n")
        hook.chmod(0o755)
        result = self.shell("check_common_commands() { :; }; main <<< $'y\\nm'")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Could not commit the layout migration", result.stderr)
        self.assertNotIn("Layout migration commit:", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD"), head)
        self.assertIn("altlinux/demo.spec", self.git("diff", "--cached", "--name-only"))

        result = self.shell("check_common_commands() { :; }; main </dev/null")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Working tree is not clean", result.stderr)

        hook.unlink()
        self.git("commit", "-m", "Moved packaging files to altlinux directory")
        result = self.shell(
            "check_common_commands() { :; }; "
            "load_upstream_tags() { printf 'Reached upstream tag check\\n'; exit 0; }; "
            "main --local-repository . </dev/null"
        )
        self.assertSuccess(result)
        self.assertIn("Reached upstream tag check", result.stdout)

    def test_rules_tokenizer_preserves_spaces_and_rejects_unclosed_quotes(self):
        result = self.shell(
            'split_rule_arguments \'"altlinux/file with spaces" altlinux/other\'; printf "%s\\n" "${RULE_ARGS[@]}"'
        )
        self.assertSuccess(result)
        self.assertEqual(
            result.stdout.splitlines(), ["altlinux/file with spaces", "altlinux/other"]
        )
        result = self.shell("split_rule_arguments '\"unclosed'")
        self.assertNotEqual(result.returncode, 0)


class MetadataTests(RepositoryTest):
    def test_tag_inference_and_rules_rewrite_keep_unrelated_lines(self):
        self.write(
            ".gear/rules",
            (
                "# tar: v@version@:.\nspec: altlinux/demo.spec\n"
                "tar: v@version@:.\ncopy: altlinux/version.txt\n"
            ),
        )
        result = self.shell(
            "infer_upstream_version_template 1.0 release-1.0 release-2.0; "
            "rewrite_rule_tag_template .gear/rules v@version@ release-@version@; "
            'resolve_gear_source_tag .gear/rules demo 2.0; printf "%s\\n" "$RESOLVED_GEAR_SOURCE_TAG"'
        )
        self.assertSuccess(result)
        self.assertEqual(
            result.stdout.splitlines(), ["release-@version@", "release-2.0"]
        )
        self.assertEqual(
            (self.repo / ".gear/rules").read_text(),
            (
                "# tar: v@version@:.\nspec: altlinux/demo.spec\n"
                "tar: release-@version@:.\ncopy: altlinux/version.txt\n"
            ),
        )

    def test_ambiguous_tags_are_not_guessed(self):
        result = self.shell("infer_upstream_version_template 1.0 one-1.0 two-1.0")
        self.assertNotEqual(result.returncode, 0)

    def test_changelog_failure_restores_exact_original_spec(self):
        original = SPEC + "\n\n"
        self.write("altlinux/demo.spec", original)
        result = self.shell(
            'add_changelog() { printf "partial edit\\n" >> "$1"; return 1; }; '
            "update_spec altlinux/demo.spec 2.0"
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("original contents restored", result.stderr)
        self.assertEqual((self.repo / "altlinux/demo.spec").read_text(), original)


class TaskScanTests(RepositoryTest):
    def test_scan_dry_run_skips_present_packages_and_never_mutates_task(self):
        fixture = Path(__file__).parent / "fixtures/task-show.txt"
        result = self.shell(
            'TASK_FIXTURE="$1"; '
            'girar_ssh() { [[ "$1 $2" == "task show" ]] || die "unexpected mutation"; cat "$TASK_FIXTURE"; }; '
            'query_rebuild_candidates() { printf "%s\\n" already-rebuilt new-first new-second new-first; }; '
            "scan_task_rebuilds 123 1",
            str(fixture),
        )
        self.assertSuccess(result)
        self.assertIn("Unique rebuilds to add (2)", result.stdout)
        self.assertIn("  new-first\n  new-second\n", result.stdout)
        self.assertNotIn("  already-rebuilt\n", result.stdout)
        self.assertIn("Dry run", result.stdout)

    def test_rebuilds_are_submitted_once_in_one_command(self):
        fixture = Path(__file__).parent / "fixtures/task-show.txt"
        result = self.shell(
            'TASK_FIXTURE="$1"; '
            'girar_ssh() { if [[ "$1 $2" == "task show" ]]; then cat "$TASK_FIXTURE"; '
            'else printf "%s\\n" "$*" >> calls; fi; }; '
            'query_rebuild_candidates() { printf "%s\\n" new-first new-second new-first; }; '
            "ask_yes_no() { return 0; }; scan_task_rebuilds 123",
            str(fixture),
        )
        self.assertSuccess(result)
        self.assertEqual(
            (self.repo / "calls").read_text(),
            "task add 123 rebuild new-first new-second\n",
        )
