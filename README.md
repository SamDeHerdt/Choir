# Choir

**One thread for every AI model you already pay for.** Ask Claude, then hand the same conversation to ChatGPT, then to a local model — the history, the project files and your library of prompts and skills come along. Put several models in a *room* and let them answer side by side, build on the one you prefer, or debate.

Choir is a native Mac app. It spends **no API credits**: it talks to the command-line tools you are already signed in to (Claude Code, Codex) and to local models through Ollama.

---

## Setting up (no technical knowledge needed)

You need a Mac with macOS 14 or newer. Plan on 15 minutes.

### 1. Install Choir

- If you were given a `Choir.dmg`: open it, drag **Choir** to **Applications**.
- The first time, macOS may say the app is from an unidentified developer. **Control-click Choir → Open → Open.** Only needed once.

### 2. Connect the AIs you pay for

Choir uses each provider's own free command-line tool, signed in with your normal account. Open **Terminal** (press ⌘ Space, type *Terminal*, Return) and paste one line at a time.

**Claude (Claude Pro / Max)**

```bash
curl -fsSL https://claude.ai/install.sh | bash
```
then
```bash
claude login
```
A browser window opens — sign in with your Claude account. Done.

**ChatGPT (Plus / Pro / Team)**

```bash
npm install -g @openai/codex
```
(if it says `npm` is missing, first install Node from https://nodejs.org, then repeat) then
```bash
codex login
```
Sign in with your ChatGPT account in the browser that opens.

**Local models (free, works offline, optional)**

Install Ollama from https://ollama.com, open it once, then in Terminal:
```bash
ollama pull llama3.2
```

### 3. Open Choir

On the Home screen press **Find models**. Everything that is signed in appears with a green tick. Press **New chat**, pick a model under the text box, and type.

If something shows a red cross, hover it — Choir tells you the one thing to do.

---

## What the pieces are

- **Chat** — one conversation, any model. Switch model at the bottom at any time; the whole thread goes with you.
- **Room** — several models answer the same message. *Parallel* (each blind to the others), *Relay* (each reads the ones before it) or *Debate* (a relay round, then a synthesis). Mark the answer you prefer with ★ and from then on every voice builds on it.
- **Projects** — a folder with instructions and files; every chat inside inherits them, whatever model answers.
- **Library** — *Prompts* (voice and rules), *Skills* (a job and when it applies) and *Knowhow* (standing facts). Written once, read by every model. Skills are also real `SKILL.md` folders that Claude Code and Codex read natively — share them from the Library.
- **MCP bridge** — Claude Code and Codex can read Choir's library and history back (Settings › MCP bridge shows the one-line setup).
- **Meters** — if AI Profiles is installed, Choir shows how much of each subscription is left and can switch to the account that still has room.

## Reporting a problem

**Help › Report a Problem…** (⌘⇧B), or the *Report* button next to any error. It takes a screenshot of the Choir window (you see it first and can leave it out), asks what went wrong, and files a GitHub issue in this repository. Your conversations are never sent — only what you type, the screenshot if you keep it, and a few setup facts (app version, macOS version, which providers are connected). Filing needs a GitHub login: `gh auth login` in Terminal, or a token pasted in Settings › General.

## Keyboard

⌘N new chat · ⌘⇧N new room · ⌘⌥N new project · ⌘K jump anywhere · ⌘⇧1…9 switch model · Return send · Shift-Return new line · Esc stop · ⌘⇧B report a problem

---

## For developers

Plain `swiftc`, no Xcode project.

```bash
CHOIR_ARCHES=arm64 bash build.sh      # build + install to /Applications
bash run-tests.sh                     # headless checks incl. live CLI round trips
bash make-dmg.sh                      # Choir.dmg for colleagues
bash make-icon.sh                     # AppIcon.icns from icon.png
```

`CHOIR_NO_INSTALL=1` skips the install step. Data lives in `~/Library/Application Support/Choir/` (plain JSON; API keys, if you ever add any, live in the Keychain). Contributions: open an issue first.

Made by Sam De Herdt for MakeWaves.
