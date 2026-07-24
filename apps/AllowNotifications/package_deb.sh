#!/usr/bin/env bash
# Package AllowNotifications as Bootstrap/RootHide (iphoneos-arm64) .deb
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/AllowNotifications"
DIST_DIR="$ROOT_DIR/dist"
DYLIB="$DIST_DIR/AllowNotifications.dylib"

if [[ ! -f "$DYLIB" ]]; then
  echo "ERROR: missing $DYLIB" >&2
  exit 1
fi

PKG_ID="byg.iosios.net.ghallownotifications-rootless"
VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$APP_DIR/control" | tr -d '\r')"
ARCH="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$APP_DIR/control" | tr -d '\r')"
DEB_NAME="${PKG_ID}_${VERSION}_${ARCH}.deb"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ROOTFS="$WORKDIR/root"
mkdir -p "$ROOTFS/DEBIAN"
mkdir -p "$ROOTFS/var/jb/Library/MobileSubstrate/DynamicLibraries"

# Payload
cp -f "$DYLIB" "$ROOTFS/var/jb/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.dylib"
cp -f "$APP_DIR/AllowNotifications.plist" "$ROOTFS/var/jb/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.plist"

# Scripts
cp -f "$APP_DIR/control" "$ROOTFS/DEBIAN/control"
cp -f "$APP_DIR/postinst" "$ROOTFS/DEBIAN/postinst"
cp -f "$APP_DIR/postrm" "$ROOTFS/DEBIAN/postrm"
chmod 0755 "$ROOTFS/DEBIAN/postinst" "$ROOTFS/DEBIAN/postrm"

# Installed-Size (KiB)
SIZE_KB=$(du -sk "$ROOTFS/var" | awk '{print $1}')
if grep -q '^Installed-Size:' "$ROOTFS/DEBIAN/control"; then
  sed -i.bak "s/^Installed-Size:.*/Installed-Size: ${SIZE_KB}/" "$ROOTFS/DEBIAN/control" && rm -f "$ROOTFS/DEBIAN/control.bak"
else
  printf '\nInstalled-Size: %s\n' "$SIZE_KB" >> "$ROOTFS/DEBIAN/control"
fi
# ensure trailing newline
perl -pi -e 'chomp if eof' "$ROOTFS/DEBIAN/control" 2>/dev/null || true
echo >> "$ROOTFS/DEBIAN/control"

# Prefer dpkg-deb when available
OUT="$DIST_DIR/$DEB_NAME"
mkdir -p "$DIST_DIR"
if command -v dpkg-deb >/dev/null 2>&1; then
  dpkg-deb -b -Zgzip "$ROOTFS" "$OUT"
else
  # Manual ar/tar deb (gzip)
  (
    cd "$ROOTFS/DEBIAN"
    tar --format=ustar -czf "$WORKDIR/control.tar.gz" .
  )
  (
    cd "$ROOTFS"
    tar --format=ustar -czf "$WORKDIR/data.tar.gz" \
      --exclude='./DEBIAN' \
      --exclude='./DEBIAN/*' \
      ./var
  )
  printf '2.0\n' > "$WORKDIR/debian-binary"
  rm -f "$OUT"
  (
    cd "$WORKDIR"
    ar r "$OUT" debian-binary control.tar.gz data.tar.gz
  )
fi

ls -lh "$OUT"
file "$OUT" || true
echo "PACKAGED=$OUT"