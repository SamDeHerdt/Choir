# Choir

Every model you already pay for, in one macOS window — with the same projects,
prompts, skills and history behind all of them.

Made by Sam De Herdt for MakeWaves.

## What it does

- **One thread, any model.** Switch model between any two messages; the whole
  conversation, the project's files and the library go with you.
- **No API credits.** Claude runs through the signed-in `claude` CLI (your
  Claude subscription), ChatGPT through the signed-in `codex` CLI (your ChatGPT
  subscription), local models through Ollama. Pay-per-token API connections
  exist but are off by default and never seeded.
- **Projects.** Instructions, knowledge files (text, Markdown, code, CSV, JSON,
  PDF), attached library items and conversations — one container that every
  model reads.
- **Library.** Prompts, skills and knowhow written once. Import the skills you
  already have for Claude Code / Codex (`SKILL.md` folders) in one click.
- **Rooms.** Several models on one question: *parallel* (blind), *relay* (each
  reads the ones before it) or *debate* (relay plus a synthesis by a real model).
- **MCP bridge.** `Choir --mcp-server` serves the library, history and projects
  over MCP, so Claude Code or Codex can read them back and file new knowhow or
  projects. Settings › MCP bridge has the exact one-line setup for each.

## Build

```bash
CHOIR_ARCHES=arm64 bash build.sh          # current Mac only, optimised
CHOIR_FAST=1 CHOIR_ARCHES=arm64 bash build.sh   # debug loop, seconds instead of minutes
bash build.sh                              # universal
bash run-tests.sh                          # headless checks + one live round trip per CLI
```

Nothing watches the sources: rebuild and relaunch after every change.

## Where things live

- App data: `~/Library/Application Support/Choir/` — `conversations.json`,
  `projects.json`, `library.json`, `settings.json`. API keys are in the Keychain.
- CLI workspace: `~/Library/Application Support/Choir/workspace` — a neutral
  cwd so no repo's `CLAUDE.md` / `AGENTS.md` leaks into a chat.

## Honest limits

- A subscription is not an API. Claude Pro/Max and ChatGPT Plus/Pro work here
  only because their CLIs hold the login. Gemini works the same way through its
  CLI if installed — configure it under *Another CLI* with its own flags.
  Copilot has no usable local bridge today.
- Codex does not stream tokens; its answer appears whole.
- Claude **Fable** is metered separately by Anthropic; it is listed but marked.
