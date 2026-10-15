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
        container = {"Id": "container", "Config": {"Labels": {"com.docker.compose.config-hash": "a" * 64}}}
        responses = ["container", {"services": {"daily": {"build": "."}}}, "daily " + "b" * 64]
        with patch.object(deploy, "run", side_effect=responses) as run, \
             patch.object(deploy, "inspect_container", return_value=container), \
             patch.object(deploy, "compose_for", return_value=["docker-compose"]):
            with self.assertRaisesRegex(deploy.ReleaseError, "Compose configuration differs"):
                deploy.preflight(Path("/unused"))
            self.assertEqual(run.call_count, 3)

    def no_deps_fixture(self):
        live = {"Config": {"Labels": {"com.docker.compose.config-hash": "b" * 64,
                                       "com.docker.compose.depends_on": "",
                                       "com.docker.compose.version": "2.26.1"}}}
        compose = ["docker-compose", "--project-name", "deploy", "--project-directory", "/deploy",
                   "-f", "/deploy/docker-compose.yml", "-f", "/deploy/docker-compose.override.yml",
                   "--profile", "daily"]
        config = {"services": {"daily": {"depends_on": {"db": {"condition": "service_healthy"}},
                                          "environment": self.base, "ports": ["8787:8787"]},
                                "db": {"image": "postgres:16"}}}
        return live, compose, config

    def test_exact_hash_does_not_try_no_deps_alternative(self):
        live, compose, config = self.no_deps_fixture()
        with patch.object(deploy, "run", return_value="daily " + "b" * 64) as run:
            deploy.validate_service_hash(live, compose, config)
            run.assert_called_once_with(*compose, "config", "--hash", "daily")

    def test_no_deps_hash_removes_only_dependencies_after_proven_roundtrip(self):
        live, compose, config = self.no_deps_fixture()
        original = deploy.copy.deepcopy(config)
        responses = ["daily " + "a" * 64, "2.26.1", "daily " + "a" * 64, "daily " + "b" * 64]
        with patch.object(deploy, "run", side_effect=responses) as run:
            deploy.validate_service_hash(live, compose, config)
            first = deploy.json.loads(run.call_args_list[2].kwargs["input_text"])
            second = deploy.json.loads(run.call_args_list[3].kwargs["input_text"])
            self.assertEqual(first, original)
            self.assertEqual(first["services"]["db"], second["services"]["db"])
            expected = deploy.copy.deepcopy(original)
            expected["services"]["daily"].pop("depends_on")
            self.assertEqual(second, expected)
            self.assertEqual(config, original)
            self.assertNotIn("/deploy/docker-compose.yml", run.call_args_list[3].args)
            self.assertEqual(run.call_args_list[3].args[-5:], ("-f", "-", "config", "--hash", "daily"))
            self.assertNotIn(self.base["SESSION_SECRET"], " ".join(run.call_args_list[3].args))

    def test_no_deps_hash_never_accepts_unrelated_configuration_drift(self):
        live, compose, config = self.no_deps_fixture()
        responses = ["daily " + "a" * 64, "2.26.1", "daily " + "a" * 64, "daily " + "c" * 64]
        with patch.object(deploy, "run", side_effect=responses):
            with self.assertRaisesRegex(deploy.ReleaseError, "Compose configuration differs"):
                deploy.validate_service_hash(live, compose, config)

    def test_no_deps_hash_requires_lossless_full_configuration_roundtrip(self):
        live, compose, config = self.no_deps_fixture()
        responses = ["daily " + "a" * 64, "2.26.1", "daily " + "c" * 64]
        with patch.object(deploy, "run", side_effect=responses) as run:
            with self.assertRaisesRegex(deploy.ReleaseError, "unchanged Daily Compose model"):
                deploy.validate_service_hash(live, compose, config)
            self.assertEqual(run.call_count, 3)

    def test_no_deps_alternative_requires_empty_live_dependency_label_and_known_version(self):
        for changed in [{"com.docker.compose.depends_on": "db:service_started:false"},
                        {"com.docker.compose.depends_on": None}, {"com.docker.compose.version": "2.27.0"}]:
            live, compose, config = self.no_deps_fixture()
            live["Config"]["Labels"].update(changed)
            with patch.object(deploy, "run", return_value="daily " + "a" * 64) as run:
                with self.assertRaises(deploy.ReleaseError):
                    deploy.validate_service_hash(live, compose, config)
                self.assertEqual(run.call_count, 1)

    def test_no_deps_alternative_rejects_changed_installed_compose_version(self):
        live, compose, config = self.no_deps_fixture()
        with patch.object(deploy, "run", side_effect=["daily " + "a" * 64, "2.27.0"]) as run:
            with self.assertRaises(deploy.ReleaseError):
                deploy.validate_service_hash(live, compose, config)
            self.assertEqual(run.call_count, 2)

    def test_service_hash_rejects_missing_extra_or_malformed_results(self):
        for value in ["", "daily invalid", "other " + "a" * 64, "daily " + "a" * 64 + "\ndb " + "b" * 64]:
            with self.assertRaises(deploy.ReleaseError):
                deploy.service_hash(value)

    def test_rollback_revision_uses_deployment_metadata_without_image_fallback(self):
        with patch.object(deploy, "run", return_value={"sha": "a" * 40}) as run:
            self.assertEqual(deploy.deployed_revision({"Id": "container", "Image": "image"}),
                             {"sha": "a" * 40, "source": "deployment.json"})
            self.assertEqual(run.call_count, 1)

    def test_missing_metadata_uses_exact_running_image_revision(self):
        image = {"Id": "immutable-image", "Config": {"Labels": {"org.opencontainers.image.revision": "a" * 40}}}
        with patch.object(deploy, "run", side_effect=[{"missing": True}, [image]]) as run:
            self.assertEqual(deploy.deployed_revision({"Id": "container", "Image": "immutable-image"}),
                             {"sha": "a" * 40, "source": "image-revision-label"})
            self.assertEqual(run.call_args.args, ("docker", "image", "inspect", "immutable-image"))

    def test_invalid_metadata_never_falls_back_to_image_label(self):
        for metadata in ({}, {"sha": "main"}, {"sha": None}, {"missing": False}, None):
            with self.subTest(metadata=metadata), patch.object(deploy, "run", return_value=metadata) as run:
                with self.assertRaisesRegex(deploy.ReleaseError, "no exact commit"):
                    deploy.deployed_revision({"Id": "container", "Image": "image"})
                self.assertEqual(run.call_count, 1)

    def test_metadata_read_failure_never_falls_back_to_image_label(self):
        with patch.object(deploy, "run", side_effect=deploy.ReleaseError("read failed")) as run:
            with self.assertRaisesRegex(deploy.ReleaseError, "read failed"):
                deploy.deployed_revision({"Id": "container", "Image": "image"})
            self.assertEqual(run.call_count, 1)

    def test_image_revision_fallback_rejects_missing_invalid_or_mismatched_identity(self):
        for image in [
                {"Id": "image", "Config": {"Labels": None}},
                {"Id": "image", "Config": {"Labels": {"org.opencontainers.image.revision": "main"}}},
                {"Id": "image", "Config": {"Labels": {"org.opencontainers.image.revision": 123}}},
                {"Id": "different-image", "Config": {"Labels": {"org.opencontainers.image.revision": "a" * 40}}}]:
            with self.subTest(image=image), patch.object(deploy, "run", side_effect=[{"missing": True}, [image]]):
                with self.assertRaises(deploy.ReleaseError):
                    deploy.deployed_revision({"Id": "container", "Image": "image"})

    def test_default_invocation_only_reads_preflight(self):
        with patch("sys.argv", ["deploy-service.py"]), \
             patch.object(deploy, "preflight", return_value=({"Id": "container", "Image": "image"}, [], {})), \
             patch.object(deploy, "run") as run, contextlib.redirect_stdout(io.StringIO()):
            deploy.main()
            run.assert_not_called()

    def test_candidate_override_allows_only_daily_image_change(self):
        original = {"services": {"daily": {"image": "sha256:" + "a" * 64, "environment": self.base,
                                          "cap_drop": ["ALL"], "networks": {"private": {}}},
                                 "db": {"image": "postgres:16"}}, "networks": {"private": {}}}
        candidate = deploy.copy.deepcopy(original)
        candidate["services"]["daily"]["image"] = "ritual-cue-release:" + "b" * 40
        with patch.object(deploy, "run", side_effect=[original, candidate]):
            deploy.validate_image_only_override(["original"], ["candidate"], candidate["services"]["daily"]["image"])
        self.assertEqual(original["services"]["daily"]["image"], "sha256:" + "a" * 64)
        changes = [lambda c: c["services"]["daily"]["environment"].update(SESSION_SECRET="unexpected-secret"),
                   lambda c: c["services"]["daily"].update(cap_drop=[]),
                   lambda c: c["services"]["daily"].update(networks={}),
                   lambda c: c["services"]["db"].update(image="postgres:17")]
        for change in changes:
            altered = deploy.copy.deepcopy(candidate)
            change(altered)
            with patch.object(deploy, "run", side_effect=[original, altered]):
                with self.assertRaisesRegex(deploy.ReleaseError, "changes more than the Daily image") as error:
                    deploy.validate_image_only_override(["original"], ["candidate"], candidate["services"]["daily"]["image"])
                self.assertNotIn("unexpected-secret", str(error.exception))

    def test_image_override_refuses_to_overwrite_existing_release_file(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "existing.json"
            path.write_text("preserve existing overlay")
            with self.assertRaises(FileExistsError):
                deploy.write_image_override(path, "candidate", exclusive=True)
            self.assertEqual(path.read_text(), "preserve existing overlay")

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
        directory = Path(temp).resolve()
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
            overlay = directory / ("daily-image-" + "b" * 40 + ".json")
            candidate_compose = compose + ["-f", str(overlay)]
            built_image = "sha256:" + "c" * 64

            def response(*args, **kwargs):
                if args[:3] == ("docker", "exec", "old-container"):
                    return {"sha": "a" * 40}
                if args[:3] == ("docker", "image", "inspect"):
                    return [{"Id": built_image}]
                if args[-3:] == ("config", "--format", "json"):
                    image = deploy.json.loads(overlay.read_text())["services"]["daily"]["image"] if str(overlay) in args else "deploy-daily"
                    return {"services": {"daily": {"image": image, "environment": self.base}}}
                return ""

            with patch("sys.argv", [str(script), "--deploy-directory", str(directory), "--release", "b" * 40]), \
                 patch.object(deploy, "__file__", str(script)), \
                 patch.object(deploy, "preflight", side_effect=[(previous, compose, {}), (previous, compose, {}), (current, compose, {})]), \
                 patch.object(deploy, "run", side_effect=response) as run, \
                 patch.object(deploy, "verify") as verify, contextlib.redirect_stdout(io.StringIO()):
                deploy.main()
                commands = [call.args for call in run.call_args_list]
                self.assertIn(tuple(candidate_compose + ["build", "daily"]), commands)
                self.assertIn(tuple(candidate_compose + ["up", "-d", "--no-deps", "--no-build", "daily"]), commands)
                self.assertIn(("docker", "image", "tag", "old-image", "ritual-cue-rollback:" + "b" * 40), commands)
                self.assertEqual([c for c in commands if "up" in c], [tuple(candidate_compose + ["up", "-d", "--no-deps", "--no-build", "daily"])])
                self.assertEqual(deploy.json.loads(overlay.read_text()), {"services": {"daily": {"image": built_image}}})
                verify.assert_called_once_with("new-container", "b" * 40)
                record = deploy.json.loads((directory / "release-records" / ("daily-" + "b" * 40 + ".json")).read_text())
                self.assertEqual(record["previousSha"], "a" * 40)
                self.assertEqual(record["previousShaSource"], "deployment.json")
                self.assertEqual(record["compose"], compose)
                self.assertEqual(record["candidateCompose"], candidate_compose)
                self.assertEqual(record["status"], "healthy")

    def test_candidate_drift_after_build_stops_before_container_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            directory, script, previous, _, compose = self.release_fixture(temp)
            with patch("sys.argv", [str(script), "--deploy-directory", str(directory), "--release", "b" * 40]), \
                 patch.object(deploy, "__file__", str(script)), \
                 patch.object(deploy, "preflight", return_value=(previous, compose, {})), \
                 patch.object(deploy, "deployed_revision", return_value={"sha": "a" * 40, "source": "image-revision-label"}), \
                 patch.object(deploy, "validate_image_only_override", side_effect=[None, deploy.ReleaseError("candidate drift")]), \
                 patch.object(deploy, "run", side_effect=["", "", [{"Id": "sha256:" + "c" * 64}]]) as run, \
                 contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaisesRegex(deploy.ReleaseError, "candidate drift"):
                    deploy.main()
                self.assertFalse(any("up" in call.args for call in run.call_args_list))
                record = deploy.json.loads((directory / "release-records" / ("daily-" + "b" * 40 + ".json")).read_text())
                self.assertEqual(record["status"], "prepared")
                self.assertEqual(record["previousImage"], "old-image")

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
