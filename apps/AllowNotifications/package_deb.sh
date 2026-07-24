#!/usr/bin/env bash
# Package AllowNotifications as Bootstrap / RootHide .deb
# RootHide package rules (from roothide/theos):
#   Architecture: iphoneos-arm64e
#   Layout: rootful-looking paths (NO /var/jb). dpkg installs into jbroot.
#   Example: /Library/MobileSubstrate/DynamicLibraries/*.dylib
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
APP_DIR="$ROOT_DIR/apps/AllowNotifications"
DIST_DIR="$ROOT_DIR/dist"
DYLIB="$DIST_DIR/AllowNotifications.dylib"

if [[ ! -f "$DYLIB" ]]; then
  echo "ERROR: missing $DYLIB" >&2
  exit 1
fi

PKG_ID="$(awk -F': ' '/^Package:/{print $2; exit}' "$APP_DIR/control" | tr -d '\r')"
VERSION="$(awk -F': ' '/^Version:/{print $2; exit}' "$APP_DIR/control" | tr -d '\r')"
ARCH="$(awk -F': ' '/^Architecture:/{print $2; exit}' "$APP_DIR/control" | tr -d '\r')"
if [[ "$ARCH" != "iphoneos-arm64e" ]]; then
  echo "WARN: forcing Architecture iphoneos-arm64e for Bootstrap/RootHide (was $ARCH)"
  ARCH="iphoneos-arm64e"
fi
DEB_NAME="${PKG_ID}_${VERSION}_${ARCH}.deb"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

ROOTFS="$WORKDIR/root"
mkdir -p "$ROOTFS/DEBIAN"
# RootHide: NO /var/jb prefix. Install into jbroot as rootful paths.
mkdir -p "$ROOTFS/Library/MobileSubstrate/DynamicLibraries"

cp -f "$DYLIB" "$ROOTFS/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.dylib"
cp -f "$APP_DIR/AllowNotifications.plist" "$ROOTFS/Library/MobileSubstrate/DynamicLibraries/AllowNotifications.plist"

# control (force arch field)
awk -v arch="$ARCH" '
  BEGIN{done=0}
  /^Architecture:/{print "Architecture: " arch; done=1; next}
  {print}
  END{if(!done) print "Architecture: " arch}
' "$APP_DIR/control" | tr -d '\r' > "$ROOTFS/DEBIAN/control"

cp -f "$APP_DIR/postinst" "$ROOTFS/DEBIAN/postinst"
cp -f "$APP_DIR/postrm" "$ROOTFS/DEBIAN/postrm"
chmod 0755 "$ROOTFS/DEBIAN/postinst" "$ROOTFS/DEBIAN/postrm"

SIZE_KB=$(du -sk "$ROOTFS/Library" | awk '{print $1}')
if grep -q '^Installed-Size:' "$ROOTFS/DEBIAN/control"; then
  if sed --version >/dev/null 2>&1; then
    sed -i "s/^Installed-Size:.*/Installed-Size: ${SIZE_KB}/" "$ROOTFS/DEBIAN/control"
  else
    sed -i.bak "s/^Installed-Size:.*/Installed-Size: ${SIZE_KB}/" "$ROOTFS/DEBIAN/control"
    rm -f "$ROOTFS/DEBIAN/control.bak"
  fi
else
  printf 'Installed-Size: %s\n' "$SIZE_KB" >> "$ROOTFS/DEBIAN/control"
fi
# ensure final newline
[[ -n "$(tail -c1 "$ROOTFS/DEBIAN/control")" ]] && echo >> "$ROOTFS/DEBIAN/control"

OUT="$DIST_DIR/$DEB_NAME"
mkdir -p "$DIST_DIR"

# Build deb. Prefer dpkg-deb; fallback to ar/tar.
if command -v dpkg-deb >/dev/null 2>&1; then
  # xz matches many RootHide packages; gzip also accepted
  if dpkg-deb -Zxz -b "$ROOTFS" "$OUT" 2>/dev/null; then
    :
  else
    dpkg-deb -Zgzip -b "$ROOTFS" "$OUT"
  fi
else
  (
    cd "$ROOTFS/DEBIAN"
    if command -v xz >/dev/null 2>&1; then
      tar --format=ustar -cf - . | xz -z9 > "$WORKDIR/control.tar.xz"
      CT=control.tar.xz
    else
      tar --format=ustar -czf "$WORKDIR/control.tar.gz" .
      CT=control.tar.gz
    fi
    echo "$CT" > "$WORKDIR/ct_name"
  )
  (
    cd "$ROOTFS"
    if command -v xz >/dev/null 2>&1; then
      tar --format=ustar -cf - ./Library | xz -z9 > "$WORKDIR/data.tar.xz"
      DT=data.tar.xz
    else
      tar --format=ustar -czf "$WORKDIR/data.tar.gz" ./Library
      DT=data.tar.gz
    fi
    echo "$DT" > "$WORKDIR/dt_name"
  )
  CT=$(cat "$WORKDIR/ct_name")
  DT=$(cat "$WORKDIR/dt_name")
  printf '2.0\n' > "$WORKDIR/debian-binary"
  rm -f "$OUT"
  (
    cd "$WORKDIR"
    ar r "$OUT" debian-binary "$CT" "$DT"
  )
fi

ls -lh "$OUT"
file "$OUT" || true
echo "PACKAGED=$OUT"
echo "FORMAT=Bootstrap/RootHide"
echo "ARCH=$ARCH"
echo "LAYOUT=/Library/MobileSubstrate/DynamicLibraries (no /var/jb)"