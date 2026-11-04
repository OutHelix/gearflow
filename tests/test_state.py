from tests.support import RepositoryTest


def checkpoint(values):
    # Original v1 protocol counts bytes using LC_ALL=C, including UTF-8 tags.
    return "v1;" + "".join(f"{len(value.encode())}:{value}" for value in values)


class StateTests(RepositoryTest):
    def setUp(self):
        super().setUp()
        self.write("tracked", "fixture\n")
        self.commit()
        head = self.git("rev-parse", "HEAD")
        self.values = [
            "build", "demo", "2.0", "alt1", "релиз-2.0", head,
            "sisyphus", head, "none", "", "", "0", "",
        ]

    def test_reads_original_checkpoint_and_status_does_not_modify_it(self):
        payload = checkpoint(self.values)
        self.git("config", "--local", "gear-update-upstream.resume", payload)
        before = (self.repo / ".git/config").read_bytes()
        result = self.shell('SCRIPT_INVOKED_AS=gearflow; show_resume_status .; show_update_progress .')
        self.assertSuccess(result)
        self.assertIn("Next stage: build", result.stdout)
        self.assertIn("релиз-2.0", result.stdout)
        self.assertIn("Progress: 4/10", result.stdout)
        self.assertEqual((self.repo / ".git/config").read_bytes(), before)

    def test_save_round_trips_original_format(self):
        payload = checkpoint(self.values)
        self.git("config", "--local", "gear-update-upstream.resume", payload)
        result = self.shell('load_resume_state; save_resume_state')
        self.assertSuccess(result)
        self.assertEqual(self.git("config", "--get", "gear-update-upstream.resume"), payload)

    def test_rejects_corrupt_state(self):
        for payload in ("v2;", "v1;999:short", checkpoint(self.values) + "trailing"):
            with self.subTest(payload=payload):
                self.git("config", "--local", "gear-update-upstream.resume", payload)
                result = self.shell('load_resume_state')
                self.assertNotEqual(result.returncode, 0)

    def test_unknown_girar_result_remains_pending_until_user_decides(self):
        self.values[0] = "girar-pending"
        self.git("config", "--local", "gear-update-upstream.resume", checkpoint(self.values))
        result = self.shell('SCRIPT_INVOKED_AS=gearflow; show_update_progress .')
        self.assertSuccess(result)
        self.assertIn("[check", result.stdout)
        self.assertIn("Check Girar before retrying", result.stdout)

    def test_legacy_state_is_read_without_migration_then_migrates_on_save(self):
        fields = (
            "stage package version release upstream-tag upstream-commit branch "
            "head tag-mode old-template new-template layout-skipped gear-tag"
        ).split()
        legacy = self.repo / ".git/gear-update-upstream.state"
        self.git("config", "--file", str(legacy), "resume.schema", "1")
        for field, value in zip(fields, self.values):
            self.git("config", "--file", str(legacy), f"resume.{field}", value)
        result = self.shell('show_resume_status .')
        self.assertSuccess(result)
        self.assertTrue(legacy.exists())
        result = self.shell('load_resume_state; save_resume_state')
        self.assertSuccess(result)
        self.assertFalse(legacy.exists())
        self.assertEqual(self.git("config", "--get", "gear-update-upstream.resume"), checkpoint(self.values))
