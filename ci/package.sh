#!/usr/bin/env bash
#
# Builds teleport .rpm and .deb packages from a release tarball with fpm.
# This is build.assets/build-package.sh without the "docker run": it runs fpm
# directly, so it works on runners that have no Docker daemon.
#
# Usage: ci/package.sh <version> <tarball> <output dir>
#
# Optional environment:
#   TELEPORT_SRC        path of the Teleport source tree (default: this repo)
#   PKG_ARCH            amd64 (default) | arm64
#   PKG_VENDOR / PKG_MAINTAINER / PKG_LICENSE
#   RPM_GPG_PRIVATE_KEY ASCII-armoured private key (or a path to one) - signs the RPM
#   RPM_GPG_PASSPHRASE  passphrase for that key, if it has one

set -euo pipefail

VERSION="${1:?version}"
TARBALL="$(readlink -f "${2:?tarball}")"
OUT_DIR="${3:?output dir}"
# TELEPORT_SRC: Teleport source tree, when it is not the repo this script lives in.
REPO_ROOT="${TELEPORT_SRC:-$(cd "$(dirname "$0")/.." && pwd -P)}"

ARCH="${PKG_ARCH:-amd64}"
case "$ARCH" in
  amd64) RPM_ARCH=x86_64;  TEXT_ARCH="64-bit x86" ;;
  arm64) RPM_ARCH=aarch64; TEXT_ARCH="64-bit ARM" ;;
  *) echo "unsupported PKG_ARCH: $ARCH" >&2; exit 1 ;;
esac

if [ -z "${PKG_LICENSE:-}" ]; then
  if grep -qi 'GNU AFFERO GENERAL PUBLIC LICENSE' "$REPO_ROOT/LICENSE" 2>/dev/null; then
    PKG_LICENSE="AGPL-3.0-only"
  else
    PKG_LICENSE="Apache-2.0"
  fi
fi
VENDOR="${PKG_VENDOR:-${CI_PROJECT_NAMESPACE:-self-built}}"
MAINTAINER="${PKG_MAINTAINER:-ci@${CI_SERVER_HOST:-localhost}}"
URL="${CI_PROJECT_URL:-https://github.com/gravitational/teleport}"
DESCRIPTION="Teleport provides on-demand, least-privileged access to your infrastructure [${TEXT_ARCH}, built from source, ${PKG_LICENSE}]"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT_DIR"
OUT_DIR="$(readlink -f "$OUT_DIR")"

tar -C "$WORK" -xzf "$TARBALL"
SRC="$WORK/teleport"
ROOT="$WORK/buildroot"
SYSTEMD_SRC="$SRC/examples/systemd"

# Newer trees install into /opt/teleport/system and let the post-install script
# (teleport-update link-package) create the /usr/local/bin symlinks. Older trees
# have no such script and install straight into /usr/local/bin.
SCRIPT_ARGS_RPM=()
SCRIPT_ARGS_DEB=()
# The tree's own build-package.sh is the reference: Dockerfile-distroless
# expects the same layout inside the .deb.
if grep -q '^LINUX_BINARY_DIR=/opt/teleport/system/bin' "$REPO_ROOT/build.assets/build-package.sh" 2>/dev/null \
   || { [ -f "$SYSTEMD_SRC/post-install" ] && [ -f "$SRC/teleport-update" ]; }; then
  BIN_DIR=/opt/teleport/system/bin
  UNIT_DIR=/opt/teleport/system/lib/systemd/system
  cp "$SYSTEMD_SRC/post-install" "$SYSTEMD_SRC/before-remove" "$WORK/"
  # RPM runs "after install" before the old package is removed, hence posttrans.
  SCRIPT_ARGS_RPM=(--rpm-posttrans "$WORK/post-install" --before-remove "$WORK/before-remove")
  SCRIPT_ARGS_DEB=(--after-install "$WORK/post-install" --before-remove "$WORK/before-remove")
else
  BIN_DIR=/usr/local/bin
  UNIT_DIR=/lib/systemd/system
fi

mkdir -p "$ROOT$BIN_DIR" "$ROOT$UNIT_DIR"
mkdir -p "$ROOT/var/lib/teleport"
chmod 0700 "$ROOT/var/lib/teleport"
found=0
for bin in teleport tctl tsh tbot fdpass-teleport teleport-update; do
  if [ -f "$SRC/$bin" ]; then
    install -m0755 "$SRC/$bin" "$ROOT$BIN_DIR/$bin"
    found=$((found + 1))
  fi
done
[ -f "$ROOT$BIN_DIR/teleport" ] || { echo "no teleport binary in $TARBALL" >&2; exit 1; }
echo "Packaging $found binaries into $BIN_DIR"
install -m0644 "$SYSTEMD_SRC/teleport.service" "$ROOT$UNIT_DIR/teleport.service"

# Suppress /usr/lib/.build-id links (gravitational/teleport#7040).
if [ -f "$REPO_ROOT/build.assets/rpm/rpmmacros" ]; then
  cp "$REPO_ROOT/build.assets/rpm/rpmmacros" "$HOME/.rpmmacros"
else
  echo '%_build_id_links none' > "$HOME/.rpmmacros"
fi

COMMON=(
  --input-type dir
  --name teleport
  --version "$VERSION"
  --maintainer "$MAINTAINER"
  --url "$URL"
  --vendor "$VENDOR"
  --license "$PKG_LICENSE"
  --description "$DESCRIPTION"
  --chdir "$ROOT"
  --directories /var/lib/teleport
  --provides teleport
  --prefix /
)

RPM_FILE="$OUT_DIR/teleport-${VERSION}-1.${RPM_ARCH}.rpm"
DEB_FILE="$OUT_DIR/teleport_${VERSION}_${ARCH}.deb"
rm -f "$RPM_FILE" "$DEB_FILE"

# sha256 digests instead of fpm's md5 default: md5 packages do not install on
# FIPS-mode RHEL hosts.
fpm "${COMMON[@]}" --output-type rpm \
  --architecture "$RPM_ARCH" \
  --rpm-user root --rpm-group root --rpm-use-file-permissions \
  --rpm-digest sha256 \
  "${SCRIPT_ARGS_RPM[@]}" \
  --package "$RPM_FILE" .

# The .deb is what build.assets/charts/Dockerfile-distroless consumes.
mkdir -p "$ROOT/etc/needrestart/conf.d"
# shellcheck disable=SC2016 # $nrconf is perl, not shell
printf '# necessary for needrestart before 3.9\npush(@{$nrconf{blacklist}}, qr(^/memfd:teleport-));\n' \
  > "$ROOT/etc/needrestart/conf.d/teleport.conf"
fpm "${COMMON[@]}" --output-type deb \
  --architecture "$ARCH" \
  --deb-user root --deb-group root \
  "${SCRIPT_ARGS_DEB[@]}" \
  --package "$DEB_FILE" .

# --- optional RPM signing -----------------------------------------------------
if [ -n "${RPM_GPG_PRIVATE_KEY:-}" ]; then
  export GNUPGHOME="$WORK/gnupg"
  mkdir -m0700 "$GNUPGHOME"
  if [ -f "$RPM_GPG_PRIVATE_KEY" ]; then
    gpg --batch --quiet --import "$RPM_GPG_PRIVATE_KEY"
  else
    gpg --batch --quiet --import <<<"$RPM_GPG_PRIVATE_KEY"
  fi
  KEY_ID="$(gpg --batch --list-secret-keys --with-colons | awk -F: '$1 == "sec" { print $5; exit }')"
  SIGN_ARGS="--batch --pinentry-mode loopback"
  if [ -n "${RPM_GPG_PASSPHRASE:-}" ]; then
    (umask 077; printf '%s' "$RPM_GPG_PASSPHRASE" > "$WORK/passphrase")
    SIGN_ARGS="$SIGN_ARGS --passphrase-file $WORK/passphrase"
  fi
  rpm --define "_gpg_name $KEY_ID" \
      --define "_gpg_digest_algo sha256" \
      --define "_gpg_sign_cmd_extra_args $SIGN_ARGS" \
      --addsign "$RPM_FILE"
  gpg --batch --armor --export "$KEY_ID" > "$OUT_DIR/RPM-GPG-KEY-teleport"
  echo "Signed $(basename "$RPM_FILE") with key $KEY_ID"
else
  echo "RPM_GPG_PRIVATE_KEY not set: RPM is unsigned"
fi

(cd "$OUT_DIR" && for f in *.rpm *.deb; do sha256sum "$f" > "$f.sha256"; done)
ls -lh "$OUT_DIR"
