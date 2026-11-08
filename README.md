# Termux AI Installers

Unofficial installers for AI agent CLIs on **Termux** (Android ARM64), without proot.

| CLI | Installer | What it fixes |
|-----|-----------|----------------|
| **Grok Build** (xAI) | [`install-grok-termux.sh`](./install-grok-termux.sh) | Static musl binary + DNS path patch |
| **Cursor Agent** | [`install-cursor-termux.sh`](./install-cursor-termux.sh) | Official linux/arm64 package + Bionic shims (sqlite3 + tree-sitter rebuild) |

## Quick start

```bash
# Interactive picker
bash install.sh

# Or install one directly
bash install.sh grok
bash install.sh cursor
```

Pin a build when you want a known-good version:

```bash
bash install.sh grok 1.0.3
bash install.sh cursor 2026.11.05-86047df
```

## Grok Build

```bash
bash install-grok-termux.sh           # latest stable
bash install-grok-termux.sh 1.0.3     # pin a version
GROK_CHANNEL=alpha bash install-grok-termux.sh
```

Then:

```bash
grok
grok login     # or: export XAI_API_KEY=...
```

## Cursor Agent

Official Cursor Agent is a glibc Node bundle. Termux is Bionic, so this installer swaps in Termux `node` / `rg`, rebuilds sqlite3 + tree-sitter for Bionic, installs a preload (glibc spoof + native stubs), and drops a durable `cursor-agent` launcher.

```bash
bash install-cursor-termux.sh
# or pin a build:
bash install-cursor-termux.sh 2026.11.05-86047df
```

Then:

```bash
source ~/.bashrc
NO_OPEN_BROWSER=1 cursor-agent login
cursor-agent status
cd ~/your-project && cursor-agent
```

Use `cursor-agent` (not `agent`) — `agent` is reserved for Grok Build when both are installed.

After `cursor-agent update`, **re-run the installer** so Termux patches and the node/rg symlinks are restored.

### Requirements (Cursor)

- Android ARM64 (`aarch64`)
- Termux (F-Droid recommended)
- Cursor account / subscription (login; no BYO API key required)

## CI

GitHub Actions (`.github/workflows/ci.yml`) runs a **build** job that syntax-checks every installer (`bash -n`), runs ShellCheck (advisory), and smokes `--help` / `--list`.

## Disclaimer

These installers are unofficial community scripts. Grok Build and Cursor Agent are proprietary. Expect breakage when upstream bundles change. Not affiliated with xAI or Anysphere / Cursor.
