# Grok-Termux

Run AI agent CLIs directly on Termux (Android ARM64), without proot.

| CLI | Installer | Notes |
|-----|-----------|--------|
| **Grok** (xAI) | [`install-grok-termux.sh`](./install-grok-termux.sh) | Static musl binary + DNS path patch |
| **Cursor Agent** | [`install-cursor-termux.sh`](./install-cursor-termux.sh) | Official linux/arm64 package + Bionic compatibility |

## Grok

```bash
bash /sdcard/Download/install-grok-termux.sh           # latest stable
bash /sdcard/Download/install-grok-termux.sh 1.0.3     # pin a version
GROK_CHANNEL=alpha bash .../install-grok-termux.sh
```

Then:

```bash
grok
grok login     # or: export XAI_API_KEY=...
```

## Cursor Agent

Official Cursor Agent is a glibc Node bundle. Termux is Bionic, so this installer swaps in Termux `node` / `rg`, installs a preload (glibc spoof + native stubs), and drops a durable launcher.

```bash
bash /sdcard/Download/install-cursor-termux.sh
# or pin:
bash /sdcard/Download/install-cursor-termux.sh 2026.11.05-86047df
```

Then:

```bash
source ~/.bashrc
NO_OPEN_BROWSER=1 cursor-agent login
cursor-agent status
cd ~/your-project && cursor-agent
```

`agent` is aliased to `cursor-agent`.

After `cursor-agent update`, **re-run the installer** so Termux patches and the node/rg symlinks are restored.

### Requirements (Cursor)

- Android ARM64 (`aarch64`)
- Termux (F-Droid recommended)
- Cursor account / subscription (login; no BYO API key required)

## Disclaimer

These installers are unofficial community scripts. Grok and Cursor Agent are proprietary. Expect breakage when upstream bundles change.
