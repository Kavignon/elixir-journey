# Elixir Journey working contract

Read `claude/team.md` before planning or changing this repository. Its engineering contract applies across tools; Claude-specific agent commands and model routing apply only where supported. Applicable project instructions and explicit user authorization define scope; tool permissions still apply.

This repository is a harness, not a Mix app. Elixir verification assets under `templates/` are opt-in for other projects. Preserve the installer and settings unless their modification is authorized. Installing or editing globally linked guidance has cross-project effects; do not run the installer implicitly.

Obtain approval for consequential design decisions, then work autonomously within the approved slice. Approved high-risk code may be implemented in isolation; consequential host, database, permission, publication and deployment operations require explicit authorization. Require independent review for high-risk implementations.

Use risk-proportional proof, challenge author-written tests, and report exact executed evidence and gaps. Working-tree verification does not verify HEAD or a partially staged snapshot.

Repository checks: `sh tests/harness_test.sh`, `sh tests/mix_fixture_test.sh`, shell syntax checks and `git diff --check`. The first suite uses fake Docker commands; the second creates disposable Mix projects and build artifacts. Never run real Docker lifecycle checks without separate authorization.
