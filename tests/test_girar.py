from pathlib import Path
import unittest

from gearflow.girar import parse_task

FIXTURE = Path(__file__).parent / "fixtures" / "task-show.txt"


class TaskTests(unittest.TestCase):
    def setUp(self):
        self.text = FIXTURE.read_text()

    def test_source_roots_exclude_rebuild_copy_delete_and_deleted_subtasks(self):
        snapshot = parse_task(self.text, "123")
        self.assertEqual(snapshot.branch, "sisyphus")
        self.assertEqual(snapshot.roots, ("actual-source", "demo", "lib-extra"))
        self.assertEqual(snapshot.present, (
            "actual-source", "already-rebuilt", "copied", "demo", "lib-extra", "removed",
        ))
        self.assertEqual(len(snapshot.notices), 1)
        self.assertIn("gear repository name demo", snapshot.notices[0])

    def test_signature_tracks_actions_but_ignores_incidental_output(self):
        original = parse_task(self.text, "123")
        reordered = "\n".join([self.text.splitlines()[0], *reversed(self.text.splitlines()[1:])])
        self.assertEqual(original.signature, parse_task(reordered, "123").signature)
        self.assertEqual(original.signature, parse_task(self.text + "extra output\n", "123").signature)
        changed = self.text.replace("tag_id=abc", "tag_id=def")
        self.assertNotEqual(original.signature, parse_task(changed, "123").signature)

    def test_rejects_wrong_id_locked_or_unmodifiable_task(self):
        cases = [
            self.text.replace("id=123", "id=124"),
            self.text.replace("locked=no", "locked=yes"),
            self.text.replace("state=NEW", "state=DONE"),
            self.text.replace("repo=sisyphus", "repo=../bad"),
            "unrecognized response",
        ]
        for text in cases:
            with self.subTest(text=text[:80]), self.assertRaises(ValueError):
                parse_task(text, "123")

    def test_rejects_malformed_srpm_and_shell_tokens(self):
        for value in ("not-an-srpm", "$(touch injected).src.rpm"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                parse_task(self.text.replace("lib-extra-1.0-alt1.src.rpm", value), "123")
        with self.assertRaises(ValueError):
            parse_task(self.text.replace("package=copied", "package=bad;command"), "123")

    def test_existing_rebuild_never_becomes_a_source_root(self):
        text = self.text.replace("100:tag_name=", "100:rebuild_from=sisyphus\n 100:tag_name=")
        snapshot = parse_task(text, "123")
        self.assertNotIn("demo", snapshot.roots)
        self.assertIn("demo", snapshot.present)
