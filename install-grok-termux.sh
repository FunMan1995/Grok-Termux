#!/data/data/com.termux/files/usr/bin/bash
# install-grok-termux.sh — native Termux installer for xAI Grok Build.
#
# The official linux-aarch64 (and linux-x86_64) artifact is a static musl
# binary, so it runs on Android without proot. What official install.sh does
# NOT fix is DNS: grok hardcodes the 16-byte path "/etc/resolv.conf", which
# is missing or empty on stock Termux. This installer:
#
#   1. downloads the official binary
#   2. keeps a versioned copy under ~/.grok/versions
#   3. installs a launcher + byte-patcher that rewrite that path to
#      "/sdcard/.grokdns" (also exactly 16 bytes) on every launch
#   4. puts $PREFIX/bin/grok FIRST so `grok update` cannot hide the launcher
#
# Usage:
#   bash /sdcard/Download/install-grok-termux.sh           # latest stable
#   bash /sdcard/Download/install-grok-termux.sh 1.0.3     # pin a version
#   GROK_CHANNEL=alpha bash .../install-grok-termux.sh
#
# Env:
#   GROK_CHANNEL   stable|alpha|enterprise   (default: stable)
#   GROK_BIN_DIR   official drop dir         (default: ~/.grok/bin)
#
# No proot. Re-runnable. Survives `grok update`.

set -euo pipefail

TARGET="${1:-}"
CHANNEL="${GROK_CHANNEL:-stable}"
BASE_URL_PRIMARY="https://x.ai/cli"
BASE_URL_FALLBACK="https://storage.googleapis.com/grok-build-public-artifacts/cli"
DNS_FILE="/sdcard/.grokdns"

die()  { printf '[grok-termux] %s\n' "$*" >&2; exit 1; }
info() { printf '[grok-termux] %s\n' "$*" >&2; }

if [[ "${TARGET:-}" == "-h" || "${TARGET:-}" == "--help" ]]; then
  sed -n '2,28p' "$0"
  exit 0
fi

if [[ -n "$TARGET" && ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]]; then
  die "invalid version: $TARGET (expected X.Y.Z)"
fi

# --- Termux / arch ----------------------------------------------------------

if [ -z "${PREFIX:-}" ]; then
  if [ -d /data/data/com.termux/files/usr ]; then
    PREFIX=/data/data/com.termux/files/usr
  else
    die "PREFIX unset and this does not look like Termux."
  fi
fi
export PREFIX

case "${TERMUX_VERSION:-}${PREFIX}" in
  */com.termux/*) ;;
  *)
    if [ ! -d /data/data/com.termux/files/usr ]; then
      die "this installer is Termux-only (no proot, no glibc distro)."
    fi
    ;;
esac

case "$(uname -m)" in
  aarch64|arm64|ARM64) arch="aarch64" ;;
  x86_64|amd64|AMD64)  arch="x86_64"  ;;
  *) die "unsupported architecture: $(uname -m) (need aarch64 or x86_64)" ;;
esac
platform="linux-${arch}"

HOME="${HOME:-/data/data/com.termux/files/home}"
# If invoked from proot-distro, $HOME is /home/<user>. Pin to Termux home.
if [ ! -d "$HOME/.termux" ] && [ -d /data/data/com.termux/files/home ]; then
  HOME=/data/data/com.termux/files/home
fi
export HOME

DOWNLOAD_DIR="$HOME/.grok/downloads"
BIN_DIR="${GROK_BIN_DIR:-$HOME/.grok/bin}"
VERSIONS="$HOME/.grok/versions"
AGENTS="$HOME/agents/grok"

# --- packages ---------------------------------------------------------------

ensure_cmd() {
  local cmd="$1" pkg="${2:-$1}"
  command -v "$cmd" >/dev/null 2>&1 && return 0
  command -v pkg >/dev/null 2>&1 || die "pkg not found; is this Termux?"
  info "installing package: $pkg"
  pkg install -y "$pkg" >/dev/null
  command -v "$cmd" >/dev/null 2>&1 || die "failed to install $pkg (need $cmd)"
}

ensure_cmd curl curl
ensure_cmd python3 python

# termux-api is optional but browser login + clipboard work better with it.
if ! command -v termux-open-url >/dev/null 2>&1; then
  if command -v pkg >/dev/null 2>&1; then
    info "installing termux-tools / termux-api (browser + clipboard helpers)"
    pkg install -y termux-tools termux-api >/dev/null 2>&1 || true
  fi
fi

# --- storage (needed for /sdcard/.grokdns) ----------------------------------

ensure_sdcard() {
  if touch /sdcard/.grokdns.write-test 2>/dev/null; then
    rm -f /sdcard/.grokdns.write-test
    return 0
  fi
  info "storage permission required so grok can read $DNS_FILE"
  if command -v termux-setup-storage >/dev/null 2>&1; then
    termux-setup-storage || true
    local i
    for ((i = 1; i <= 40; i++)); do
      if touch /sdcard/.grokdns.write-test 2>/dev/null; then
        rm -f /sdcard/.grokdns.write-test
        return 0
      fi
      sleep 1
    done
  fi
  die "cannot write $DNS_FILE — run: termux-setup-storage  (grant Files access) and re-run"
}

ensure_sdcard

if ! grep -qs '^nameserver' "$DNS_FILE" 2>/dev/null; then
  printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\nnameserver 8.8.4.4\n' > "$DNS_FILE"
  info "wrote $DNS_FILE"
fi

# --- download helpers -------------------------------------------------------

download_file() {
  local url="$1" output="${2:-}"
  if [ -n "$output" ]; then
    curl -fL --retry 3 --retry-delay 1 --progress-bar -o "$output" "$url"
  else
    curl -fsSL --retry 3 --retry-delay 1 "$url"
  fi
}

# 8-way byte-range fetch for the ~130 MiB binary; falls back to one stream.
download_file_parallel() {
  local url="$1" output="$2"
  local size
  size=$(curl -fsSL --head "$url" 2>/dev/null | awk -F'[: \r\n]+' 'tolower($1)=="content-length"{print $2; exit}')
  if [ -z "${size:-}" ] || ! [ "$size" -ge 16777216 ] 2>/dev/null; then
    download_file "$url" "$output"
    return
  fi
  local n=8 chunk_size tmpdir
  chunk_size=$(( (size + n - 1) / n ))
  tmpdir=$(mktemp -d) || { download_file "$url" "$output"; return; }
  local i start end pids=() all_ok=true pid
  for ((i = 0; i < n; i++)); do
    start=$((i * chunk_size))
    end=$((start + chunk_size - 1))
    [ "$end" -ge "$size" ] && end=$((size - 1))
    curl -fsSL -r "${start}-${end}" -o "${tmpdir}/$(printf 'chunk.%03d' "$i")" "$url" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid" || all_ok=false
  done
  if [ "$all_ok" = true ] && cat "${tmpdir}"/chunk.* > "$output"; then
    rm -rf "$tmpdir"
    return 0
  fi
  rm -rf "$tmpdir"
  download_file "$url" "$output"
}

is_not_found() {
  local code
  code=$(curl -o /dev/null -sSL -w '%{http_code}' --head "$1" 2>/dev/null) || true
  [ "$code" = "404" ]
}

# --- resolve version --------------------------------------------------------

mkdir -p "$DOWNLOAD_DIR" "$BIN_DIR" "$VERSIONS" "$AGENTS" \
         "$HOME/.grok/completions/bash" "$HOME/.grok/completions/zsh"

if [ -z "$TARGET" ]; then
  info "fetching latest ${CHANNEL} version..."
fi

probe_result=""
BASE_URL="$BASE_URL_PRIMARY"
probe_result=$(download_file "${BASE_URL_PRIMARY}/${CHANNEL}" 2>/dev/null) || true
if [ -z "$probe_result" ]; then
  info "x.ai/cli unreachable, falling back to GCS"
  BASE_URL="$BASE_URL_FALLBACK"
  probe_result=$(download_file "${BASE_URL_FALLBACK}/${CHANNEL}" 2>/dev/null) || true
fi

if [ -n "$TARGET" ]; then
  version="$TARGET"
else
  version=$(printf '%s' "$probe_result" | tr -d '\r' | head -n1 | tr -d '[:space:]')
  [ -n "$version" ] || die "failed to fetch latest version from ${CHANNEL} channel"
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$ ]]; then
  die "invalid version from channel pointer: $version"
fi

info "installing Grok $version ($platform, Termux native, no proot)"

# --- fetch binary -----------------------------------------------------------

artifact="${BASE_URL}/grok-${version}-${platform}"
binary_path="$DOWNLOAD_DIR/grok-${platform}"
binary_tmp="${binary_path}.tmp.$$"
rm -f "$binary_tmp"

info "downloading $artifact"
if ! download_file_parallel "$artifact" "$binary_tmp"; then
  rm -f "$binary_tmp"
  if is_not_found "$artifact"; then
    die "Grok is not published for $platform"
  fi
  die "download failed: $artifact"
fi
chmod 700 "$binary_tmp"

# Static musl: --version must work even before the DNS patch.
if ! "$binary_tmp" --version </dev/null >/dev/null 2>&1; then
  rm -f "$binary_tmp"
  die "downloaded grok failed to execute (not a working musl binary)"
fi

mv -f "$binary_tmp" "$binary_path"
cp -f "$binary_path" "$VERSIONS/$version"
chmod 700 "$VERSIONS/$version"
printf '%s' "$version" > "$VERSIONS/.verified"

# Official layout: updater writes downloads/grok-<platform> and retargets these.
if [ "$(dirname "$BIN_DIR")" = "$(dirname "$DOWNLOAD_DIR")" ]; then
  link_target="../$(basename "$DOWNLOAD_DIR")/$(basename "$binary_path")"
else
  link_target="$binary_path"
fi
ln -sfn "$link_target" "$BIN_DIR/grok"
ln -sfn "$link_target" "$BIN_DIR/agent"

# --- launcher + DNS byte-patcher --------------------------------------------

cat > "$AGENTS/grok-dns.py" << 'PY'
#!/data/data/com.termux/files/usr/bin/env python3
# Set the grok (static musl) binary's DNS-config path in place. Both targets are
# exactly 16 bytes, so it's a byte-for-byte swap (no length change, no relocation):
#
#   native  -> "/etc/resolv.conf"   (rooted: a systemless resolv module provides it)
#   sdcard  -> "/sdcard/.grokdns"   (no root: the only short, app-writable path)
#
# Called by launcher.sh with the chosen mode. Idempotent and bidirectional: it only
# writes when the binary isn't already in the requested mode, so it survives grok
# self-updates (which restore the original string) and switching root <-> no-root.
import sys, mmap

NATIVE = b"/etc/resolv.conf"
SDCARD = b"/sdcard/.grokdns"          # both exactly 16 bytes
assert len(NATIVE) == len(SDCARD) == 16

path, mode = sys.argv[1], sys.argv[2]
target = NATIVE if mode == "native" else SDCARD
other  = SDCARD if mode == "native" else NATIVE

with open(path, "r+b") as f:
    mm = mmap.mmap(f.fileno(), 0)
    try:
        n = 0
        i = mm.find(other)
        while i != -1:
            mm[i:i + 16] = target
            n += 1
            i = mm.find(other, i + 16)
        if n:
            mm.flush()
            sys.stderr.write(f"[grok] DNS path -> {target.decode()} ({n}x)\n")
    finally:
        mm.close()
PY
chmod 755 "$AGENTS/grok-dns.py"

cat > "$AGENTS/launcher.sh" << 'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
# grok — native Termux launcher (xAI Grok Build, static musl binary). No proot.
#
# Always bind to the Termux home that owns this launcher, even if invoked from
# a proot-distro where $HOME is /home/<user>. Resolve $0 first: $PREFIX/bin/grok
# is a symlink, so dirname "$0" is $PREFIX/bin (two levels up is NOT $HOME).
#
# DNS is auto-detected each launch:
#   • rooted Termux → /etc is a symlink into /system/etc AND that resolv.conf
#     has a nameserver, so the PRISTINE binary resolves natively, no patch.
#   • stock Termux / proot → byte-patch the hardcoded 16-byte "/etc/resolv.conf"
#     string to "/sdcard/.grokdns". proot's own /etc/resolv.conf must not
#     un-patch the native binary.
# grok-dns.py swaps EITHER direction and only writes on an actual change.
SELF="$0"
while [ -L "$SELF" ]; do
  _link="$(readlink "$SELF")" || break
  case "$_link" in
    /*) SELF="$_link" ;;
    *)  SELF="$(cd "$(dirname "$SELF")" && pwd)/$_link" ;;
  esac
done
unset _link
DIR="$(cd "$(dirname "$SELF")" && pwd)"
HOME="$(cd "$DIR/../.." && pwd)"
# Fallback if the script is not under ~/agents/grok (or symlink resolve failed).
if [ ! -d "$HOME/.grok/versions" ]; then
  HOME="${PREFIX:-/data/data/com.termux/files/usr}/../home"
  HOME="$(cd "$HOME" && pwd)"
fi
export HOME
VERSIONS="$HOME/.grok/versions"
DNS="/sdcard/.grokdns"
GROKBIN="$HOME/.grok/bin/grok"

# Adopt grok's own self-updates (Ctrl+U / `grok update`). grok's updater downloads
# the new binary to ~/.grok/downloads/ and marks it current by repointing the
# symlink ~/.grok/bin/grok at it — but it never touches versions/ or .verified,
# which is all this launcher reads. Without this block a self-update silently keeps
# running the old binary. So: resolve that symlink, parse the version from the
# filename, and promote it into the versions/ store + repoint .verified.
upd="$(readlink -f "$GROKBIN" 2>/dev/null || true)"
case "$upd" in
  */grok-*-linux-aarch64|*/grok-*-linux-x86_64)
    uver="${upd##*/grok-}"
    uver="${uver%-linux-aarch64}"
    uver="${uver%-linux-x86_64}"
    if [ -f "$upd" ] && printf '%s' "$uver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
      if [ ! -f "$VERSIONS/$uver" ]; then
        cp -f "$upd" "$VERSIONS/$uver" && chmod 700 "$VERSIONS/$uver" \
          && printf '%s' "$uver" > "$VERSIONS/.verified"
      elif [ "$(cat "$VERSIONS/.verified" 2>/dev/null || true)" != "$uver" ]; then
        printf '%s' "$uver" > "$VERSIONS/.verified"
      fi
    fi
    ;;
esac

verified="$(cat "$VERSIONS/.verified" 2>/dev/null || true)"
bin=""
if [ -n "$verified" ] && [ -f "$VERSIONS/$verified" ]; then
  bin="$VERSIONS/$verified"
else
  for c in $(ls -1 "$VERSIONS" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+' | sort -Vr); do
    [ -f "$VERSIONS/$c" ] && { bin="$VERSIONS/$c"; break; }
  done
fi
[ -n "$bin" ] || { echo "[grok] no installed binary in $VERSIONS — re-run install-grok-termux.sh." >&2; exit 1; }

# Native DNS only on real Android /etc (symlink to /system/etc) with a nameserver.
# proot-distro has a real /etc/resolv.conf and must not flip the binary back.
if [ -L /etc ] && [ -s /system/etc/resolv.conf ] && grep -q '^nameserver' /system/etc/resolv.conf 2>/dev/null; then
  MODE=native
else
  MODE=sdcard
  grep -qs nameserver "$DNS" 2>/dev/null || printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$DNS" 2>/dev/null
fi
python3 "$DIR/grok-dns.py" "$bin" "$MODE" 2>/dev/null || true

exec "$bin" "$@"
LAUNCH
chmod 755 "$AGENTS/launcher.sh"

# $PREFIX/bin beats ~/.grok/bin, so the official drop never shadows us.
ln -sfn "$AGENTS/launcher.sh" "$PREFIX/bin/grok"
ln -sfn "$AGENTS/launcher.sh" "$PREFIX/bin/agent"

# Apply the DNS patch now (not only on first interactive launch).
if [ -L /etc ] && [ -s /system/etc/resolv.conf ] && grep -q '^nameserver' /system/etc/resolv.conf 2>/dev/null; then
  python3 "$AGENTS/grok-dns.py" "$VERSIONS/$version" native || true
else
  python3 "$AGENTS/grok-dns.py" "$VERSIONS/$version" sdcard || true
fi

# --- completions + config.toml ----------------------------------------------

"$VERSIONS/$version" completions bash > "$HOME/.grok/completions/bash/grok.bash" 2>/dev/null || true
"$VERSIONS/$version" completions zsh  > "$HOME/.grok/completions/zsh/_grok"     2>/dev/null || true
if mkdir -p "$HOME/.config/fish/completions" 2>/dev/null; then
  "$VERSIONS/$version" completions fish > "$HOME/.config/fish/completions/grok.fish" 2>/dev/null || true
fi

CONFIG_FILE="$HOME/.grok/config.toml"
CLI_BLOCK="installer = \"internal\""
if [ "$CHANNEL" != "stable" ]; then
  CLI_BLOCK="${CLI_BLOCK}\nchannel = \"${CHANNEL}\""
fi
if [ ! -f "$CONFIG_FILE" ]; then
  printf '[cli]\n%b\n' "$CLI_BLOCK" > "$CONFIG_FILE"
elif grep -q '^\[cli\]' "$CONFIG_FILE"; then
  tmp="$CONFIG_FILE.tmp.$$"
  awk -v block="$CLI_BLOCK" '
    /^\[cli\][[:space:]]*(#.*)?$/ { print; printf "%s\n", block; in_cli=1; next }
    /^\[.*\][[:space:]]*(#.*)?$/  { in_cli=0 }
    in_cli && /^[[:space:]]*(installer|channel)[[:space:]]*=/ { next }
    { print }
  ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
else
  printf '\n[cli]\n%b\n' "$CLI_BLOCK" >> "$CONFIG_FILE"
fi

# --- PATH: launcher first, official drop last --------------------------------

path_has_dir() {
  case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

install_rc_block() {
  local config_file="$1" user_shell="$2"
  [ -n "$config_file" ] || return 0
  mkdir -p "$(dirname "$config_file")"

  if [ -e "$config_file" ] || [ -L "$config_file" ]; then
    local _cf="$config_file" _depth=0 _link
    while [ -L "$_cf" ] && [ "$_depth" -lt 40 ]; do
      _link="$(readlink "$_cf")" || break
      case "$_link" in
        /*) _cf="$_link" ;;
        *)  _cf="$(cd "$(dirname "$_cf")" && pwd -P)/$_link" ;;
      esac
      _depth=$((_depth + 1))
    done
    if [ ! -L "$_cf" ]; then
      config_file="$(cd "$(dirname "$_cf")" && pwd -P)/$(basename "$_cf")"
    fi
  fi

  local new_block
  case "$user_shell" in
    fish)
      new_block='# >>> grok installer >>>
# Official drop last so it cannot hide '"$PREFIX"'/bin/grok (the Termux launcher).
fish_add_path $HOME/.grok/bin
# <<< grok installer <<<'
      ;;
    zsh)
      new_block='# >>> grok installer >>>
# $PREFIX/bin/grok is the Termux launcher. Keep ~/.grok/bin after it so the
# official update drop does not hide the DNS-patched launcher.
export PATH="$PATH:$HOME/.grok/bin"
fpath=(~/.grok/completions/zsh $fpath)
autoload -Uz compinit && compinit -C
# <<< grok installer <<<'
      ;;
    *)
      new_block='# >>> grok installer >>>
# $PREFIX/bin/grok is the Termux launcher. Keep ~/.grok/bin after it so the
# official update drop does not hide the DNS-patched launcher.
export PATH="$PATH:$HOME/.grok/bin"
[[ -r "$HOME/.grok/completions/bash/grok.bash" ]] && source "$HOME/.grok/completions/bash/grok.bash"
# <<< grok installer <<<'
      ;;
  esac

  if grep -qs "grok installer" "$config_file" 2>/dev/null; then
    local tmp="$config_file.tmp.$$"
    awk '
      /# >>> grok installer >>>/ { skip=1; next }
      /# <<< grok installer <<</ { skip=0; next }
      !skip { print }
    ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
  elif [ -f "$config_file" ]; then
    cp "$config_file" "$config_file.bak.$(date +%s)"
  fi
  printf '\n%s\n' "$new_block" >> "$config_file"
  info "updated PATH in $config_file"
}

user_shell="$(basename "${SHELL:-bash}")"
case "$user_shell" in
  bash) install_rc_block "$HOME/.bashrc" bash ;;
  zsh)  install_rc_block "$HOME/.zshrc" zsh ;;
  fish) install_rc_block "$HOME/.config/fish/config.fish" fish ;;
  *)    install_rc_block "$HOME/.bashrc" bash ;;
esac

# Login shells on Termux often skip .bashrc; make sure .bash_profile sources it.
if [ -f "$HOME/.bash_profile" ] && ! grep -qs 'source ~/.bashrc\|\. ~/.bashrc' "$HOME/.bash_profile"; then
  printf '\n[[ -r ~/.bashrc ]] && source ~/.bashrc\n' >> "$HOME/.bash_profile"
fi

# --- verify -----------------------------------------------------------------

got="$("$PREFIX/bin/grok" --version 2>/dev/null | head -n1 || true)"
[ -n "$got" ] || die "launcher installed but 'grok --version' produced no output"

info ""
info "Grok $version installed (Termux native)."
info "  binary : $VERSIONS/$version"
info "  launch : $PREFIX/bin/grok -> $AGENTS/launcher.sh"
info "  dns    : $DNS_FILE"
info "  report : $got"
info ""
info "Run:  grok"
info "Login: grok login     (or export XAI_API_KEY=...)"
info "Update later with:  grok update   then just run grok again"
info "Reinstall / pin:    bash $0 [version]"
