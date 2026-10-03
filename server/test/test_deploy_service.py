import importlib.util
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("daily_deploy", Path(__file__).parents[1] / "scripts" / "deploy-service.py")
deploy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(deploy)


class DeploySafetyTests(unittest.TestCase):
    def setUp(self):
        self.base = {"NODE_ENV": "production", "SESSION_SECRET": "synthetic-test-only-secret-32-characters",
                     "DATABASE_URL": "postgresql://synthetic:placeholder@db/daily_checklist"}
        self.defaults = {"PATH": "/usr/local/bin", "NODE_ENV": "production"}

    def test_identical_effective_environment_passes_without_printing_values(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            deploy.validate_environment(self.defaults | self.base, self.base, self.defaults)
        self.assertEqual(output.getvalue(), "")

    def test_changed_and_removed_runtime_values_fail_without_disclosure(self):
        for config in [self.base | {"SESSION_SECRET": "different-private-value"},
                       {key: value for key, value in self.base.items() if key != "SESSION_SECRET"}]:
            with self.assertRaises(deploy.ReleaseError) as error:
                deploy.validate_environment(self.defaults | self.base, config, self.defaults)
            self.assertNotIn(self.base["SESSION_SECRET"], str(error.exception))
            self.assertNotIn(self.base["DATABASE_URL"], str(error.exception))

    def test_unsafe_existing_secret_fails_closed(self):
        for secret in ["", " " * 40, "short", "daily-local-development-secret-change-me"]:
            config = self.base | {"SESSION_SECRET": secret}
            with self.assertRaises(deploy.ReleaseError):
                deploy.validate_environment(self.defaults | config, config, self.defaults)

    def test_inherited_override_cannot_silently_disappear(self):
        live = self.defaults | self.base | {"PATH": "/custom/bin"}
        with self.assertRaises(deploy.ReleaseError):
            deploy.validate_environment(live, self.base, self.defaults)

    def test_preflight_refuses_changed_compose_hash(self):
        container = {"Id": "container", "Config": {"Labels": {"com.docker.compose.config-hash": "running"}}}
        responses = ["container", {"services": {"daily": {"build": "."}}}, "daily changed"]
        with patch.object(deploy, "run", side_effect=responses) as run, \
             patch.object(deploy, "inspect_container", return_value=container), \
             patch.object(deploy, "compose_for", return_value=["docker-compose"]):
            with self.assertRaisesRegex(deploy.ReleaseError, "Compose configuration differs"):
                deploy.preflight(Path("/unused"))
            self.assertEqual(run.call_count, 3)

    def test_default_invocation_only_reads_preflight(self):
        with patch("sys.argv", ["deploy-service.py"]), \
             patch.object(deploy, "preflight", return_value=({"Id": "container", "Image": "image"}, [], {})), \
             patch.object(deploy, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            deploy.main()
            run.assert_not_called()

    def test_invalid_sha_fails_before_docker_access(self):
        with patch("sys.argv", ["deploy-service.py", "--release", "main; unexpected"]), \
             patch.object(deploy, "run") as run:
            with self.assertRaises(deploy.ReleaseError):
                deploy.main()
            run.assert_not_called()

    def test_compose_files_must_be_existing_recorded_files_in_deploy_directory(self):
        with tempfile.TemporaryDirectory() as temp:
            directory = Path(temp).resolve()
            config = directory / "docker-compose.yml"
            config.write_text("services: {}")
            labels = {"com.docker.compose.project": "deploy", "com.docker.compose.service": "daily",
                      "com.docker.compose.project.working_dir": str(directory),
                      "com.docker.compose.project.config_files": str(config)}
            command = deploy.compose_for({"Config": {"Labels": labels}}, directory)
            self.assertEqual(command[-2:], ["--profile", "daily"])
            labels["com.docker.compose.project.config_files"] = "/tmp/unrelated-compose.yml"
            with self.assertRaises(deploy.ReleaseError):
                deploy.compose_for({"Config": {"Labels": labels}}, directory)

    def release_fixture(self, temp):
        directory = Path(temp)
        scripts = directory / "server" / "scripts"
        scripts.mkdir(parents=True)
        metadata = directory / "server" / "src" / "deployment.json"
        metadata.parent.mkdir()
        metadata.write_text('{"buildHash":"' + "b" * 40 + '"}')
        previous = {"Id": "old-container", "Image": "old-image", "Config": {"Image": "deploy-daily"}}
        current = {"Id": "new-container", "Image": "new-image"}
        compose = ["docker-compose", "--project-name", "deploy", "--profile", "daily"]
        return directory, scripts / "deploy-service.py", previous, current, compose

    def test_release_retains_recovery_and_only_replaces_daily(self):
        with tempfile.TemporaryDirectory() as temp:
            directory, script, previous, current, compose = self.release_fixture(temp)
            with patch("sys.argv", [str(script), "--deploy-directory", str(directory), "--release", "b" * 40]), \
                 patch.object(deploy, "__file__", str(script)), \
                 patch.object(deploy, "preflight", side_effect=[(previous, compose, {}), (previous, compose, {}), (current, compose, {})]), \
                 patch.object(deploy, "run", return_value="a" * 40) as run, \
                 patch.object(deploy, "verify") as verify, contextlib.redirect_stdout(io.StringIO()):
                deploy.main()
                commands = [call.args for call in run.call_args_list]
                self.assertIn(tuple(compose + ["build", "daily"]), commands)
                self.assertIn(tuple(compose + ["up", "-d", "--no-deps", "--no-build", "daily"]), commands)
                self.assertEqual(len(commands), 4)
                self.assertEqual(commands[1], ("docker", "image", "tag", "old-image", "ritual-cue-rollback:" + "b" * 40))
                verify.assert_called_once_with("new-container", "b" * 40)
                record = deploy.json.loads((directory / "release-records" / ("daily-" + "b" * 40 + ".json")).read_text())
                self.assertEqual(record["previousSha"], "a" * 40)
                self.assertEqual(record["status"], "healthy")

    def test_existing_record_blocks_retry_before_retagging_rollback(self):
        with tempfile.TemporaryDirectory() as temp:
            directory, script, previous, _, compose = self.release_fixture(temp)
            records = directory / "release-records"
            records.mkdir()
            (records / ("daily-" + "b" * 40 + ".json")).write_text("{}")
            with patch("sys.argv", [str(script), "--deploy-directory", str(directory), "--release", "b" * 40]), \
                 patch.object(deploy, "__file__", str(script)), \
                 patch.object(deploy, "preflight", return_value=(previous, compose, {})), \
                 patch.object(deploy, "run") as run:
                with self.assertRaisesRegex(deploy.ReleaseError, "record already exists"):
                    deploy.main()
                run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
