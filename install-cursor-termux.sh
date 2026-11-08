#!/data/data/com.termux/files/usr/bin/bash
# install-cursor-termux.sh — Termux AI Installers: official Cursor Agent CLI.
#
# Official Cursor Agent ships a linux/arm64 glibc Node bundle. Termux is Bionic,
# so the stock binary (bundled node, ripgrep, native .node addons) does not run.
# This installer:
#
#   1. downloads the official agent-cli package (same channel as cursor.com/install)
#   2. keeps it under ~/.local/share/cursor-agent/versions/<ver>
#   3. swaps bundled node/rg for Termux's node + ripgrep
#   4. installs a Node preload that spoofs glibc detection and stubs native
#      modules Cursor cannot dlopen on Android (file-service / merkle)
#   5. best-effort patches Merkle failure path + rebuilds sqlite3 for Bionic
#   6. installs a durable launcher in $PREFIX/bin so updates cannot hide it
#
# Usage:
#   bash /sdcard/Download/install-cursor-termux.sh              # latest
#   bash /sdcard/Download/install-cursor-termux.sh 2026.11.05-86047df
#
# Env:
#   CURSOR_VERSION   pin version (same as argv[1])
#   CURSOR_BIN_DIR   launcher drop dir (default: $PREFIX/bin)
#
# After install:
#   source ~/.bashrc
#   NO_OPEN_BROWSER=1 cursor-agent login
#   cursor-agent
#
# Re-run this script after `cursor-agent update` (self-update can wipe patches).
# Unofficial community installer; Cursor Agent is proprietary. Not affiliated
# with Anysphere / Cursor. Approach inspired by the MIT-licensed cursor-termux
# community package.

set -euo pipefail

TARGET="${1:-${CURSOR_VERSION:-}}"
DNS_FILE="/sdcard/.cursordns"

die()  { printf '[cursor-termux] %s\n' "$*" >&2; exit 1; }
info() { printf '[cursor-termux] %s\n' "$*" >&2; }
warn() { printf '[cursor-termux] warn: %s\n' "$*" >&2; }

if [[ "${TARGET:-}" == "-h" || "${TARGET:-}" == "--help" ]]; then
  awk 'NR==1{next} /^[^#]/&&$0!=""{exit} {print}' "$0"
  exit 0
fi

if [[ -n "$TARGET" && ! "$TARGET" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]]; then
  die "invalid version: $TARGET (expected YYYY.MM.DD-<hash>, e.g. 2026.11.05-86047df)"
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
      die "this installer is Termux-only (Android / Bionic)."
    fi
    ;;
esac

case "$(uname -m)" in
  aarch64|arm64|ARM64) arch="arm64" ;;
  *) die "unsupported architecture: $(uname -m) (need aarch64 / arm64)" ;;
esac

HOME="${HOME:-/data/data/com.termux/files/home}"
if [ ! -d "$HOME/.termux" ] && [ -d /data/data/com.termux/files/home ]; then
  HOME=/data/data/com.termux/files/home
fi
export HOME

INSTALL_ROOT="${HOME}/.local/share/cursor-agent"
VERSIONS="${INSTALL_ROOT}/versions"
LOCAL_BIN="${HOME}/.local/bin"
BIN_DIR="${CURSOR_BIN_DIR:-$PREFIX/bin}"
AGENTS="${HOME}/agents/cursor"
PRELOAD_DST="${INSTALL_ROOT}/termux-preload.js"
LAUNCHER="${AGENTS}/launcher.sh"

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
ensure_cmd tar tar
ensure_cmd python3 python

# Node + ripgrep replace the glibc-bundled binaries. Build tools are best-effort
# for rebuilding sqlite3 against Bionic.
info "ensuring Termux runtime packages (nodejs-lts, ripgrep, build tools)"
if command -v pkg >/dev/null 2>&1; then
  mkdir -p "$PREFIX/etc/apt"
  if [ ! -s "$PREFIX/etc/apt/sources.list" ]; then
    printf 'deb https://packages.termux.dev/apt/termux-main stable main\n' \
      > "$PREFIX/etc/apt/sources.list"
  fi
  pkg install -y nodejs-lts ripgrep python make clang pkg-config binutils \
    openssl-tool which git >/dev/null 2>&1 || true
fi
ensure_cmd node nodejs-lts
ensure_cmd rg ripgrep

# termux-api is optional but browser login works better with it.
if ! command -v termux-open-url >/dev/null 2>&1; then
  if command -v pkg >/dev/null 2>&1; then
    info "installing termux-tools / termux-api (browser helpers)"
    pkg install -y termux-tools termux-api >/dev/null 2>&1 || true
  fi
fi

# Optional storage write (mirrors grok installer; useful for shared notes / DNS).
if touch /sdcard/.cursordns.write-test 2>/dev/null; then
  rm -f /sdcard/.cursordns.write-test
  if [ ! -f "$DNS_FILE" ]; then
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > "$DNS_FILE" 2>/dev/null || true
  fi
fi

mkdir -p "$VERSIONS" "$LOCAL_BIN" "$BIN_DIR" "$AGENTS" "$HOME/tmp" \
         "$HOME/.cache/cursor-termux"

# --- helpers ----------------------------------------------------------------

safe_rm_version_dir() {
  local dir="$1"
  [ -e "$dir" ] || [ -L "$dir" ] || return 0
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    # Unlink first so we never delete through a symlink into $PREFIX/bin/node.
    rm -f "$dir/node" "$dir/rg" 2>/dev/null || true
    rm -rf "$dir"
  else
    rm -f "$dir" 2>/dev/null || true
  fi
}

download_file() {
  local url="$1" output="${2:-}"
  if [ -n "$output" ]; then
    curl -fL --retry 3 --retry-delay 1 --progress-bar -o "$output" "$url"
  else
    curl -fsSL --retry 3 --retry-delay 1 "$url"
  fi
}

# --- resolve version --------------------------------------------------------

if [ -z "$TARGET" ]; then
  info "fetching latest version from https://cursor.com/install"
  installer_tmp="$(mktemp)"
  if ! download_file "https://cursor.com/install" "$installer_tmp"; then
    rm -f "$installer_tmp"
    die "failed to download https://cursor.com/install"
  fi
  version="$(grep -E -o '[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+' "$installer_tmp" | head -n1 || true)"
  rm -f "$installer_tmp"
  [ -n "$version" ] || die "could not parse version from cursor.com/install"
else
  version="$TARGET"
fi

if [[ ! "$version" =~ ^[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[A-Za-z0-9]+$ ]]; then
  die "invalid version: $version"
fi

info "installing Cursor Agent $version (linux/${arch}, Termux / Bionic)"

# Stop anything holding VERSION_DIR/node (prevents Text file busy).
if command -v pkill >/dev/null 2>&1; then
  pkill -f "${INSTALL_ROOT}/versions/.*/index.js" 2>/dev/null || true
  pkill -f "cursor-agent" 2>/dev/null || true
  sleep 0.3 2>/dev/null || true
fi

# --- download package -------------------------------------------------------

VERSION_DIR="${VERSIONS}/${version}"
url="https://downloads.cursor.com/lab/${version}/linux/${arch}/agent-cli-package.tar.gz"
if curl -sfI "https://downloads.cursor.com/lab/${version}/android/${arch}/agent-cli-package.tar.gz" >/dev/null 2>&1; then
  url="https://downloads.cursor.com/lab/${version}/android/${arch}/agent-cli-package.tar.gz"
  info "using android/${arch} package"
else
  info "using linux/${arch} package"
fi

tmp="$(mktemp -d)"
stage="$(mktemp -d)"
cleanup() {
  rm -rf "${tmp:-}"
  # Only remove stage if it still exists as our temp dir (not after mv).
  if [ -n "${stage:-}" ] && [ -d "${stage}" ] && [ "${stage}" != "${VERSION_DIR:-}" ]; then
    rm -rf "${stage}"
  fi
}
trap cleanup EXIT

info "downloading $url"
archive="${tmp}/agent-cli-package.tar.gz"
download_file "$url" "$archive" || die "download failed: $url"
tar -xzf "$archive" -C "$tmp"

if [ -f "$tmp/index.js" ]; then
  src="$tmp"
else
  src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -n1 || true)"
  [ -n "${src:-}" ] || die "unexpected package layout"
fi

# Stage a fresh tree; never copy onto an existing node symlink (Text file busy).
cp -a "$src"/. "$stage"/
rm -f "$stage/node" "$stage/rg"
safe_rm_version_dir "$VERSION_DIR"
mv "$stage" "$VERSION_DIR"
stage=""  # moved; trap should not remove destination
[ -f "$VERSION_DIR/index.js" ] || die "index.js missing after extract"
printf '%s' "$version" > "${VERSIONS}/.verified"
info "extracted to $VERSION_DIR"

# --- swap glibc binaries for Termux ----------------------------------------

rm -f "$VERSION_DIR/node" "$VERSION_DIR/rg"
ln -sfn "$(command -v node)" "$VERSION_DIR/node"
ln -sfn "$(command -v rg)" "$VERSION_DIR/rg"
info "node -> $(command -v node)"
info "rg   -> $(command -v rg)"

# --- TLS + library shims ----------------------------------------------------

mkdir -p "$PREFIX/etc/tls/certs"
if [ -f "$PREFIX/etc/tls/cert.pem" ]; then
  ln -sfn "$PREFIX/etc/tls/cert.pem" "$PREFIX/etc/tls/certs/cert.pem"
fi
if [ -f "$PREFIX/lib/libc++_shared.so" ]; then
  ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so.6"
  ln -sfn "$PREFIX/lib/libc++_shared.so" "$PREFIX/lib/libstdc++.so"
fi
if command -v clang >/dev/null 2>&1; then
  stub_c="$HOME/.cache/cursor-termux/empty-gnu-compat.c"
  cat > "$stub_c" <<'C'
void __termux_gnu_compat_stub(void) {}
C
  clang -shared -fPIC -Wl,-soname,libm.so.6 "$stub_c" -o "$PREFIX/lib/libm.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libc.so.6 "$stub_c" -o "$PREFIX/lib/libc.so.6" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libpthread.so.0 "$stub_c" -o "$PREFIX/lib/libpthread.so.0" 2>/dev/null || true
  clang -shared -fPIC -Wl,-soname,libdl.so.2 "$stub_c" -o "$PREFIX/lib/libdl.so.2" 2>/dev/null || true
fi
if [ -e "$PREFIX/glibc/lib/libgcc_s.so.1" ]; then
  ln -sfn "$PREFIX/glibc/lib/libgcc_s.so.1" "$PREFIX/lib/libgcc_s.so.1"
fi

# --- sqlite3 rebuild (best effort) ------------------------------------------

info "rebuilding sqlite3 for Bionic (best effort)"
(
  cd "$VERSION_DIR"
  export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
  npm i sqlite3 --ignore-scripts >/dev/null 2>&1 || true
  if [ ! -d node_modules/sqlite3 ]; then
    warn "sqlite3 sources missing; skipping rebuild"
    exit 0
  fi
  find node_modules/sqlite3 -type f \( -name '*.gyp' -o -name '*.gypi' \) -print0 2>/dev/null \
    | xargs -0 sed -i -E \
      -e 's/\bOS\s*==\s*"android"/OS=="never"/g' \
      -e 's/\btarget_os\s*==\s*"android"/target_os=="never"/g' \
      -e '/android_ndk_path/d' \
      -e '/ANDROID_/d' || true
  jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)"
  npx node-gyp configure -C node_modules/sqlite3 -- \
    -DOS=linux -Dtarget_os=linux -Dandroid_ndk_path=/nonexistent >/dev/null 2>&1 || true
  make -C node_modules/sqlite3/build -j "$jobs" V=0 LINK=clang++ >/dev/null 2>&1 || true
  built="node_modules/sqlite3/build/Release/node_sqlite3.node"
  if [ -s "$built" ]; then
    [ -f node_sqlite3.node ] && cp -f node_sqlite3.node "node_sqlite3.node.linux-gnu.bak" || true
    cp -f "$built" node_sqlite3.node
    [ -d build ] && cp -f "$built" build/node_sqlite3.node 2>/dev/null || true
    info "sqlite3 rebuilt for Bionic"
  else
    warn "sqlite3 rebuild failed; continuing with stubs where needed"
  fi
) || warn "sqlite3 rebuild step failed; continuing"

# --- Merkle failure-path patch (defense in depth; preload also stubs) -------

info "patching Merkle native-binding failure path"
index_js="$VERSION_DIR/index.js"
cp -f "$index_js" "${index_js}.pre-merkle-bak"
if ! node - "$index_js" <<'NODE'
const fs = require("fs");
const path = process.argv[2];
let src = fs.readFileSync(path, "utf8");

if (src.includes("MerkleClient:class{constructor(){}}")) {
  console.log("Merkle stub already present");
  process.exit(0);
}

const stub =
  '{MerkleClient:class{constructor(){}async build(){}async getTreeStructure(){return null}async getSimhash(){return[]}async getNumEmbeddableFiles(){return 0}async initWithRipgrepIgnore(){}},getParentProcessInfo:()=>null,MULTI_ROOT_ABSOLUTE_PATH:""}';

// Current builds (2026.11+): variables l/r/t
const patterns = [
  [
    "Original error: ${l&&l.stack?l.stack:l}`;throw new Error(r)}t.exports=u,t.exports.MerkleClient=u.MerkleClient",
    "Original error: ${l&&l.stack?l.stack:l}`;u=" + stub + "}t.exports=u,t.exports.MerkleClient=u.MerkleClient",
  ],
  // Older builds: variables c/n/e
  [
    "Original error: ${c&&c.stack?c.stack:c}`;throw new Error(n)}e.exports=u,e.exports.MerkleClient=u.MerkleClient",
    "Original error: ${c&&c.stack?c.stack:c}`;u=" + stub + "}e.exports=u,e.exports.MerkleClient=u.MerkleClient",
  ],
];

for (const [from, to] of patterns) {
  if (src.includes(from)) {
    src = src.replace(from, to);
    fs.writeFileSync(path, src);
    console.log("Patched Merkle throw -> stub (exact)");
    process.exit(0);
  }
}

// Generic: replace the throw that precedes MerkleClient export.
const re =
  /(`Failed to load native binding for[\s\S]*?`);throw new Error\((\w+)\)\}(\w)\.exports=(\w),\2\.exports\.MerkleClient=\3\.MerkleClient/;
if (re.test(src)) {
  src = src.replace(re, (_, msg, _err, exp, val) => {
    return msg + ";" + val + "=" + stub + "}" + exp + ".exports=" + val + "," + exp + ".exports.MerkleClient=" + val + ".MerkleClient";
  });
  fs.writeFileSync(path, src);
  console.log("Patched Merkle throw -> stub (regex)");
  process.exit(0);
}

console.error("Could not locate Merkle failure path; relying on preload stub");
process.exit(2);
NODE
then
  warn "Merkle index patch skipped; preload will still stub native loads"
else
  node --check "$index_js" || die "patched index.js failed syntax check"
  info "Merkle stub OK"
fi

# --- preload ----------------------------------------------------------------

cat > "$PRELOAD_DST" <<'JS'
"use strict";
/**
 * Termux preload for Cursor Agent (Bionic).
 *
 * Cursor's file-service loader does not call Node require() for the musl
 * package name. When isMusl() is true it throws a synthetic MODULE_NOT_FOUND.
 * On Termux, isMusl() is true (no glibc / no ldd). Fix:
 *   1) Spoof glibc detection (report + ldd)
 *   2) Stub process.dlopen for glibc .node binaries (file_service / merkle)
 */
const fs = require("fs");
const path = require("path");
const Module = require("module");
const cp = require("child_process");
const workerThreads = require("worker_threads");

const versionDir =
  process.env.CURSOR_AGENT_VERSION_DIR ||
  path.dirname(process.argv[1] || "") ||
  process.cwd();
const preloadPath = __filename;

function fileServiceStub() {
  class FileService {
    constructor() {}
    async start() {
      return this;
    }
    async stop() {}
    async getFileStats() {
      return null;
    }
    async readFile() {
      return null;
    }
    async writeFile() {}
    async watch() {
      return { close() {} };
    }
  }
  return new Proxy(
    { FileService, fileService: new FileService(), default: FileService },
    {
      get(target, prop, recv) {
        if (prop in target) return Reflect.get(target, prop, recv);
        if (prop === "then") return undefined;
        if (typeof prop === "symbol") return undefined;
        return (..._args) => null;
      },
    }
  );
}

function merkleStub() {
  class MerkleClient {
    constructor() {}
    async build() {}
    async getTreeStructure() {
      return null;
    }
    async getSimhash() {
      return [];
    }
    async getNumEmbeddableFiles() {
      return 0;
    }
    async initWithRipgrepIgnore() {}
  }
  return {
    MerkleClient,
    getParentProcessInfo: () => null,
    MULTI_ROOT_ABSOLUTE_PATH: "",
  };
}

function ensureJsPackages() {
  const root = path.join(versionDir, "node_modules", "@anysphere");
  for (const name of [
    "file-service-linux-arm64-musl",
    "file-service-linux-arm64-gnu",
  ]) {
    const dir = path.join(root, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(
      path.join(dir, "package.json"),
      JSON.stringify({
        name: `@anysphere/${name}`,
        version: "0.0.0-termux-stub",
        main: "index.js",
      })
    );
    fs.writeFileSync(
      path.join(dir, "index.js"),
      `"use strict";\nmodule.exports = (${fileServiceStub.toString()})();\n`
    );
  }
  const parent = path.join(root, "file-service");
  fs.mkdirSync(parent, { recursive: true });
  fs.writeFileSync(
    path.join(parent, "package.json"),
    JSON.stringify({
      name: "@anysphere/file-service",
      version: "0.0.0-termux-stub",
      main: "index.js",
    })
  );
  fs.writeFileSync(
    path.join(parent, "index.js"),
    `"use strict";\nmodule.exports = require("../file-service-linux-arm64-gnu");\n`
  );
}

ensureJsPackages();

try {
  if (process.report && typeof process.report.getReport === "function") {
    const orig = process.report.getReport.bind(process.report);
    process.report.getReport = function patchedReport(...args) {
      const r = orig(...args) || {};
      r.header = Object.assign({}, r.header || {}, {
        glibcVersionRuntime: "2.38",
      });
      if (!Array.isArray(r.sharedObjects)) r.sharedObjects = [];
      return r;
    };
  }
} catch (_) {}

const origReadFileSync = fs.readFileSync;
fs.readFileSync = function (p, opts) {
  const s = String(p);
  if (s.includes("/ldd") || s.endsWith("ldd")) {
    return opts && String(opts).includes("utf")
      ? "ldd (GNU libc) 2.38\n"
      : Buffer.from("ldd (GNU libc) 2.38\n");
  }
  return origReadFileSync.apply(this, arguments);
};

const origExecSync = cp.execSync;
cp.execSync = function (cmd, opts) {
  const c = String(cmd);
  if (c.includes("ldd")) {
    const out = "ldd (GNU libc) 2.38\n";
    if (opts && (opts.encoding === "utf8" || opts.encoding === "utf-8")) return out;
    return Buffer.from(out);
  }
  return origExecSync.apply(this, arguments);
};

const origExists = fs.existsSync;
fs.existsSync = function (p) {
  if (String(p) === "/usr/bin/ldd") return true;
  return origExists.apply(this, arguments);
};

const origDlopen = process.dlopen;
process.dlopen = function (mod, filename, ...rest) {
  const f = String(filename || "");
  try {
    if (f.includes("file_service") || f.includes("file-service")) {
      mod.exports = fileServiceStub();
      return;
    }
    if (f.includes("merkle-tree-napi") || f.includes("merkle_tree")) {
      mod.exports = merkleStub();
      return;
    }
  } catch (_) {}
  return origDlopen.call(this, mod, filename, ...rest);
};

function mapRequest(request) {
  if (typeof request !== "string") return null;
  if (!request.includes("@anysphere/file-service")) return null;
  if (request === "@anysphere/file-service") {
    return path.join(versionDir, "node_modules/@anysphere/file-service/index.js");
  }
  if (request.includes("gnu")) {
    return path.join(
      versionDir,
      "node_modules/@anysphere/file-service-linux-arm64-gnu/index.js"
    );
  }
  return path.join(
    versionDir,
    "node_modules/@anysphere/file-service-linux-arm64-musl/index.js"
  );
}

const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  const mapped = mapRequest(request);
  if (mapped) return mapped;
  return origResolve.call(this, request, parent, isMain, options);
};

const origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  const mapped = mapRequest(request);
  if (mapped) return origLoad.call(this, mapped, parent, isMain);
  return origLoad.call(this, request, parent, isMain);
};

function injectPreload(execArgv) {
  const argv = Array.isArray(execArgv) ? execArgv.slice() : [];
  const has = argv.some((a) => String(a).includes("termux-preload.js"));
  if (!has) argv.unshift("-r", preloadPath);
  return argv;
}

const RealWorker = workerThreads.Worker;
function HookedWorker(file, opts) {
  const options = Object.assign({}, opts || {});
  const base =
    options.execArgv != null ? options.execArgv : process.execArgv || [];
  options.execArgv = injectPreload(base);
  options.env = Object.assign({}, process.env, options.env || {}, {
    CURSOR_AGENT_VERSION_DIR: versionDir,
  });
  return new RealWorker(file, options);
}
HookedWorker.prototype = RealWorker.prototype;
Object.setPrototypeOf(HookedWorker, RealWorker);
workerThreads.Worker = HookedWorker;

const origFork = cp.fork;
cp.fork = function (modulePath, args, opts) {
  if (opts === undefined && args && !Array.isArray(args)) {
    opts = args;
    args = undefined;
  }
  opts = Object.assign({}, opts || {});
  opts.execArgv = injectPreload(
    opts.execArgv != null ? opts.execArgv : process.execArgv || []
  );
  opts.env = Object.assign({}, process.env, opts.env || {}, {
    CURSOR_AGENT_VERSION_DIR: versionDir,
  });
  return args === undefined
    ? origFork.call(this, modulePath, opts)
    : origFork.call(this, modulePath, args, opts);
};
JS

# --- launcher ---------------------------------------------------------------

cat > "$LAUNCHER" << 'LAUNCH'
#!/data/data/com.termux/files/usr/bin/bash
# cursor-agent — Termux launcher for the official Cursor Agent CLI.
#
# Always bind to the Termux home that owns this launcher, even if invoked from
# a proot-distro where $HOME is /home/<user>.
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
if [ ! -d "$HOME/.local/share/cursor-agent/versions" ]; then
  HOME="${PREFIX:-/data/data/com.termux/files/usr}/../home"
  HOME="$(cd "$HOME" && pwd)"
fi
export HOME
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
export PATH="${HOME}/.local/bin:${PREFIX}/bin:${PATH}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"
export TMPDIR="${TMPDIR:-${HOME}/tmp}"
mkdir -p "$TMPDIR"

ROOT="${HOME}/.local/share/cursor-agent/versions"
PRELOAD="${HOME}/.local/share/cursor-agent/termux-preload.js"

# Prefer the version recorded by the installer; otherwise newest directory.
verified="$(cat "${ROOT}/.verified" 2>/dev/null || true)"
VERSION_DIR=""
if [ -n "$verified" ] && [ -f "${ROOT}/${verified}/index.js" ]; then
  VERSION_DIR="${ROOT}/${verified}"
else
  VERSION_DIR="$(ls -1d "${ROOT}"/* 2>/dev/null | sort | tail -n1 || true)"
fi
[ -n "${VERSION_DIR}" ] && [ -f "${VERSION_DIR}/index.js" ] || {
  echo "[cursor-agent] no installed version under ${ROOT}" >&2
  echo "Re-run: bash install-cursor-termux.sh" >&2
  exit 1
}
[ -f "${PRELOAD}" ] || {
  echo "[cursor-agent] missing termux-preload.js — re-run install-cursor-termux.sh" >&2
  exit 1
}

# If cursor-agent update dropped a fresh tree without our node symlink / patches,
# warn loudly; user must re-run the installer.
if [ -f "${VERSION_DIR}/node" ] && [ ! -L "${VERSION_DIR}/node" ]; then
  echo "[cursor-agent] bundled node is not a Termux symlink — re-run install-cursor-termux.sh" >&2
fi

export CURSOR_AGENT_VERSION_DIR="${VERSION_DIR}"
export NODE_PATH="${VERSION_DIR}/node_modules${NODE_PATH:+:${NODE_PATH}}"
case "${NODE_OPTIONS:-}" in
  *termux-preload.js*) ;;
  *) export NODE_OPTIONS="--require=${PRELOAD}${NODE_OPTIONS:+ ${NODE_OPTIONS}}" ;;
esac

NODE_BIN="${PREFIX}/bin/node"
[ -x "$NODE_BIN" ] || NODE_BIN="$(command -v node)"
exec "$NODE_BIN" -r "${PRELOAD}" "${VERSION_DIR}/index.js" "$@"
LAUNCH
chmod 755 "$LAUNCHER"
chmod 644 "$PRELOAD_DST"

# $PREFIX/bin beats ~/.local/bin so official drop / updates cannot hide us.
ln -sfn "$LAUNCHER" "$BIN_DIR/cursor-agent"
ln -sfn "$LAUNCHER" "$BIN_DIR/agent"
ln -sfn "$LAUNCHER" "$LOCAL_BIN/cursor-agent"
ln -sfn "$LAUNCHER" "$LOCAL_BIN/agent"

# --- PATH -------------------------------------------------------------------

path_has_dir() {
  case ":$PATH:" in *":$1:"*) return 0 ;; *) return 1 ;; esac
}

install_rc_block() {
  local config_file="$1" user_shell="$2"
  [ -n "$config_file" ] || return 0
  mkdir -p "$(dirname "$config_file")"

  local new_block
  case "$user_shell" in
    fish)
      new_block='# >>> cursor-agent termux >>>
fish_add_path $HOME/.local/bin
set -gx LD_LIBRARY_PATH "$PREFIX/lib" $LD_LIBRARY_PATH
set -gx TMPDIR "$HOME/tmp"
alias agent cursor-agent
# <<< cursor-agent termux <<<'
      ;;
    zsh)
      new_block='# >>> cursor-agent termux >>>
# $PREFIX/bin/cursor-agent is the Termux launcher.
export PATH="$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
export TMPDIR="${TMPDIR:-$HOME/tmp}"
alias agent=cursor-agent
# <<< cursor-agent termux <<<'
      ;;
    *)
      new_block='# >>> cursor-agent termux >>>
# $PREFIX/bin/cursor-agent is the Termux launcher.
export PATH="$HOME/.local/bin:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
export TMPDIR="${TMPDIR:-$HOME/tmp}"
alias agent=cursor-agent
# <<< cursor-agent termux <<<'
      ;;
  esac

  if grep -qs "cursor-agent termux" "$config_file" 2>/dev/null; then
    local tmp="$config_file.tmp.$$"
    awk '
      /# >>> cursor-agent termux >>>/ { skip=1; next }
      /# <<< cursor-agent termux <<</ { skip=0; next }
      !skip { print }
    ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
  elif [ -f "$config_file" ]; then
    cp "$config_file" "$config_file.bak.$(date +%s)"
  fi
  # Also strip older cursor-termux marker blocks if present.
  if grep -qs '# --- Cursor Agent (Termux) ---' "$config_file" 2>/dev/null; then
    local tmp2="$config_file.tmp.$$"
    awk '
      $0=="# --- Cursor Agent (Termux) ---" { skip=1; next }
      $0=="# --- end Cursor Agent ---" { skip=0; next }
      !skip { print }
    ' "$config_file" > "$tmp2" && mv "$tmp2" "$config_file"
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

if [ -f "$HOME/.bash_profile" ] && ! grep -qs 'source ~/.bashrc\|\. ~/.bashrc' "$HOME/.bash_profile"; then
  printf '\n[[ -r ~/.bashrc ]] && source ~/.bashrc\n' >> "$HOME/.bash_profile"
fi
if [ -f "$HOME/.profile" ] && ! grep -qs 'bashrc' "$HOME/.profile"; then
  printf '\n[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"\n' >> "$HOME/.profile"
fi

# --- verify -----------------------------------------------------------------

export PATH="$BIN_DIR:$LOCAL_BIN:$PATH"
export LD_LIBRARY_PATH="$PREFIX/lib:${LD_LIBRARY_PATH:-}"
got="$("$BIN_DIR/cursor-agent" --help 2>/dev/null | head -n2 || true)"
[ -n "$got" ] || die "launcher installed but 'cursor-agent --help' produced no output"

info ""
info "Cursor Agent $version installed (Termux / Bionic)."
info "  package : $VERSION_DIR"
info "  launch  : $BIN_DIR/cursor-agent -> $LAUNCHER"
info "  preload : $PRELOAD_DST"
info ""
info "Run:   source ~/.bashrc"
info "Login: NO_OPEN_BROWSER=1 cursor-agent login"
info "Then:  cursor-agent"
info "Update: cursor-agent update   then re-run this installer"
info "Reinstall / pin: bash $0 [YYYY.MM.DD-hash]"
