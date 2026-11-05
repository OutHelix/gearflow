import io
import json
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from gearflow.rdb import dependency_url, query_rebuilds, rebuild_candidates


class RdbTests(unittest.TestCase):
    def data(self):
        rows = [
            {"name": "demo", "depth": 0},
            {"name": "lib-first", "depth": 1},
            {"name": "lib-second", "depth": 1},
            {"name": "lib-first", "depth": 2},
        ]
        return {"length": len(rows), "dependencies": rows}

    def test_deduplicates_in_build_order_and_excludes_roots(self):
        self.assertEqual(
            rebuild_candidates(self.data(), ["demo"]), ["lib-first", "lib-second"]
        )

    def test_absent_roots_are_an_error_including_empty_responses(self):
        for data in (self.data(), {"length": 0, "dependencies": []}):
            with (
                self.subTest(data=data),
                self.assertRaisesRegex(ValueError, "absent from RDB"),
            ):
                rebuild_candidates(data, ["missing"])

    def test_incomplete_or_malformed_plans_are_rejected(self):
        cases = [
            None,
            {},
            {"length": 1, "dependencies": []},
            {"length": True, "dependencies": [{}]},
        ]
        for row in (
            None,
            {"name": "bad name", "depth": 1},
            {"name": "ok", "depth": True},
            {"name": "ok", "depth": -1},
        ):
            data = self.data()
            data["dependencies"][-1] = row
            cases.append(data)
        for data in cases:
            with self.subTest(data=data), self.assertRaises(ValueError):
                rebuild_candidates(data, ["demo"])

    def test_request_carries_all_roots_and_parameters(self):
        url = dependency_url(
            "https://example.invalid/api/", "2", "both", "p11", ["a", "b+"]
        )
        self.assertEqual(urlsplit(url).path, "/api/package/what_depends_src")
        self.assertEqual(
            parse_qs(urlsplit(url).query),
            {
                "branch": ["p11"],
                "depth": ["2"],
                "dptype": ["both"],
                "use_last_tasks": ["true"],
                "packages": ["a", "b+"],
            },
        )

    def test_invalid_settings_fail_before_network_access(self):
        for base, depth, dptype in (
            ("file:///tmp/data", "1", "both"),
            ("https://example.invalid", "0", "both"),
            ("https://example.invalid", "1", "invalid"),
        ):
            with self.subTest(base=base, depth=depth, dptype=dptype):
                with patch("gearflow.rdb.urllib.request.urlopen") as request:
                    with self.assertRaises(ValueError):
                        query_rebuilds(base, depth, dptype, "sisyphus", ["demo"])
                    request.assert_not_called()

    def test_http_result_is_validated(self):
        with patch(
            "gearflow.rdb.urllib.request.urlopen",
            return_value=io.BytesIO(json.dumps(self.data()).encode()),
        ) as request:
            self.assertEqual(
                query_rebuilds(
                    "https://example.invalid", "1", "both", "sisyphus", ["demo"]
                ),
                ["lib-first", "lib-second"],
            )
            self.assertEqual(request.call_args.kwargs["timeout"], 120)
