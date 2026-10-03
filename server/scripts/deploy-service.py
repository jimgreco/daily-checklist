#!/usr/bin/env python3
"""Validate or replace only the existing Daily service without changing runtime config."""

import argparse
import fcntl
import json
from pathlib import Path
import re
import subprocess
import sys
import time


class ReleaseError(Exception):
    pass


def run(*args, json_output=False):
    # Compose config and inspect can contain credentials. Keep all output in memory
    # and never include subprocess output in an exception or release record.
    result = subprocess.run(args, text=True, capture_output=True)
    if result.returncode:
        raise ReleaseError(f"Command failed: {args[0]} {args[1] if len(args) > 1 else ''}; output withheld")
    try:
        return json.loads(result.stdout) if json_output else result.stdout.strip()
    except ValueError as error:
        raise ReleaseError("Command returned invalid JSON; output withheld") from error


def environment(values):
    return dict(value.split("=", 1) for value in values or [] if "=" in value)


def validate_environment(live, configured, image_defaults):
    resolved = dict(image_defaults)
    resolved.update({key: str(value) if value is not None else None for key, value in configured.items()})
    if live != resolved:
        raise ReleaseError("Effective Daily environment differs from the running container; reconcile before release")
    secret = live.get("SESSION_SECRET", "")
    if len(secret.strip()) < 32 or secret == "daily-local-development-secret-change-me":
        raise ReleaseError("Existing Daily signing secret fails the production startup requirement")
    if live.get("NODE_ENV") != "production" or not live.get("DATABASE_URL", "").startswith(("postgres://", "postgresql://")):
        raise ReleaseError("Existing Daily production/database configuration is incomplete")


def inspect_container(container_id):
    return run("docker", "inspect", container_id, json_output=True)[0]


def compose_for(container, directory):
    labels = container["Config"].get("Labels") or {}
    if labels.get("com.docker.compose.project") != "deploy" or labels.get("com.docker.compose.service") != "daily":
        raise ReleaseError("Container is not the existing deploy/daily service")
    if Path(labels.get("com.docker.compose.project.working_dir", "")).resolve() != directory:
        raise ReleaseError("Running Daily Compose working directory differs from the requested directory")
    files = labels.get("com.docker.compose.project.config_files", "").split(",")
    if not files or any(not name for name in files):
        raise ReleaseError("Running Daily container has no recorded Compose files")
    command = ["docker-compose", "--project-name", "deploy", "--project-directory", str(directory)]
    for name in files:
        path = Path(name).resolve()
        if path.parent != directory or not path.is_file():
            raise ReleaseError("Recorded Daily Compose file is missing or outside the deployment directory")
        command.extend(["-f", str(path)])
    return command + ["--profile", "daily"]


def preflight(directory, expected_id=None):
    ids = run("docker", "ps", "--filter", "label=com.docker.compose.project=deploy",
              "--filter", "label=com.docker.compose.service=daily", "--format", "{{.ID}}").splitlines()
    if len(ids) != 1:
        raise ReleaseError("Expected exactly one running deploy/daily container")
    live = inspect_container(ids[0])
    if expected_id and live["Id"] != expected_id:
        raise ReleaseError("Running Daily container changed during release; stop and reconcile")
    compose = compose_for(live, directory)
    config = run(*compose, "config", "--format", "json", json_output=True)
    service = config.get("services", {}).get("daily", {})
    digest = run(*compose, "config", "--hash", "daily").split()
    if len(digest) != 2 or digest[0] != "daily" or digest[1] != live["Config"]["Labels"].get("com.docker.compose.config-hash"):
        raise ReleaseError("Effective Daily Compose configuration differs from the running container")
    build = service.get("build") or {}
    if not isinstance(build, dict) or Path(build.get("context", "")).resolve() != Path(__file__).resolve().parents[1]:
        raise ReleaseError("Daily build context differs from the transferred server directory")
    image = run("docker", "image", "inspect", live["Image"], json_output=True)[0]
    validate_environment(environment(live["Config"].get("Env")), service.get("environment", {}),
                         environment(image["Config"].get("Env")))
    return live, compose, service


def verify(container_id, sha):
    # Public health is read-only. Do not invoke the synthetic monitor/sync writer.
    script = ('const fs=require("node:fs"); const d=JSON.parse(fs.readFileSync("/app/src/deployment.json","utf8"));'
              'if(d.buildHash!==process.argv[1])process.exit(1);'
              'fetch("http://127.0.0.1:8787/health").then(async r=>{'
              'const b=await r.json();process.exit(r.ok&&b.ok===true?0:1)}).catch(()=>process.exit(1));')
    run("docker", "exec", container_id, "node", "-e", script, sha)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deploy-directory", type=Path, default=Path.home() / "deploy")
    parser.add_argument("--release", help="Exact 40-character commit SHA; omit for read-only preflight")
    args = parser.parse_args()
    directory = args.deploy_directory.resolve()
    if args.release and not re.fullmatch(r"[0-9a-f]{40}", args.release):
        raise ReleaseError("Release requires an exact lowercase 40-character Git SHA")
    if not args.release:
        live, _, _ = preflight(directory)
        print(json.dumps({"preflight": "passed", "container": live["Id"], "image": live["Image"]}))
        return
    with (directory / ".app-release.lock").open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        live, compose, _ = preflight(directory)
        metadata = Path(__file__).resolve().parents[1] / "src" / "deployment.json"
        if json.loads(metadata.read_text()).get("buildHash") != args.release:
            raise ReleaseError("Transferred deployment metadata does not match the requested commit")
        rollback = f"ritual-cue-rollback:{args.release}"
        record_dir = directory / "release-records"
        record_dir.mkdir(exist_ok=True)
        record = record_dir / f"daily-{args.release}.json"
        if record.exists():
            raise ReleaseError("Release record already exists; inspect it before retrying")
        previous_sha = run("docker", "exec", live["Id"], "node", "-p",
                           'require("/app/src/deployment.json").buildHash')
        if not re.fullmatch(r"[0-9a-f]{40}", previous_sha):
            raise ReleaseError("Existing Daily deployment metadata has no exact commit; establish recovery evidence first")
        run("docker", "image", "tag", live["Image"], rollback)
        recovery = {"sha": args.release, "previousContainer": live["Id"], "previousImage": live["Image"],
                    "previousImageName": live["Config"]["Image"], "previousSha": previous_sha, "rollbackTag": rollback,
                    "compose": compose, "status": "prepared"}
        record.write_text(json.dumps(recovery, indent=2) + "\n")
        print(f"Rollback image retained: {rollback}", flush=True)
        run(*compose, "build", "daily")
        preflight(directory, expected_id=live["Id"])
        run(*compose, "up", "-d", "--no-deps", "--no-build", "daily")
        recovery["status"] = "replaced-awaiting-health"
        record.write_text(json.dumps(recovery, indent=2) + "\n")
        for _ in range(60):
            try:
                current, _, _ = preflight(directory)
                verify(current["Id"], args.release)
                recovery.update(status="healthy", container=current["Id"], image=current["Image"])
                record.write_text(json.dumps(recovery, indent=2) + "\n")
                print(json.dumps({"status": "healthy", "sha": args.release, "container": current["Id"],
                                  "image": current["Image"], "recoveryRecord": str(record)}))
                return
            except ReleaseError:
                time.sleep(2)
        raise ReleaseError(f"Daily did not verify; retain rollback image and use recovery record {record}")


if __name__ == "__main__":
    try:
        main()
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        # Unrecognized exceptions can include command input; never dump the config.
        print(str(error) if isinstance(error, ReleaseError) else "Daily deployment failed; inspect the non-secret release record", file=sys.stderr)
        sys.exit(1)
