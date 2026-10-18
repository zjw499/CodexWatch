import contextlib
import io
import json
import os
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

import require_native_verification as gate


class NativeReleaseGateTests(unittest.TestCase):
    def run_gate(self, *, changed_watch=False, conclusion="success", workflow="Verify Scribe Pilot phone and Watch", pilot=False, required_conclusion="success"):
        def response(request, timeout):
            path = request.full_url.split("/repos/example/app/", 1)[1]
            if path == "actions/runs/123":
                value = {"name": workflow, "head_sha": "tested", "status": "completed", "conclusion": conclusion}
            elif path == "actions/runs/123/jobs":
                value = {"jobs": [{"name": "native", "steps": [
                    {"name": name, "status": "completed", "conclusion": required_conclusion} for name in gate.REQUIRED_STEPS] + [
                    {"name": "Capture Watch preview", "status": "completed", "conclusion": conclusion}]}]}
            elif path.startswith("commits/"):
                value = {"commit": {"tree": {"sha": path.split("/")[-1]}}}
            elif path.startswith("git/trees/"):
                tested = path.endswith("tested")
                value = {"tree": [{"path": p, "sha": "different" if p == "watchos" and tested and changed_watch else p + "-blob"}
                                  for p in gate.SOURCE_PATHS] + [{"path": ".github", "sha": "different-release-workflow" if tested else "new-release-workflow"}]}
            elif path.startswith("contents/.github/workflows/native-verify.yml?ref="):
                value = {"sha": "same-native-workflow"}
            else:
                raise AssertionError(path)
            return io.BytesIO(json.dumps(value).encode())

        env = {"GITHUB_REPOSITORY": "example/app", "GITHUB_SHA": "release", "GH_TOKEN": "synthetic-secret",
               "NATIVE_VERIFICATION_RUN": "Pilot release\nnative-verification-run=123", "PILOT_RELEASE": "true" if pilot else "false"}
        output = io.StringIO()
        with patch.dict(os.environ, env), patch("urllib.request.urlopen", side_effect=response), contextlib.redirect_stdout(output):
            gate.main()
        self.assertNotIn("synthetic-secret", output.getvalue())
        return output.getvalue()

    def test_successful_matching_source_allows_release_metadata_changes(self):
        self.assertIn("source verified", self.run_gate())

    def test_a_passing_run_for_different_watch_source_cannot_release(self):
        with self.assertRaisesRegex(RuntimeError, "different app source"):
            self.run_gate(changed_watch=True)

    def test_failed_or_cancelled_native_run_blocks_distribution(self):
        for conclusion in ("failure", "cancelled", "timed_out"):
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(RuntimeError, "distribution stopped"):
                self.run_gate(conclusion=conclusion)

    def test_another_workflow_cannot_stand_in_for_native_tests(self):
        with self.assertRaisesRegex(RuntimeError, "native verification workflow"):
            self.run_gate(workflow="Only package artifacts")

    def test_pilot_accepts_completed_checks_when_only_preview_is_cancelled(self):
        output = self.run_gate(pilot=True, conclusion="cancelled")
        self.assertIn("tests passed for pilot distribution", output)
        self.assertIn("preview/artifact completion is unverified", output)

    def test_pilot_cannot_release_failed_or_skipped_required_checks(self):
        for conclusion in ("failure", "cancelled", "timed_out", "skipped"):
            with self.subTest(conclusion=conclusion), self.assertRaisesRegex(RuntimeError, "required native check"):
                self.run_gate(pilot=True, required_conclusion=conclusion)

    def test_missing_native_source_is_rejected(self):
        def get(path):
            if path.startswith("commits/"): return {"commit": {"tree": {"sha": "incomplete"}}}
            return {"tree": [{"path": "watchos", "sha": "watch"}]}
        with self.assertRaisesRegex(RuntimeError, "source is incomplete"):
            gate.source_fingerprint(get, "test")

    def test_transient_github_timeout_retries_the_same_read(self):
        request = urllib.request.Request("https://api.github.com/repos/example/app/actions/runs/123")
        outcomes = [urllib.error.URLError("timed out"), io.BytesIO(b'{"status":"completed"}')]
        with patch("urllib.request.urlopen", side_effect=outcomes) as opener, patch("time.sleep") as sleep:
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(gate.read_json(request), {"status": "completed"})
        self.assertEqual(opener.call_count, 2)
        sleep.assert_called_once_with(2)

    def test_persistent_timeout_and_authorization_failure_still_block(self):
        request = urllib.request.Request("https://api.github.com/repos/example/app/actions/runs/123")
        with patch("urllib.request.urlopen", side_effect=urllib.error.URLError("timed out")) as opener, patch("time.sleep"):
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaises(urllib.error.URLError):
                gate.read_json(request)
        self.assertEqual(opener.call_count, 5)
        denied = urllib.error.HTTPError(request.full_url, 401, "Unauthorized", {}, None)
        with patch("urllib.request.urlopen", side_effect=denied) as opener, patch("time.sleep") as sleep:
            with self.assertRaises(urllib.error.HTTPError):
                gate.read_json(request)
        self.assertEqual(opener.call_count, 1)
        sleep.assert_not_called()


if __name__ == "__main__":
    unittest.main()
