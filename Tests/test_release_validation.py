import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


VALIDATOR = Path(__file__).resolve().parents[1] / "scripts/release-validation.sh"


class ReleaseValidationTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory()
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        for name in ("codesign", "xcrun", "spctl"):
            path = self.root / name
            path.write_text("""#!/bin/bash
case "$MOCK_FAILURE:$0:$*" in
  signature:*codesign:*) exit 1 ;;
  staple:*xcrun:*) exit 1 ;;
  dmg:*spctl:*test.dmg*) echo 'rejected'; exit 1 ;;
esac
if [[ "$0" == *spctl ]]; then
  echo accepted
  if [[ "$MOCK_FAILURE" == source ]]; then echo 'source=Developer ID';
  else echo 'source=Notarized Developer ID'; fi
fi
""")
            path.chmod(0o755)

    def run_function(self, function, *arguments, failure=""):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; shift; "$@"', "check", str(VALIDATOR), function, *arguments],
            env={**os.environ, "PATH": str(self.root) + os.pathsep + os.environ["PATH"],
                 "MOCK_FAILURE": failure}, capture_output=True, text=True)

    def test_unsigned_publication_is_rejected(self):
        self.assertNotEqual(self.run_function("validate_release_options", "1.0.90", "1", "1").returncode, 0)

    def test_publication_cannot_skip_sparkle_feed(self):
        result = subprocess.run(
            ["bash", str(VALIDATOR.parent / "release.sh"), "1.0.91", "--skip-appcast", "--publish"],
            capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("알 수 없는 옵션", result.stderr)

    def test_invalid_version_is_rejected(self):
        self.assertNotEqual(self.run_function("validate_release_options", "--oops", "0", "0").returncode, 0)

    def test_local_signed_build_is_allowed(self):
        self.assertEqual(self.run_function("validate_release_options", "", "0", "1").returncode, 0)

    def test_only_accepted_notarization_is_allowed(self):
        for status in ("Accepted", "Invalid", "In Progress"):
            with self.subTest(status=status):
                path = self.root / "notary.json"
                path.write_text(json.dumps({"status": status, "id": "submission"}))
                result = self.run_function("require_accepted_notarization", str(path))
                self.assertEqual(result.returncode == 0, status == "Accepted")

    def test_every_artifact_gate_must_pass(self):
        for failure in ("", "signature", "staple", "dmg", "source"):
            with self.subTest(failure=failure):
                result = self.run_function("verify_notarized_artifacts", "test.app", "test.dmg", failure=failure)
                self.assertEqual(result.returncode == 0, failure == "", result.stdout + result.stderr)

    def test_history_must_match_the_actual_submission(self):
        path = self.root / "history.json"
        path.write_text(json.dumps({"history": [{"id": "accepted-id", "status": "Accepted"},
                                                {"id": "rejected-id", "status": "Invalid"}]}))
        for submission in ("accepted-id", "rejected-id", "missing-id"):
            with self.subTest(submission=submission):
                result = self.run_function("require_notarization_history", str(path), submission)
                self.assertEqual(result.returncode == 0, submission == "accepted-id")


if __name__ == "__main__":
    unittest.main()
