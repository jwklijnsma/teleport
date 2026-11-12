#!/usr/bin/env bash
#
# Installs the Go / Node.js / Rust toolchains Teleport needs, on an EL8 image
# (rockylinux:8, almalinux:8, ubi8 with repos). Versions are read from the
# checked-out tree, so the same pipeline builds v15 as well as master.
#
# Must be *sourced* from the repository root, so PATH changes reach the job:
#   source ci/setup-toolchain.sh
#
# Override any detected version by setting GOLANG_VERSION / NODE_VERSION /
# RUST_VERSION as CI variables.

set -euo pipefail

VERSIONS_MK=build.assets/versions.mk
# Older release branches keep the versions in build.assets/Makefile instead.
[ -f "$VERSIONS_MK" ] || VERSIONS_MK=build.assets/Makefile

mk_var() {
  sed -n "s/^$1[[:space:]]*?\{0,1\}=[[:space:]]*//p" "$VERSIONS_MK" | head -n1
}

GOLANG_VERSION="${GOLANG_VERSION:-$(mk_var GOLANG_VERSION)}"   # e.g. go1.26.7
NODE_VERSION="${NODE_VERSION:-$(mk_var NODE_VERSION)}"         # e.g. 24.19.0
if [ -z "${RUST_VERSION:-}" ]; then
  if [ -f rust-toolchain.toml ]; then
    RUST_VERSION="$(sed -n 's/^channel[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' rust-toolchain.toml)"
  else
    RUST_VERSION="$(mk_var RUST_VERSION)"
  fi
fi

for v in GOLANG_VERSION NODE_VERSION RUST_VERSION; do
  [ -n "${!v}" ] || { echo "ERROR: could not detect $v, set it as a CI variable" >&2; return 1 2>/dev/null || exit 1; }
done
echo "Toolchain: ${GOLANG_VERSION}, node ${NODE_VERSION}, rust ${RUST_VERSION}"

case "$(uname -m)" in
  x86_64)  GOARCH_DL=amd64; NODE_ARCH=x64 ;;
  aarch64) GOARCH_DL=arm64; NODE_ARCH=arm64 ;;
  *) echo "unsupported arch $(uname -m)" >&2; return 1 2>/dev/null || exit 1 ;;
esac

# --- OS packages -------------------------------------------------------------
# gcc-toolset-12 mirrors the devtoolset-12 used by the upstream buildbox.
# pam-devel enables PAM support; cmake/clang/perl are needed by the Rust
# (boring/ironrdp) parts that back Desktop Access.
dnf -y -q install \
  git make which tar gzip xz zip unzip findutils diffutils ca-certificates \
  gcc gcc-c++ gcc-toolset-12-gcc gcc-toolset-12-gcc-c++ \
  cmake clang llvm perl pkgconf-pkg-config \
  pam-devel openssl-devel python3

set +u
# shellcheck disable=SC1091
source /opt/rh/gcc-toolset-12/enable
set -u

# --- caches (inside the project dir so GitLab can cache them) ----------------
CACHE_DIR="${CI_PROJECT_DIR:-$PWD}/.cache"
export GOMODCACHE="$CACHE_DIR/go-mod"
export CARGO_HOME="$CACHE_DIR/cargo"
export RUSTUP_HOME=/usr/local/rustup
export npm_config_store_dir="$CACHE_DIR/pnpm-store"   # pnpm (v16+)
export YARN_CACHE_FOLDER="$CACHE_DIR/yarn"            # yarn (v15)
mkdir -p "$GOMODCACHE" "$CARGO_HOME" "$npm_config_store_dir" "$YARN_CACHE_FOLDER"

# --- Go ----------------------------------------------------------------------
curl -fsSL "https://go.dev/dl/${GOLANG_VERSION}.linux-${GOARCH_DL}.tar.gz" | tar -C /usr/local -xz
export PATH="/usr/local/go/bin:$PATH"
export GOTOOLCHAIN=local GOFLAGS=-buildvcs=false

# --- Node.js + corepack (pnpm / yarn) ----------------------------------------
mkdir -p /usr/local/node
curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
  | tar -C /usr/local/node -xJ --strip-components=1
export PATH="/usr/local/node/bin:$PATH"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
# The corepack bundled with older Node.js releases (e.g. 20.18.0, used by v17)
# only knows npm registry signing keys that have since been rotated, and dies
# with "Cannot find matching keyid" when it fetches pnpm. Use a current one.
if npm install -g --force --engine-strict corepack@latest >/dev/null 2>&1; then
  echo "corepack $(corepack --version)"
else
  echo "Could not upgrade corepack on node ${NODE_VERSION}; disabling its signature check"
  export COREPACK_INTEGRITY_KEYS=0
fi
corepack enable

# --- Rust ----------------------------------------------------------------------
curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs \
  | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
export PATH="$CARGO_HOME/bin:$PATH"
rustup target add wasm32-unknown-unknown

# --- wasm-pack (v15 - v17 only) ----------------------------------------------
# Those release lines build the web UI's Rust/WASM part with wasm-pack, which
# upstream bakes into its buildbox image instead of installing it from the
# Makefile. Newer trees do not define WASM_PACK_VERSION and need nothing here.
WASM_PACK_VERSION="${WASM_PACK_VERSION:-$(mk_var WASM_PACK_VERSION)}"
if [ -n "$WASM_PACK_VERSION" ]; then
  if [ "$(wasm-pack --version 2>/dev/null || true)" != "wasm-pack ${WASM_PACK_VERSION}" ]; then
    wp="wasm-pack-v${WASM_PACK_VERSION}-$(uname -m)-unknown-linux-musl"
    mkdir -p "$CARGO_HOME/bin"
    if curl -fsSL "https://github.com/rustwasm/wasm-pack/releases/download/v${WASM_PACK_VERSION}/${wp}.tar.gz" \
         | tar -xz -C "$CARGO_HOME/bin" --strip-components=1 "${wp}/wasm-pack"; then
      echo "Installed prebuilt wasm-pack ${WASM_PACK_VERSION}"
    else
      echo "No prebuilt wasm-pack ${WASM_PACK_VERSION}, building it with cargo"
      cargo install wasm-pack --locked --version "$WASM_PACK_VERSION"
    fi
  fi
  wasm-pack --version
fi

git config --global --add safe.directory "${CI_PROJECT_DIR:-$PWD}"

go version
node --version
rustc --version
gcc --version | head -n1

# Do not leak nounset into the rest of the CI job's shell.
set +u
