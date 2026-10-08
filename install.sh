#!/bin/sh
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HOME/.claude/agents"
for f in "$here"/claude/agents/*.md; do
  ln -sf "$f" "$HOME/.claude/agents/"
done
ln -sf "$here/claude/team.md" "$HOME/.claude/team.md"
touch "$HOME/.claude/CLAUDE.md"
grep -qxF '@~/.claude/team.md' "$HOME/.claude/CLAUDE.md" || echo '@~/.claude/team.md' >> "$HOME/.claude/CLAUDE.md"
echo "Linked $(ls "$here"/claude/agents/*.md | wc -l | tr -d ' ') agents and team.md into $HOME/.claude"
