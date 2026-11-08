#!/data/data/com.termux/files/usr/bin/bash
# install.sh — Termux AI Installers entrypoint.
#
# Installs AI agent CLIs on Termux (Android ARM64):
#   grok     xAI Grok Build (static musl + DNS patch)
#   cursor   Cursor Agent CLI (official package + Bionic shims)
#
# Usage:
#   bash install.sh                 # interactive picker
#   bash install.sh grok [version]
#   bash install.sh cursor [version]
#   bash install.sh --list
#
# Or run a specific installer directly:
#   bash install-grok-termux.sh
#   bash install-cursor-termux.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die()  { printf '[termux-ai] %s\n' "$*" >&2; exit 1; }
info() { printf '[termux-ai] %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
Termux AI Installers — run AI agent CLIs on Termux (Android ARM64)

Usage:
  bash install.sh                 interactive picker
  bash install.sh grok [ver]      install xAI Grok Build
  bash install.sh cursor [ver]    install Cursor Agent CLI
  bash install.sh --list          show available installers
  bash install.sh -h|--help       this help

Examples:
  bash install.sh grok
  bash install.sh grok 1.0.3
  bash install.sh cursor
  bash install.sh cursor 2026.11.05-86047df
EOF
}

list_installers() {
  cat <<'EOF'
Available installers:
  grok     install-grok-termux.sh      xAI Grok Build (musl + DNS patch)
  cursor   install-cursor-termux.sh    Cursor Agent CLI (Bionic shims)
EOF
}

run_installer() {
  local name="$1"
  shift || true
  local script=""
  case "$name" in
    grok|grok-build|xai)
      script="$ROOT/install-grok-termux.sh"
      ;;
    cursor|cursor-agent|agent)
      script="$ROOT/install-cursor-termux.sh"
      ;;
    *)
      die "unknown installer: $name (try: grok, cursor)"
      ;;
  esac
  [ -f "$script" ] || die "missing installer script: $script"
  info "running $(basename "$script")${*:+ ($*)}"
  exec bash "$script" "$@"
}

pick_interactive() {
  if [ ! -t 0 ]; then
    die "no installer specified (non-interactive). Use: bash install.sh grok|cursor"
  fi
  printf '\nTermux AI Installers\n\n' >&2
  printf '  1) Grok Build (xAI)\n' >&2
  printf '  2) Cursor Agent\n' >&2
  printf '  q) Quit\n\n' >&2
  printf 'Choose [1/2/q]: ' >&2
  local choice
  read -r choice
  case "$choice" in
    1|grok|Grok) run_installer grok "$@" ;;
    2|cursor|Cursor) run_installer cursor "$@" ;;
    q|Q|quit|"") info "cancelled"; exit 0 ;;
    *) die "invalid choice: $choice" ;;
  esac
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "" )
      pick_interactive
      ;;
    -h|--help|help)
      usage
      ;;
    --list|list)
      list_installers
      ;;
    grok|grok-build|xai|cursor|cursor-agent|agent)
      shift
      run_installer "$cmd" "$@"
      ;;
    *)
      die "unknown command: $cmd (try --help)"
      ;;
  esac
}

main "$@"
