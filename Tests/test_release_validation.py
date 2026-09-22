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

    def test_version_compare_is_numeric(self):
        cases = {("1.0.9", "1.0.94"): "-1", ("1.0.95", "1.0.94"): "1", ("1.0.94", "1.0.94"): "0",
                 ("2.0.0", "1.9.99"): "1", ("1.10.0", "1.9.0"): "1", ("1.0.010", "1.0.9"): "1"}
        for (left, right), expected in cases.items():
            with self.subTest(left=left, right=right):
                result = self.run_function("version_compare", left, right)
                self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_lower_version_is_rejected(self):
        for requested, allowed in (("1.0.9", False), ("1.0.93", False), ("1.0.94", True),
                                   ("1.0.95", True), ("1.1.0", True)):
            with self.subTest(requested=requested):
                result = self.run_function("require_version_not_lower", requested, "1.0.94")
                self.assertEqual(result.returncode == 0, allowed, result.stderr)

    # --- 임시 git 저장소 헬퍼 ---
    def git(self, repo, *arguments):
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        return subprocess.run(["git", "-C", str(repo), *arguments], env=env,
                              capture_output=True, text=True, check=True)

    def make_repo(self, version="1.0.94", build="95", published=True):
        repo = self.root / "repo"
        (repo / "updates").mkdir(parents=True)
        (repo / "Casks").mkdir()
        (repo / "scripts").mkdir()
        for name in ("release.sh", "release-validation.sh"):
            target = repo / "scripts" / name
            target.write_text((VALIDATOR.parent / name).read_text())
            target.chmod(0o755)
        (repo / "project.yml").write_text(
            f'settings:\n  base:\n    MARKETING_VERSION: "{version}"\n    CURRENT_PROJECT_VERSION: "{build}"\n'
            'targets: {}\n')
        (repo / ".gitignore").write_text("dist/\nbuild/\nbuild-check.log\n")
        (repo / "appcast.xml").write_text("<rss/>\n")
        (repo / "Casks/oh-my-opensnap.rb").write_text(f'version "{version}"\nsha256 "old"\n')
        if published:
            (repo / f"updates/oh-my-opensnap-{version}.zip").write_bytes(b"zip-" + version.encode())
        self.git(repo, "init", "-q", "-b", "main")
        self.git(repo, "add", ".")
        self.git(repo, "commit", "-q", "-m", "init")
        return repo

    def run_in_repo(self, repo, function, *arguments):
        return subprocess.run(["bash", "-c", 'source scripts/release-validation.sh; "$@"', "check", function, *arguments],
                              cwd=repo, capture_output=True, text=True)

    def test_clean_tree_is_required_without_version(self):
        repo = self.make_repo()
        self.assertEqual(self.run_in_repo(repo, "require_clean_release_tree").returncode, 0)
        (repo / "appcast.xml").write_text("<rss>changed</rss>\n")
        self.assertNotEqual(self.run_in_repo(repo, "require_clean_release_tree").returncode, 0)

    def test_rehearsal_outputs_for_same_version_are_allowed(self):
        repo = self.make_repo()
        # `release.sh 1.0.95` 리허설이 남기는 변경
        (repo / "project.yml").write_text((repo / "project.yml").read_text()
                                          .replace("1.0.94", "1.0.95").replace('"95"', '"96"'))
        (repo / "appcast.xml").write_text("<rss>1.0.95</rss>\n")
        (repo / "Casks/oh-my-opensnap.rb").write_text('version "1.0.95"\nsha256 "new"\n')
        (repo / "updates/oh-my-opensnap-1.0.95.zip").write_bytes(b"zip")
        result = self.run_in_repo(repo, "require_clean_release_tree", "1.0.95")
        self.assertEqual(result.returncode, 0, result.stderr)
        # 다른 버전을 게시하려 하면 거부
        self.assertNotEqual(self.run_in_repo(repo, "require_clean_release_tree", "1.0.96").returncode, 0)

    def test_unrelated_changes_are_rejected_even_with_version(self):
        repo = self.make_repo()
        (repo / "project.yml").write_text((repo / "project.yml").read_text()
                                          .replace("1.0.94", "1.0.95").replace("targets: {}", "targets: {x: 1}"))
        self.assertNotEqual(self.run_in_repo(repo, "require_clean_release_tree", "1.0.95").returncode, 0)
        self.git(repo, "checkout", "--", "project.yml")
        (repo / "Sources.swift").write_text("// stray")
        self.assertNotEqual(self.run_in_repo(repo, "require_clean_release_tree", "1.0.94").returncode, 0)

    def test_git_has_path_detects_committed_update_zip(self):
        repo = self.make_repo()
        self.assertEqual(self.run_in_repo(repo, "git_has_path", "HEAD", "updates/oh-my-opensnap-1.0.94.zip").returncode, 0)
        self.assertNotEqual(self.run_in_repo(repo, "git_has_path", "HEAD", "updates/oh-my-opensnap-1.0.95.zip").returncode, 0)

    def run_release(self, repo, *arguments, extra_path=None):
        path = os.environ["PATH"] if extra_path is None else str(extra_path) + os.pathsep + os.environ["PATH"]
        env = {**os.environ, "PATH": path, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
        return subprocess.run(["bash", str(repo / "scripts/release.sh"), *arguments],
                              env=env, capture_output=True, text=True)

    def test_release_script_rejects_version_typo(self):
        repo = self.make_repo()
        result = self.run_release(repo, "1.0.9")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("낮습니다", result.stderr)

    def test_release_script_refuses_to_rebuild_committed_version(self):
        repo = self.make_repo()
        result = self.run_release(repo, "1.0.94")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("다시 빌드하지 않습니다", result.stderr)
        self.assertFalse((repo / "build-check.log").exists(), "재빌드 단계에 들어가면 안 된다")

    def make_published_remote(self, repo):
        remote = self.root / "remote.git"
        subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(remote)], check=True)
        self.git(repo, "remote", "add", "origin", str(remote))
        self.git(repo, "push", "-q", "-u", "origin", "main")
        return remote

    def mock_release_tools(self, zip_path, remote=None):
        tools = self.root / "tools"
        tools.mkdir()
        log = self.root / "calls.log"
        # gh 호출 시점의 원격 main 을 함께 남겨 "릴리스 → 푸시" 순서를 검증한다.
        remote_head = f'; echo "remote $(git --git-dir="{remote}" rev-parse main)" >> "{log}"' if remote else ""
        scripts = {
            "gh": f'echo "gh $*" >> "{log}"{remote_head}; [ "$2" = view ] && exit 1; exit 0',
            "codesign": "exit 0",
            "xcrun": "exit 0",
            # 공개 ZIP 다운로드 = 커밋된 ZIP 과 같은 바이트
            "curl": f'while [ $# -gt 0 ]; do [ "$1" = --output ] && cp "{zip_path}" "$2"; shift; done',
        }
        for name, body in scripts.items():
            path = tools / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o755)
        return tools, log

    def test_resume_without_previous_dmg_aborts(self):
        repo = self.make_repo()
        self.make_published_remote(repo)
        tools, log = self.mock_release_tools(repo / "updates/oh-my-opensnap-1.0.94.zip")
        result = self.run_release(repo, "1.0.94", "--publish", extra_path=tools)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("버전을 올려", result.stderr)
        self.assertFalse(log.exists(), "GitHub Release 를 건드리면 안 된다")

    def test_resume_uploads_committed_zip_before_pushing(self):
        repo = self.make_repo()
        remote = self.make_published_remote(repo)
        zip_path = repo / "updates/oh-my-opensnap-1.0.94.zip"
        dmg = repo / "dist/oh-my-opensnap-1.0.94.dmg"
        dmg.parent.mkdir()
        dmg.write_bytes(b"dmg")
        sha = subprocess.run(["shasum", "-a", "256", str(dmg)], capture_output=True, text=True).stdout.split()[0]
        (repo / "Casks/oh-my-opensnap.rb").write_text(f'version "1.0.94"\nsha256 "{sha}"\n')
        self.git(repo, "commit", "-q", "-am", "release: v1.0.94 (appcast 갱신)")   # 푸시 전 실패한 상태
        tools, log = self.mock_release_tools(zip_path, remote)
        result = self.run_release(repo, "1.0.94", "--publish", extra_path=tools)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = log.read_text()
        self.assertIn("gh release create v1.0.94", calls)
        self.assertIn(str(zip_path), calls)
        head = self.git(repo, "rev-parse", "HEAD").stdout.strip()
        remote_head = subprocess.run(["git", "-C", str(remote), "rev-parse", "main"],
                                     capture_output=True, text=True).stdout.strip()
        self.assertEqual(head, remote_head)
        self.assertIn("remote ", calls)
        self.assertNotIn(f"remote {head}", calls, "릴리스 커밋은 GitHub Release 생성 뒤에 푸시돼야 한다")
        self.assertFalse((repo / "build-check.log").exists(), "재개는 재빌드하지 않는다")

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
