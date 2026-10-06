"""Offline backup regressions: generated keys and isolated filesystem/CLI fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "server/scripts/production-db-backup.sh"
WORKFLOWS = ("production-backup.yml", "production-backup-check.yml", "production-restore-drill.yml")


def run_block(workflow, step):
    source = (ROOT / ".github/workflows" / workflow).read_text()
    after_step = source.split(f"      - name: {step}\n", 1)[1]
    after_run = after_step.split("        run: |\n", 1)[1]
    lines = []
    for line in after_run.splitlines():
        if line and not line.startswith("          "):
            break
        lines.append(line[10:] if line else "")
    # Redirect only the storage root, without changing the user's HOME.
    return "\n".join(lines).replace("$HOME", "$BACKUP_TEST_HOME")


class BackupSSHTests(unittest.TestCase):
    def test_generated_key_is_readable_with_and_without_final_newline(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp)
            key_path = directory / "synthetic-key"
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key_path)], check=True)
            key = key_path.read_text()
            original_public = subprocess.check_output(["ssh-keygen", "-y", "-P", "", "-f", str(key_path)])
            # Confirm that this fixture reproduces the old failure.
            key_path.write_text(key.rstrip("\n"))
            old = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", str(key_path)], capture_output=True)
            self.assertNotEqual(old.returncode, 0)
            for workflow in WORKFLOWS:
                for trailing_newline in (False, True):
                    with self.subTest(workflow=workflow, trailing_newline=trailing_newline):
                        env = os.environ | {"BACKUP_TEST_HOME": temp, "EC2_SSH_KEY": key if trailing_newline else key.rstrip("\n"),
                                            "EC2_SSH_KNOWN_HOSTS": "synthetic-host-entry"}
                        result = subprocess.run(["bash", "-c", run_block(workflow, "Prepare SSH")], env=env, capture_output=True)
                        self.assertEqual(result.returncode, 0)
                        prepared = directory / ".ssh/daily-backup"
                        self.assertEqual(prepared.stat().st_mode & 0o777, 0o600)
                        public = subprocess.run(["ssh-keygen", "-y", "-P", "", "-f", str(prepared)], capture_output=True)
                        self.assertEqual(public.returncode, 0)
                        self.assertEqual(public.stdout, original_public)

    def test_manual_no_prune_value_reaches_remote_script(self):
        source = (ROOT / ".github/workflows/production-backup.yml").read_text()
        self.assertIn("type: boolean\n        default: false", source)
        self.assertIn("SKIP_LOCAL_PRUNE: ${{ inputs.skip_local_prune || false }}", source)
        with tempfile.TemporaryDirectory() as temp:
            ssh = Path(temp) / "ssh"
            ssh.write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "${@: -1}"\ncat >/dev/null\n')
            ssh.chmod(0o700)
            for value in ("true", "false"):
                env = os.environ | {"PATH": temp + os.pathsep + os.environ["PATH"], "BACKUP_TEST_HOME": temp,
                                    "BACKUP_BUCKET": "synthetic-backups", "EC2_USER": "synthetic", "EC2_HOST": "example.invalid",
                                    "SKIP_LOCAL_PRUNE": value}
                result = subprocess.run(["bash", "-c", run_block("production-backup.yml", "Back up and upload daily_checklist")],
                                        env=env, cwd=ROOT, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"bash -se -- 'synthetic-backups' '7' '{value}'")


class BackupRetentionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.backups = self.root / "deploy/backups/daily"
        self.backups.mkdir(parents=True)
        (self.root / "deploy/.env").write_text("DB_PASSWORD=synthetic-test-only\n")
        self.old = self.backups / "ritual-cue-old.dump"
        self.old.write_text("preserve old archive")
        old_time = time.time() - 15 * 86400
        os.utime(self.old, (old_time, old_time))
        self.recent = self.backups / "ritual-cue-recent.dump"
        self.recent.write_text("preserve recent archive")
        self.unrelated = self.backups / "unrelated.txt"
        self.unrelated.write_text("preserve unrelated file")
        os.utime(self.unrelated, (old_time, old_time))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.stub("docker-compose", '''
            set -eu
            case " $* " in
              *" pg_dump "*) printf 'synthetic archive' ;;
              *" pg_restore --list "*) cat >/dev/null; exit "${TEST_LIST_EXIT:-0}" ;;
              *) exit 99 ;;
            esac
        ''')
        self.stub("aws", '''
            set -eu
            case "$1 $2" in
              "s3 cp")
                test "$5 $6 $7" = "--only-show-errors --sse AES256"
                printf '%s\\n' "$4" >> "$BACKUP_TEST_HOME/uploads"
                exit "${TEST_UPLOAD_EXIT:-0}"
                ;;
              "s3api head-object") printf '%s\\n' "${TEST_REMOTE_SIZE:-17}" ;;
              *) exit 99 ;;
            esac
        ''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + textwrap.dedent(body))
        path.chmod(0o700)

    def run_backup(self, args=(), overrides=None):
        env = os.environ | {"BACKUP_TEST_HOME": str(self.root), "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}
        env.update(overrides or {})
        # Execute the production script, redirecting its storage root into the fixture.
        return subprocess.run(["bash", "-s", "--", "synthetic-backups", *args],
                              input=SCRIPT.read_text().replace("$HOME", "$BACKUP_TEST_HOME"),
                              env=env, capture_output=True, text=True)

    def assert_preserved(self):
        self.assertEqual(self.old.read_text(), "preserve old archive")
        self.assertEqual(self.recent.read_text(), "preserve recent archive")
        self.assertEqual(self.unrelated.read_text(), "preserve unrelated file")

    def test_no_prune_preserves_all_existing_files_and_uploads_once(self):
        result = self.run_backup(("7", "true"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_preserved()
        self.assertEqual(len((self.root / "uploads").read_text().splitlines()), 1)
        fresh = set(self.backups.glob("*.dump")) - {self.old, self.recent}
        self.assertEqual(len(fresh), 1)
        self.assertEqual(next(iter(fresh)).stat().st_mode & 0o777, 0o600)
        self.assertIn("Postgres archive list verified.", result.stdout)
        self.assertIn("Local backup pruning disabled", result.stdout)
        self.assertIn("(17 bytes)", result.stdout)
        self.assertNotIn("synthetic-test-only", result.stdout + result.stderr)

    def test_default_retention_still_prunes_only_expired_archives(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.old.exists())
        self.assertTrue(self.recent.exists())
        self.assertTrue(self.unrelated.exists())

    def test_invalid_prune_value_fails_before_backup_or_deletion(self):
        result = self.run_backup(("7", "invalid"))
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()
        self.assertFalse((self.root / "uploads").exists())

    def test_archive_validation_failure_never_uploads_or_prunes(self):
        result = self.run_backup(overrides={"TEST_LIST_EXIT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()
        self.assertFalse((self.root / "uploads").exists())
        self.assertFalse(list(self.backups.glob("*.tmp")))

    def test_upload_failure_never_prunes(self):
        result = self.run_backup(overrides={"TEST_UPLOAD_EXIT": "1"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()

    def test_size_mismatch_never_prunes(self):
        result = self.run_backup(overrides={"TEST_REMOTE_SIZE": "18"})
        self.assertNotEqual(result.returncode, 0)
        self.assert_preserved()
        self.assertIn("size does not match", result.stderr)


if __name__ == "__main__":
    unittest.main()
