# Opt-in Elixir verification

This repository is not a Mix project. Copy `scripts/verify.sh` into the chosen project's `scripts/` directory only after target-specific authorization. Install it at a Mix root containing `mix.exs`; for umbrellas use the umbrella root. The script resolves its own installation root, regardless of the caller's working directory. Nested monorepo Mix roots can use the script directly; the provided hook assumes Mix is at the Git root.

## Adoption audit

Before executing the gate in a real project, inspect `mix.exs`, all relevant umbrella child aliases, `.formatter.exs`, formatter plugins, custom compilers, configuration and test helpers. Standard tasks can be overridden by aliases or execute custom code. Review at least `format`, `compile`, and `test`, including indirect tasks. Do not infer safety from a task called `precommit`. The script cannot statically prove arbitrary Elixir code harmless; copying it does not authorize provisioning or data changes.

Confirm dependencies and local toolchain are already available. Establish that compilation/plugins do not rewrite tracked source. Confirm the root formatter includes the intended umbrella children and HEEx files. Confirm test aliases and helpers target only the explicitly authorized disposable test database. Phoenix projects may create/migrate databases from their test alias; that requires separate authorization. Adapt that alias deliberately or use a reviewed project-specific gate; do not grant database-creation privileges merely to bypass this boundary.

## Canonical commands

```sh
scripts/verify.sh fast
scripts/verify.sh full
```

`fast` runs `MIX_ENV=dev mix format --check-formatted` and `MIX_ENV=dev mix compile --warnings-as-errors`. `full` runs fast and then `MIX_ENV=test mix test`. A failed command stops the gate and preserves its exit status. Usage failures exit 2; unavailable prerequisites exit 3; a detected tracked-input/HEAD change exits 1. No dependency fetching, formatting writes, migrations, optional scanners or asset setup are added by the gate itself. Project aliases, compilers and tests still have their audited effects.

Compilation and formatter plugins may write `_build` artifacts; tests may write caches, coverage files and their authorized test database. This is a source-checking contract, not a promise of zero filesystem or database effects. No linters or scanners are installed for v0.

The gate reports HEAD only as context. It verifies working-tree inputs, including potentially untracked files, and **does not verify the index or HEAD commit**. Staged/unstaged changes and partial staging are disclosed rather than stashed, staged or rewritten. Tracked differences against HEAD and HEAD identity are fingerprinted before/after checks; changes fail the run without restoring files. This detects net changes, not a write subsequently reverted, index-only changes, ignored/untracked input changes, or changes outside the installed root. Keep the candidate stable while checks run. This lightweight fingerprint is not an adversarial filesystem sandbox.

For commit evidence, run the gate against that exact clean revision in an isolated checkout with the required dependencies and authorized test environment. Record the checked SHA, toolchain, environment, commands and exit statuses. Do not relabel a prior working-tree run after committing.

## Optional pre-commit hook

After inspecting existing hooks, copy `.githooks/pre-commit` only if it will not overwrite an existing file. Before opting in, `git config --show-origin --get core.hooksPath` must report no existing effective setting. If one exists, stop and design an explicit integration; never overwrite it automatically. Also inspect existing `.git/hooks/pre-commit` behavior before replacing its execution path. Make both scripts executable.

Only after that target-specific approval:

```sh
git config --local core.hooksPath .githooks
```

The hook invokes the same `scripts/verify.sh fast` implementation and warns that it checks working-tree content, not the staged snapshot. It does not install itself, alter Git configuration, fetch dependencies or stash changes. Record the previous configuration for rollback. Future CI should call `scripts/verify.sh full` on the submitted revision, not duplicate its command list. No CI workflow is installed here.

## Harness proof

From the harness repository run `sh tests/harness_test.sh` and `sh tests/mix_fixture_test.sh`. They create disposable Git/Mix fixtures; no target project is adopted. The first uses fake Mix and Docker commands, including failure and unsafe-model controls. The second exercises actual formatting, compilation, tests and umbrella recursion with dependency-free generated projects. No Docker daemon or database is needed.
