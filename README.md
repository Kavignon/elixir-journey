# elixir-journey

My Claude Code setup for Elixir and Phoenix work, and the notes that come out of using it.

## What's here

- `claude/team.md`: how the lead agent and its helpers split the work: model routing, risk tiers, the task loop, and the evidence rules every agent follows.
- `claude/agents/`: six subagents. `scout`, `librarian`, `runner` and `porter` run on Haiku, `builder` runs on Sonnet in its own worktree, and `reviewer` runs on Opus with a fresh context.
- `claude/settings.example.json`: user-level settings. Merge by hand into `~/.claude/settings.json`.
- `templates/project-settings.json`: a starting `.claude/settings.json` for a project. Blocks the deploy CLI and reading `.env`, and asks before `git push`.
- `install.sh`: symlinks the agents and `team.md` into `~/.claude`, so an edit here applies to every project. Safe to run twice.

## Install

```sh
git clone git@github.com:Kavignon/elixir-journey.git ~/development/elixir-journey
~/development/elixir-journey/install.sh
```

Then merge `claude/settings.example.json` into `~/.claude/settings.json` and run `/agents` in a Claude Code session to check that all six agents show up.

## How it changes

Nothing here is designed up front. A rule or agent earns its place when a real project hits a failure the setup should have caught. Fix it here, and say in the commit which failure it prevents.

Current proving ground: `after_one_knee`, a bilingual wedding RSVP app in Phoenix 1.8.

## Claude and Codex contract

`AGENTS.md` points Codex to the shared engineering contract in `claude/team.md`. Agent roles and model routing remain Claude-specific. Approved agents may implement high-risk code in isolation; consequential host, database, permission, publication and deployment operations require explicit authority. Independent review challenges the specification, implementation and evidence. The PR template under `.github/` provides a guided review dossier.

The installer is unchanged: it symlinks `~/.claude/team.md` and six agents, then adds `@~/.claude/team.md` to the existing `~/.claude/CLAUDE.md`. It does not symlink that latter file. After installation, edits to linked guidance affect every project using it. Installation and global settings are separate opt-in operations; do not run the installer as part of verification. The repository includes no duplicate root `CLAUDE.md`.

## Verification templates

See [the adoption audit and command contract](templates/elixir/README.md). These are opt-in assets for Mix/Phoenix projects, including umbrella roots; this repository is not a Mix application. Hooks, agents and future CI use one `scripts/verify.sh` implementation. Fast checks formatting and compilation; full adds tests. Local evidence concerns working-tree inputs, including dirty and partially staged limitations, rather than proving HEAD. Test/build artifacts are expected; tracked-source rewrites are not.

Harness checks (Python 3, Git, POSIX shell; the real fixture suite also needs Elixir/Mix):

```sh
sh tests/harness_test.sh
sh tests/mix_fixture_test.sh
sh -n scripts/stack.sh
sh -n templates/elixir/scripts/verify.sh
sh -n templates/elixir/.githooks/pre-commit
sh -n tests/harness_test.sh
sh -n tests/mix_fixture_test.sh
git diff --check
```

Tests write disposable temporary fixtures and delete only those fixtures on exit. Docker commands are faked throughout the contract suite. The real Mix suite uses generated dependency-free projects and never connects to a database. No extra linters/scanners or CI workflow are installed.

## Optional Compose stack prototype

This is a small application lifecycle adapter, not a provisioning platform. SBX and Orca are deferred. It requires Python 3, Git and a local Unix-socket Docker context with Compose v2 supporting JSON config, service hashes and `up --wait`. Docker CLI 27.3.1 / Compose 2.30.3 provide the used flags; actual daemon behavior still needs a separately authorized live pilot.

```text
scripts/stack.sh --help
scripts/stack.sh doctor [--repo PATH]
scripts/stack.sh up [--repo PATH]
scripts/stack.sh status [--repo PATH]
scripts/stack.sh verify fast|full [--repo PATH]
scripts/stack.sh down [--repo PATH]
```

The default target is the current Git worktree. Copy and adapt [stack.example.json](templates/stack.example.json) to the target's `.elixir-journey/stack.json` only after target-specific approval. The v1 schema has exactly five fields: `version` (1), `compose_files` (nonempty relative paths inside the worktree), `app_service`, `app_workdir` (absolute container path), and `host_port` (1024–65535). It is JSON data, never sourced as shell commands. No secrets belong in the adapter.

The selected application's normalized Compose configuration must have a locally available image, enabled healthcheck and exactly one TCP publication on `127.0.0.1` matching `host_port`. It must have no `depends_on`, fixed `container_name`, privileged mode or `network_mode`. Network/volume names must be project-scoped and non-external, using default local/bridge drivers without driver options. `volumes_from` is refused. Explicit `pid`, `ipc`, `uts`, `cgroup`, `devices`, `device_cgroup_rules`, `gpus`, `cap_add`, `userns_mode`, `security_opt`, `runtime` and `use_api_socket` are unsupported, including restrictive or empty overrides. Device reservations at `deploy.resources.reservations.devices` are also refused; bind mounts must stay inside the worktree. Use explicitly reviewed Compose secrets for the agent's own credentials. Review all mounted files, startup commands, environment, secret references and database targets before adoption. The adapter cannot prove what application code does: startup must not provision or migrate databases, and app credentials must already be isolated. Other Compose services are never started by the wrapper.

Every Docker subprocess, including context inspection and container verification, receives only `PATH`, `HOME`, `DOCKER_CONFIG`, `DOCKER_CONTEXT`, `TMPDIR` and `XDG_RUNTIME_DIR` when present. Other host-shell variables, including tokens and `COMPOSE_*` overrides, are not forwarded. Application variables and credentials must use separately reviewed configuration. Compose always receives explicit files, project name, project directory and `--env-file /dev/null`. This suppresses automatic `.env` discovery, but an explicitly configured service `env_file` or secret can still be read by Compose: inspect those references during adoption. Resolved Compose output, container inspection and Docker errors are captured rather than dumped because they can contain secrets. Gate output remains visible and must itself avoid secrets.

Workspace identity combines canonical common-Git-directory/worktree paths with a 12-digit SHA-256 suffix. Branch switches preserve identity; different worktrees get separate identities. Moving a checkout changes identity and requires manual re-adoption; old resources are not discovered or deleted. Runtime lifecycle locks live in the repository's common Git directory, one per workspace. Interrupted locks are not force-cleared; inspect active work before removing a stale lock.

| Command | Behavior |
|---|---|
| `doctor` | Validate adapter, local endpoint, normalized Compose model, ownership, local image, config hash and available app port. Read-only; passing does not prove database connectivity. |
| `status` | Inspect this workspace's app only; never start it. |
| `up` | Start the named app only with `--no-deps --no-build --pull never --no-recreate --wait --wait-timeout 60`. Existing unhealthy or changed containers are refused. |
| `verify` | Require a running healthy owned app and run `sh scripts/verify.sh fast|full` at `app_workdir` with `compose exec -T`. |
| `down` | `compose stop --timeout 10` only for the named owned app; retain its container, networks, volumes and all databases. Repeated stop is harmless. |

Missing/invalid config exits 2; missing tools, daemon, image, locks, occupied ports or ownership conflicts exit 3; failed startup exits 4. Verification preserves the gate's nonzero exit status. Commands never pull/build images, start dependencies, migrate databases, delete resources, choose a different occupied port, stop its owner or perform global Docker actions. Failed startup may leave scoped resources for inspection; cleanup is not automatic. The lock serializes wrapper mutations, not outside Docker users; the daemon resolves any port-binding race. Do not change the selected Docker context while a command runs; context selection is not pinned across separate Docker invocations. Status/down still require a valid available adapter, and config repair/recreation is manual.

Accept only a separately reviewed, trusted Compose configuration, including its referenced files, providers and executable helpers. Compose may read host files through `env_file`, `secrets`, `configs`, `include` and `extends`; providers may execute host-side programs. Normalization occurs before this wrapper validates the model. Allowed runtime variables such as `HOME` and `DOCKER_CONFIG` still expose configuration paths to Compose and its trusted helpers. Configuration changes invalidate the review. These checks are not a comprehensive Compose security parser or a sandbox boundary for untrusted agents. Enforcing an approved configuration snapshot outside the agent-writable workspace is deferred.

There is no real Compose/AOK adapter bundled here: its local structure has not been inspected. This prototype is contract-tested with fake Docker; live lifecycle behavior remains unverified. Host-daemon Compose is not a security boundary against a hostile agent. Never expose host admin credentials or the Docker socket to an untrusted room.

## Inactive shared PostgreSQL scaffold and later pilot

[infrastructure/postgres/compose.yaml](infrastructure/postgres/compose.yaml) is inactive and requires `EJ_POSTGRES_IMAGE` (approved digest), `EJ_POSTGRES_DATA_TARGET` (directory appropriate to that image major), and `EJ_POSTGRES_ADMIN_PASSWORD_FILE` (protected host-only file). There are deliberately no defaults inferred from a client version or unknown AOK setup. Its externally managed volume is `elixir-journey-postgres-data`; proposed Compose project name is `elixir-journey-postgres`. It publishes only `127.0.0.1:55432`. App teardown never stops this independent service or deletes its data.

Before a live pilot, obtain the explicit app path and permission to inspect only development configuration. Inventory existing Docker resources and verify port availability. Present exact image digest/architecture, mount target, new resource names, protected secret paths, role/database SQL and probe commands for operational approval. Do not attach an existing unknown volume, reuse production credentials or migrate legacy data.

After that separate approval, a trusted host operator can:

1. Create a protected local credential directory (0700) and files (0600), outside repositories and agent mounts. Pull the approved image, explicitly create the new volume, and start only the named host PostgreSQL service. Never put credentials in command arguments, logs or source control.
2. Provision per-worktree dev/test databases and separate limited login roles. Derive names from the workspace identity, not branch alone. Keep database ownership with a trusted owner; grant each role only its database connection and application-schema privileges, including reviewed local schema migration needs. Grant no superuser, CREATEDB, CREATEROLE, replication, BYPASSRLS or sibling memberships. Revoke PUBLIC database access on new agent databases, grant the intended role explicitly, and install privileged extensions from the trusted host.
3. Approve any test-alias adaptation and local migrations separately. Supplying a precreated database does not make a Phoenix `ecto.create` alias safe or functional automatically. Verify both directions of cross-agent denial and dev/test separation using effective privileges, not names alone.
4. Configure DBeaver for `127.0.0.1:55432` with the intended limited role; verify only `current_database()` and `current_user()`. Do not browse guest records for connectivity tests.
5. Probe host TCP/authenticated SQL, then DNS/TCP/authenticated SQL from an approved disposable Docker Desktop container. `host.docker.internal` is a candidate endpoint, not proof that a localhost-only publication is reachable. Inspect failure before proposing any alternative networking. Do not widen binds/firewalls or enable host networking automatically. Native Linux host-gateway routing also does not inherently expose a loopback-only listener.
6. Prove one existing app remains healthy, each agent can use only its databases, and stopping an app leaves PostgreSQL and siblings healthy. Retain all data on cleanup. Host shutdown and any data deletion require explicit decisions.

SBX installation, microVM and nested-container TCP probes, network allowlists, Orca, cloud work, automated migrations and a general orchestrator are deferred. Shared PostgreSQL still shares availability and capacity; credentials isolate access, not resource exhaustion. Rollback stops only explicitly approved new services, restores any recorded local hook configuration, and retains volumes/databases. Never use prune or `down -v`.
