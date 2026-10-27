#!/bin/bash
# Runs as root inside the privileged build container: loop-mount the ext4
# build image at /build, then drop to the unprivileged "docker" user (the
# CoreELEC build system refuses to run as root).
set -e

IMG=/host/build.img

if [ ! -f "$IMG" ]; then
  echo "entrypoint: $IMG missing - run 'cebuild setup' first" >&2
  exit 1
fi

# A privileged container's /dev is a snapshot; make sure loop nodes exist.
[ -e /dev/loop-control ] || mknod /dev/loop-control c 10 237
for i in $(seq 0 15); do
  [ -e /dev/loop$i ] || mknod /dev/loop$i b 7 $i
done

mkdir -p /build
e2fsck -p "$IMG" >/dev/null 2>&1 || true
mount -o loop,noatime "$IMG" /build
chown docker:docker /build

cleanup() {
  sync
  umount /build 2>/dev/null || umount -l /build 2>/dev/null || true
}
trap cleanup EXIT

cd /build
[ -d /build/CoreELEC ] && cd /build/CoreELEC

if [ $# -eq 0 ]; then
  set -- bash -l
fi

# not exec: the EXIT trap has to run to unmount cleanly
sudo -E -H -u docker -- env PATH="$PATH" "$@"
