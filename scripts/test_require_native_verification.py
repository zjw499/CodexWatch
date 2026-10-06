import contextlib
import io
import json
import os
import unittest
from unittest.mock import patch

import require_native_verification as gate


class NativeReleaseGateTests(unittest.TestCase):
    def run_gate(self, *, changed_watch=False, conclusion="success", workflow="Verify Scribe Pilot phone and Watch"):
        def response(request, timeout):
            path = request.full_url.split("/repos/example/app/", 1)[1]
            if path == "actions/runs/123":
                value = {"name": workflow, "head_sha": "tested", "status": "completed", "conclusion": conclusion}
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
               "NATIVE_VERIFICATION_RUN": "Pilot release\nnative-verification-run=123"}
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

    def test_missing_native_source_is_rejected(self):
        def get(path):
            if path.startswith("commits/"): return {"commit": {"tree": {"sha": "incomplete"}}}
            return {"tree": [{"path": "watchos", "sha": "watch"}]}
        with self.assertRaisesRegex(RuntimeError, "source is incomplete"):
            gate.source_fingerprint(get, "test")


if __name__ == "__main__":
    unittest.main()
