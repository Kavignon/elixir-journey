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
