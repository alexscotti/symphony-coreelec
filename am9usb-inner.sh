#!/bin/bash
# Runs as root inside the cebuild container (am9usb make). Works on the ext4
# build volume, not on /host: loop-mounting a file that sits on the Mac's
# virtiofs share is slow and the intermediate image is throwaway anyway.
set -euo pipefail

IMG_GZ="$1"; RESOLUTION="$2"; OUT_GZ="$3"; DTB="$4"; GROW_MB="$5"; BUNDLE="$6"; DTBFILE="${7:-}"

W=/build/usb
rm -rf "$W"; mkdir -p "$W/mnt" "$W/bundle"
IMG="$W/work.img"

cleanup() { mountpoint -q "$W/mnt" && umount "$W/mnt"; [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null; true; }
trap cleanup EXIT

echo "== unpacking image and bundle"
pigz -dc "$IMG_GZ" > "$IMG"
tar xf "$BUNDLE" -C "$W/bundle"

# Partition geometry straight from the table - never hardcoded.
read -r P1_START P1_SIZE < <(sfdisk -d "$IMG" | awk -F'[=,]' '/img1 :/{print $2+0, $4+0}')
read -r P2_START          < <(sfdisk -d "$IMG" | awk -F'[=,]' '/img2 :/{print $2+0}')
[ -n "$P1_START" ] && [ -n "$P2_START" ] || { echo "cannot read partition table" >&2; exit 1; }
FAT="$IMG@@$((P1_START*512))"

if [ -n "$DTBFILE" ]; then DTBSRC="the AM9_DTB_FILE override"; else DTBSRC="device_trees/$DTB"; fi
echo "== /flash: dtb.img <- $DTBSRC, slot A from the bundle, resolution.ini"
# dtb.img normally comes from THIS build's device_trees, never from the box: it
# has to match the kernel it boots. AM9_DTB_FILE overrides it with a file, for
# a dtb the box is known to boot - the stick is never mounted after writing, so
# this is the only chance to put one in.
if [ -n "$DTBFILE" ]; then
  cp "$DTBFILE" "$W/dtb.img"
else
  mcopy -i "$FAT" "::device_trees/$DTB" "$W/dtb.img" \
    || { echo "no device_trees/$DTB in this image" >&2; exit 1; }
fi
mcopy -o -i "$FAT" "$W/dtb.img" ::dtb.img

# A/B slots (see am9slot.sh): the image's plain kernel.img + SYSTEM become
# slot A, taken from the bundle - the same artifact a live install uses - after
# checking it IS this image's build. Slot B starts empty; slot.ini selects A.
# No dovi_<slot>.ko: Amlogic's module is in no image and no git tree, and the
# box captures it from a USB stick at boot (the image's symphony-dovi).
mcopy -i "$FAT" ::SYSTEM "$W/gen.SYSTEM"; mcopy -i "$FAT" ::kernel.img "$W/gen.kernel"
cmp -s "$W/gen.SYSTEM" "$W/bundle/SYSTEM" && cmp -s "$W/gen.kernel" "$W/bundle/kernel.img" \
  || { echo "the bundle is not this image's build (SYSTEM/kernel differ)" >&2; exit 1; }
rm -f "$W/gen.SYSTEM" "$W/gen.kernel"
need=$(( 2 * ( $(stat -c%s "$W/bundle/SYSTEM") + $(stat -c%s "$W/bundle/kernel.img") ) ))
[ $((P1_SIZE * 512)) -gt $((need + 64*1024*1024)) ] \
  || { echo "boot FAT is $((P1_SIZE/2048))M - too small for two slots (need $((need/1048576))M + 64M); build with SYSTEM_SIZE=1536" >&2; exit 1; }
for f in kernel.img kernel.img.md5 SYSTEM SYSTEM.md5 dovi.ko; do mdel -i "$FAT" "::$f" 2>/dev/null || true; done
mcopy -i "$FAT" "$W/bundle/kernel.img" ::kernel_A.img
mcopy -i "$FAT" "$W/bundle/SYSTEM"     ::SYSTEM_A
mcopy -i "$FAT" "$W/bundle/MANIFEST"   ::SLOT_A.manifest
# The installer, for the box's web page (status, goback); installs refresh it.
[ -f "$W/bundle/am9slot.sh" ] && mcopy -i "$FAT" "$W/bundle/am9slot.sh" ::am9slot.sh
printf 'ceslot=A\n' > "$W/slot.ini"; mcopy -i "$FAT" "$W/slot.ini" ::slot.ini
echo "   slot A: $(sed -n 's/^VERSION=//p' "$W/bundle/MANIFEST") ($(sed -n 's/^COREELEC_VERSION=//p' "$W/bundle/MANIFEST"))"
# config.ini is the build's own now (the fork sets keymap='us' in it, the
# only line the old seed's copy changed). resolution.ini is this repo's:
# u-boot imports it as env and it sets the early HDMI mode.
mcopy -o -i "$FAT" "$RESOLUTION" ::resolution.ini

echo "== /storage: sizing partition 2 to +${GROW_MB}M"
# The stock STORAGE partition is 32M - the JRE alone is ~110M - so STORAGE has
# to be sized HERE, at image time. The box will not do it for us, and must not
# try: CoreELEC's fs-resize runs
#
#   parted resizepart 2 100% && mke2fs -F -q -t ext4 ... $PART
#
# which would destroy everything we put there. It declines on a populated
# stick anyway
# ("Resizing is not permitted - the system has already been initialised",
# measured), so the marker only ever sits there as a hazard waiting for that
# check to pass. Remove it below and size STORAGE properly up front - which
# means recreating the filesystem exactly as fs-resize would, not growing it.
truncate -s "+${GROW_MB}M" "$IMG"
parted -s "$IMG" resizepart 2 100%
LOOP="$(losetup -f --show -o $((P2_START*512)) "$IMG")"

# RECREATE the filesystem, do not grow it. The stock STORAGE partition is 32M,
# where mke2fs picks a 1K block size; resize2fs preserves that, so growing it
# to 4G leaves a 4G filesystem built from 1K blocks with ~1M inodes. On USB
# flash that is catastrophic write amplification - measured on the AM9 Pro at
# 592 KB/s for a 20M write, with the box sitting at 52% iowait. Every BD-J menu
# resource goes through libbluray's VFS cache on /storage, so menus could not
# finish loading and Kodi sat on its busy dialog forever.
#
# CoreELEC's own fs-resize does exactly this (mke2fs -F -q -t ext4 -m 0 -L -U),
# which is why a box that resized itself on first boot is fast. Keep the label
# and UUID: the kernel boots with disk=LABEL=STORAGE.
LABEL="$(tune2fs -l "$LOOP" | sed -n 's/^Filesystem volume name: *//p')"
UUID="$(tune2fs -l "$LOOP" | sed -n 's/^Filesystem UUID: *//p')"
[ -n "$LABEL" ] || { echo "cannot read STORAGE label" >&2; exit 1; }
echo "   recreating ext4 (was $(tune2fs -l "$LOOP" | sed -n 's/^Block size: *//p')-byte blocks) label=$LABEL"
mke2fs -F -q -t ext4 -m 0 -L "$LABEL" -U "$UUID" "$LOOP"
echo "   now $(tune2fs -l "$LOOP" | sed -n 's/^Block size: *//p')-byte blocks"
mount "$LOOP" "$W/mnt"
# The bundle's extension (if it has one) for slot A's version, where
# am9slot.sh puts it on a live install (/storage/.extra/<version>), with its
# install step run against this /storage.
if [ -f "$W/bundle/extra.tar" ]; then
  ver="$(sed -n 's/^VERSION=//p' "$W/bundle/MANIFEST")"
  rm -rf "$W/mnt/.extra"; mkdir -p "$W/mnt/.extra/$ver"
  tar xf "$W/bundle/extra.tar" -C "$W/mnt/.extra/$ver"
  if [ -f "$W/mnt/.extra/$ver/install" ]; then
    sh "$W/mnt/.extra/$ver/install" "$W/mnt" "$ver" >/dev/null
  fi
  echo "   extension $ver installed"
fi

# See above: a first-boot resize would mke2fs the partition we just wrote.
rm -f "$W/mnt/.please_resize_me"
sync
df -h "$W/mnt" | tail -1
umount "$W/mnt"
e2fsck -fy "$LOOP" >/dev/null || [ $? -le 1 ]
losetup -d "$LOOP"; LOOP=""

echo "== verifying"
mdir -i "$FAT" ::
# config.ini is the build's own, and two lines in it matter enough to assert:
# keymap, and coreelec='ssh' - sshd's kernel-command-line switch, which is what
# keeps SSH independent of anything on /storage. A stick that boots without it
# and then has /storage cleared (am9slot.sh wipe-storage, or a factory reset)
# can end up with no way in. It is cheaper to fail here than to find out from a
# box that will not answer.
for want in "keymap='us'" "coreelec='ssh'"; do
  mtype -i "$FAT" ::config.ini | grep -qx "$want" \
    || { echo "config.ini on the stick has no $want - refusing to ship it" >&2; exit 1; }
  echo "   config.ini: $want"
done
cmp <(mtype -i "$FAT" ::dtb.img) "$W/dtb.img"
cmp <(mtype -i "$FAT" ::kernel_A.img) "$W/bundle/kernel.img"
cmp <(mtype -i "$FAT" ::SYSTEM_A) "$W/bundle/SYSTEM"
cmp <(mtype -i "$FAT" ::SLOT_A.manifest) "$W/bundle/MANIFEST"
[ -f "$W/bundle/am9slot.sh" ] && cmp <(mtype -i "$FAT" ::am9slot.sh) "$W/bundle/am9slot.sh"
if mdir -i "$FAT" ::kernel.img >/dev/null 2>&1 || mdir -i "$FAT" ::SYSTEM >/dev/null 2>&1; then
  echo "plain kernel.img/SYSTEM still on the FAT" >&2; exit 1
fi
sfdisk -d "$IMG" | grep 'img[12] :'

# Record the UNCOMPRESSED size next to the image. gzip's ISIZE trailer is
# 32-bit, so anything over 4G wraps undetectably and a writer cannot work the
# size out for itself; a writer can read this sidecar for its progress.
stat -c%s "$IMG" > "${OUT_GZ%.gz}.size" 2>/dev/null || stat -f%z "$IMG" > "${OUT_GZ%.gz}.size"

echo "== compressing -> $OUT_GZ"
pigz -c "$IMG" > "$OUT_GZ.part"
mv "$OUT_GZ.part" "$OUT_GZ"
rm -rf "$W"
