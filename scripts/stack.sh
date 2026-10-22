#!/bin/sh
# The optional stack adapter needs Python 3; no third-party packages.
set -eu
command -v python3 >/dev/null 2>&1 || { echo 'BLOCKED: stack requires python3' >&2; exit 3; }
exec python3 - "$@" <<'PYTHON'
import atexit
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import signal
import subprocess
import sys

USAGE = "stack.sh --help | {doctor|up|status|down} [--repo PATH] | verify {fast|full} [--repo PATH]"

# Only Docker/runtime configuration is inherited. Application credentials must
# use separately reviewed configuration, never ambient host-shell variables.
DOCKER_ENV = {
    key: os.environ[key]
    for key in ("PATH", "HOME", "DOCKER_CONFIG", "DOCKER_CONTEXT", "TMPDIR", "XDG_RUNTIME_DIR")
    if key in os.environ
}

class Blocked(Exception):
    def __init__(self, message, code=3):
        self.code = code
        super().__init__(message)

def run(args, cwd=None):
    try:
        process = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, check=False,
                                 env=DOCKER_ENV if args[0] == "docker" else None)
    except FileNotFoundError:
        raise Blocked("missing executable: " + args[0])
    if process.returncode:
        # Docker stderr/config can contain interpolated credentials. Do not dump it.
        raise Blocked("command failed (output withheld): " + args[0] +
                      " exit=" + str(process.returncode))
    return process.stdout

def main():
    args = sys.argv[1:]
    if args == ["--help"]:
        print(USAGE)
        return
    if not args or args[0] not in ("doctor", "up", "status", "verify", "down"):
        raise Blocked(USAGE, 2)
    action = args.pop(0)
    mode = None
    if action == "verify":
        if not args or args[0] not in ("fast", "full"):
            raise Blocked(USAGE, 2)
        mode = args.pop(0)
    if args and (len(args) != 2 or args[0] != "--repo"):
        raise Blocked(USAGE, 2)
    requested = Path(args[1] if args else os.getcwd()).resolve()
    repo = Path(run(["git", "-C", str(requested), "rev-parse", "--show-toplevel"]).strip()).resolve()
    config_path = repo / ".elixir-journey/stack.json"
    if not config_path.is_file():
        raise Blocked("missing .elixir-journey/stack.json; adopt the reviewed example first", 2)
    config = json.loads(config_path.read_text())
    required = {"version", "compose_files", "app_service", "app_workdir", "host_port"}
    if set(config) != required or config["version"] != 1:
        raise Blocked("adapter must contain exactly the documented v1 fields", 2)
    service, workdir, port = config["app_service"], config["app_workdir"], config["host_port"]
    if not isinstance(service, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]*", service):
        raise Blocked("invalid app_service", 2)
    if not isinstance(workdir, str) or not workdir.startswith("/"):
        raise Blocked("app_workdir must be an absolute container path", 2)
    if type(port) is not int or not 1024 <= port <= 65535:
        raise Blocked("host_port must be an unprivileged TCP port", 2)
    files = config["compose_files"]
    if not isinstance(files, list) or not files or not all(isinstance(f, str) for f in files):
        raise Blocked("compose_files must be a nonempty list of relative paths", 2)
    paths = []
    for entry in files:
        path = (repo / entry).resolve()
        if Path(entry).is_absolute() or repo not in path.parents or not path.is_file():
            raise Blocked("Compose files must exist inside this worktree", 2)
        paths.append(path)
    common = Path(run(["git", "-C", str(repo), "rev-parse", "--git-common-dir"]).strip())
    if not common.is_absolute():
        common = repo / common
    common = common.resolve()
    token = hashlib.sha256((str(common) + "\0" + str(repo)).encode()).hexdigest()[:12]
    slug = re.sub(r"[^a-z0-9]", "-", common.parent.name.lower()).strip("-")[:24] or "app"
    project = "ej-" + slug + "-" + token
    if os.environ.get("DOCKER_HOST"):
        raise Blocked("DOCKER_HOST override is unsupported; select a local Unix-socket context")
    endpoint = run(["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"] ).strip()
    if not endpoint.startswith("unix://"):
        raise Blocked("only a local Unix-socket Docker context is supported")
    # Explicit files and an empty env file suppress automatic .env discovery.
    compose = ["docker", "compose", "--project-name", project, "--project-directory", str(repo),
               "--env-file", os.devnull]
    for path in paths:
        compose += ["-f", str(path)]
    model = json.loads(run(compose + ["config", "--format", "json"], repo))
    services = model.get("services", {})
    if service not in services:
        raise Blocked("configured application service is absent", 2)
    app = services[service]
    unsupported = (
        "pid", "ipc", "uts", "cgroup", "devices", "device_cgroup_rules", "gpus",
        "cap_add", "userns_mode", "security_opt", "runtime", "use_api_socket",
    )
    requested = [key for key in unsupported if key in app]
    resources = (app.get("deploy") or {}).get("resources") or {}
    reservations = resources.get("reservations") or {}
    if "devices" in reservations:
        requested.append("deploy.resources.reservations.devices")
    if requested:
        raise Blocked("unsupported namespace/device/privilege options: " + ", ".join(requested), 2)
    if app.get("depends_on") or app.get("container_name") or app.get("network_mode") or app.get("privileged") or app.get("volumes_from"):
        raise Blocked("app must have no dependencies, fixed container name, network_mode, privileged mode or volumes_from", 2)
    if not app.get("image") or app.get("healthcheck", {}).get("disable", False) or not app.get("healthcheck", {}).get("test") or app["healthcheck"]["test"] == ["NONE"]:
        raise Blocked("app requires a local image and enabled healthcheck", 2)
    for section in ("volumes", "networks"):
        for name, spec in model.get(section, {}).items():
            if spec.get("external") or spec.get("name", project + "_" + name) != project + "_" + name:
                raise Blocked("shared or fixed-name " + section + " are unsupported", 2)
            default_driver = "local" if section == "volumes" else "bridge"
            if spec.get("driver") not in (None, default_driver) or spec.get("driver_opts"):
                raise Blocked("custom drivers/options for " + section + " are unsupported", 2)
    for mount in app.get("volumes", []):
        if mount.get("type") == "bind":
            source = Path(mount.get("source", "")).resolve()
            if source != repo and repo not in source.parents:
                raise Blocked("bind mounts outside this worktree are unsupported; use reviewed Compose secrets", 2)
        if mount.get("type") not in ("bind", "volume", "tmpfs"):
            raise Blocked("unsupported mount type", 2)
    ports = app.get("ports", [])
    if len(ports) != 1 or str(ports[0].get("published")) != str(port) or ports[0].get("host_ip") != "127.0.0.1" or ports[0].get("protocol", "tcp") != "tcp":
        raise Blocked("app must publish exactly its configured TCP port on 127.0.0.1", 2)
    if action in ("up", "down", "verify"):
        lock = common / ("ej-" + token + ".lock")
        try:
            lock.mkdir()
        except FileExistsError:
            raise Blocked("workspace is locked; inspect any active command before removing a stale lock")
        atexit.register(lock.rmdir)
        for sig in (signal.SIGINT, signal.SIGTERM):
            signal.signal(sig, lambda number, frame: sys.exit(128 + number))
    ids = run(compose + ["ps", "--all", "--quiet", service], repo).split()
    if len(ids) > 1:
        raise Blocked("multiple app containers are unsupported")
    container = None
    if ids:
        container = json.loads(run(["docker", "inspect", ids[0]]))[0]
        labels = container.get("Config", {}).get("Labels", {})
        if labels.get("com.docker.compose.project") != project or labels.get("com.docker.compose.service") != service:
            raise Blocked("container ownership mismatch")
        if Path(labels.get("com.docker.compose.project.working_dir", "")).resolve() != repo:
            raise Blocked("container belongs to another worktree")
    print("workspace=" + project)
    if action == "status":
        print("app=" + (container["State"]["Status"] if container else "absent"))
        return
    if action == "down":
        if container and container["State"]["Status"] != "exited":
            run(compose + ["stop", "--timeout", "10", service], repo)
        print("app stopped; containers, volumes and databases retained")
        return
    run(["docker", "image", "inspect", app["image"]])
    expected_hash = run(compose + ["config", "--hash", service], repo).strip().split()[-1]
    if container and container["Config"]["Labels"].get("com.docker.compose.config-hash") != expected_hash:
        raise Blocked("app configuration changed; explicit recreation is outside this prototype")
    if not container or container["State"]["Status"] != "running":
        with socket.socket() as probe:
            try:
                probe.bind(("127.0.0.1", port))
            except OSError:
                raise Blocked("application port is occupied; no process will be stopped")
    if container and container["State"]["Status"] == "running" and container["State"].get("Health", {}).get("Status") != "healthy":
        raise Blocked("existing app is unhealthy; no automatic recreation")
    if action == "doctor":
        print("doctor passed; startup commands, aliases and database targets still require adoption review")
    elif action == "up":
        try:
            run(compose + ["up", "--no-deps", "--no-build", "--pull", "never", "--no-recreate",
                           "--wait", "--wait-timeout", "60", service], repo)
        except Blocked:
            raise Blocked("app startup failed; inspect this workspace; no automatic cleanup performed", 4)
        print("app running/healthy; no database provisioning performed")
    else:
        if not container or container["State"]["Status"] != "running":
            raise Blocked("verify requires a running owned app")
        # Gate output is intentionally visible; the audited gate must not print secrets.
        result = subprocess.run(compose + ["exec", "-T", "--workdir", workdir, service,
                                           "sh", "scripts/verify.sh", mode], cwd=repo, env=DOCKER_ENV)
        raise SystemExit(result.returncode)

try:
    main()
except Blocked as exc:
    print("BLOCKED: " + str(exc), file=sys.stderr)
    raise SystemExit(exc.code)
except (ValueError, TypeError, KeyError, IndexError, OSError):
    print("BLOCKED: invalid adapter, Compose response or inaccessible input (details withheld)", file=sys.stderr)
    raise SystemExit(2)
PYTHON
