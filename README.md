# SkillDock

[한국어 문서](README.ko.md)

SkillDock is a macOS menu-bar launcher for Claude Code skills and configured MCP
servers. It discovers available actions, infers their inputs, fills safe defaults,
and runs them with one click whenever no human-only value is required.

![SkillDock home](docs/images/01-home.png)

## Install

### Homebrew

```sh
brew tap dosuser/skilldock
brew install --cask skilldock
```

The app is ad-hoc signed and not notarized. The cask removes the quarantine
attribute after installation. Upgrade with `brew upgrade --cask skilldock` and
remove with `brew uninstall --cask skilldock` (`--zap` also removes settings).

### Build from source

```sh
./build.sh
open build/SkillDock.app
```

No Xcode project is required. `build.sh` compiles `Sources/**`, creates the app
bundle, and ad-hoc signs it.

## How it works

1. **Discover** skills from `~/.claude/skills`, `~/.agents/skills`, plugin caches,
   and `~/.claude/commands`; discover MCP servers from Claude settings.
2. **Infer inputs** from `SKILL.md`, argument hints, parameter tables, `$ARGUMENTS`,
   and command examples.
3. **Prefill** documented defaults and name-based defaults. A fully resolved card
   runs directly; unresolved human values open a small form.
4. **Run** `claude -p` headlessly and show `stream-json` progress in real time.

Dynamic values stay as tokens until execution, so a date never becomes stale:

| Token | Value at runtime |
|---|---|
| `{{today}}`, `{{yesterday}}`, `{{tomorrow}}` | Dates (`yyyy-MM-dd`) |
| `{{weekAgo}}`, `{{monthAgo}}` | 7 or 30 days ago |
| `{{thisMonth}}`, `{{lastMonth}}` | Months (`yyyy-MM`) |
| `{{now}}`, `{{year}}` | Current time or year |
| `{{home}}`, `{{desktop}}`, `{{downloads}}`, `{{documents}}`, `{{worklog}}` | Local paths |

MCP servers become cards too. SkillDock reads only server name, transport, and
host—never `headers` or `env` values—so API keys are not copied into cards.

## Features

- Global shortcuts using Carbon `RegisterEventHotKey`
- Live tool-call and text progress
- Results retained in the popover, macOS notifications, and `~/SkillDock/*.md`
- Card editing for name, color, shortcut, and run options
- Optional AI form inference when deterministic parsing is insufficient

![Run form](docs/images/02-run-form.png)

## Requirements

- macOS 14 or newer
- Swift 6.1+ via Command Line Tools
- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code):
  `npm i -g @anthropic-ai/claude-code`

SkillDock ignores the Linux ELF binary bundled inside the Claude desktop app;
install the native macOS Claude Code CLI instead.

## Development tools

| Command | Purpose |
|---|---|
| `tools/selfcheck.sh` | Verify discovery, inference, prefilling, token expansion, and prompt rendering without launching the app |
| `tools/shots.sh` | Capture the actual UI to `docs/images/` |
| `tools/preview.sh` | Fast `ImageRenderer` layout preview |

## Project layout

```text
Sources/
  App/        App entry point (menu-bar only)
  Models/     Cards, parameters, and configuration storage
  Discovery/  Skill and MCP discovery, inference, prefilling
  Runner/     Claude process execution, stream parsing, notifications
  UI/         Popover, library window, Markdown, hotkeys
```

Configuration is stored in `~/.config/skilldock/config.json` and survives app
reinstallation.

## License

MIT
