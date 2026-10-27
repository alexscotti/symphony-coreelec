#!/bin/sh
# am9slot.sh - A/B slot installer, run ON the AM9 Pro (busybox sh). am9usb
# pushes it over ssh for every run; it is never installed on the box.
#
# Slot stick layout, all at the root of the boot FAT (/flash):
#   kernel_A.img SYSTEM_A SLOT_A.manifest   (same for B)
#   slot.ini     ceslot=A|B - which slot cfgload boots (missing/garbage -> A)
#   dtb.img config.ini resolution.ini cfgload ...      shared
#
# A slot is valid only while its SLOT_x.manifest exists and its files match
# the sha256s in it. install removes the manifest FIRST, writes, re-reads the
# files from the device and verifies, writes the manifest, and only then
# points slot.ini at it. Any failure before the last step leaves slot.ini on
# the running slot.
#
#   am9slot.sh status
#   am9slot.sh install <dir>   <dir> holds kernel.img SYSTEM MANIFEST
#                              (and am9slot.sh: copied to /flash/am9slot.sh;
#                              extra.tar: an optional extension, see below)
#   am9slot.sh goback          boot the other (verified) slot next time
#   am9slot.sh wipe-storage    put /storage back to what a freshly written
#                              stick has on it, for testing an image's own
#                              first-boot behaviour without burning one
#
# The extension (extra.tar, optional; extra_sha256 in the MANIFEST) is how a
# build adds its own software to /storage, which no slot install touches.
# install unpacks it to /storage/.extra/<VERSION>/ and may run three files
# from it, all optional:
#   install <storage> <version>   run when it is unpacked, before the slot is
#                                 written (a failure leaves the slot alone)
#   pre-install <storage>         run from the RUNNING slot's extension before
#                                 a new slot is written (a backup, say); a
#                                 failure is a warning
#   keep                          paths under /storage, one per line, that
#                                 wipe-storage keeps (the extension of the
#                                 slot that boots next is the one read)
#   status <storage>              key=value lines about itself, which
#                                 am9usb status prints (the running slot's)
# /storage/.extra keeps only the two slots' extensions.
set -u

# AM9SLOT_TEST=1 (tests/test_am9slot.sh only): flash dir, cmdline and Kodi's
# answer come from the environment; no remount, no cache drop.
F="${AM9SLOT_FLASH:-/flash}"
S="${AM9SLOT_STORAGE:-/storage}"
X="$S/.extra"
CMDLINE="${AM9SLOT_CMDLINE:-/proc/cmdline}"
TEST="${AM9SLOT_TEST:-}"

die() { echo "am9slot: $*" >&2; exit 1; }

running_slot() {
  local a s=""
  for a in $(cat "$CMDLINE"); do
    case "$a" in SYSTEM_IMAGE=*SYSTEM_[AB]) s="${a##*_}" ;; esac
  done
  echo "$s"
}

selected_slot() {
  local s
  s="$(sed -n 's/^ceslot=//p' "$F/slot.ini" 2>/dev/null | tr -d '\r ' | tail -1)"
  [ "$s" = "B" ] && echo B || echo A
}

other() { [ "$1" = "A" ] && echo B || echo A; }

mval() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }

# verify_slot <slot>: its manifest exists and every file matches it.
verify_slot() {
  local s="$1" m="$F/SLOT_$1.manifest" f want got
  [ -f "$m" ] || { echo "slot $s: no manifest"; return 1; }
  for f in kernel SYSTEM; do
    want="$(mval "$m" "${f}_sha256")"
    case $f in kernel) p="$F/kernel_$s.img" ;; SYSTEM) p="$F/SYSTEM_$s" ;; esac
    [ -n "$want" ] || { echo "slot $s: manifest has no ${f}_sha256"; return 1; }
    [ -f "$p" ] || { echo "slot $s: $p missing"; return 1; }
    got="$(sha256sum "$p" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || { echo "slot $s: $p sha256 $got != manifest $want"; return 1; }
  done
  return 0
}

# kodi_playing: 0 playing, 1 not, 2 cannot tell. Asked over Kodi's TCP
# JSON-RPC (127.0.0.1:9090, no credentials), which runs whenever the
# EventServer is enabled - Kodi's default. Not the web server: it is off by
# default, and its password lives in guisettings.xml. The TCP server pushes
# notifications on the same socket, so read objects until the reply to id 1.
kodi_playing() {
  if [ -n "$TEST" ]; then
    case "${AM9SLOT_KODI:-idle}" in playing) return 0 ;; idle) return 1 ;; *) return 2 ;; esac
  fi
  local out
  out="$(python3 -c '
import json, socket, sys
s = socket.create_connection(("127.0.0.1", 9090), 5)
s.settimeout(5)
s.sendall(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"Player.GetActivePlayers\"}")
dec, buf = json.JSONDecoder(), ""
while True:
    chunk = s.recv(65536)
    if not chunk:
        sys.exit(1)
    buf += chunk.decode("utf-8", "replace")
    while True:
        buf = buf.lstrip()
        try:
            msg, end = dec.raw_decode(buf)
        except ValueError:
            break
        buf = buf[end:]
        if isinstance(msg, dict) and msg.get("id") == 1:
            r = msg.get("result")
            if not isinstance(r, list):
                sys.exit(1)
            print("playing" if r else "idle")
            sys.exit(0)
' 2>/dev/null)" || return 2
  case "$out" in
    idle)    return 1 ;;
    playing) return 0 ;;
    *)       return 2 ;;
  esac
}

# keep_list <version>: the extension's keep file, one clean relative path per
# line (no blanks, comments, absolute paths or ..).
keep_list() {
  local k="$X/$1/keep" line
  [ -n "$1" ] && [ -f "$k" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="$(echo "$line" | sed 's|^ *||; s| *$||; s|/*$||')"
    case "$line" in ''|/*|..|../*|*/../*|*/..) continue ;; esac
    echo "$line"
  done < "$k"
}

# prune_extra: /storage/.extra keeps the extensions the two slots name.
prune_extra() {
  local d v keep_a keep_b
  keep_a="$(mval "$F/SLOT_A.manifest" VERSION)"; keep_b="$(mval "$F/SLOT_B.manifest" VERSION)"
  for d in "$X"/*; do
    [ -d "$d" ] || continue
    v="${d##*/}"
    [ "$v" = "$keep_a" ] || [ "$v" = "$keep_b" ] && continue
    echo "== removing the extension of $v (no slot holds it)"
    rm -rf "$d"
  done
}

rw()   { [ -n "$TEST" ] && return 0; mount -o remount,rw "$F" || die "cannot remount $F rw"; }
ro()   { sync; [ -n "$TEST" ] && return 0; mount -o remount,ro "$F" 2>/dev/null || true; }

# set_slot <slot>: replace slot.ini (temp + rename, then sync).
set_slot() {
  printf 'ceslot=%s\n' "$1" > "$F/slot.ini.new" && sync && mv "$F/slot.ini.new" "$F/slot.ini" && sync \
    || die "could not write $F/slot.ini"
  [ "$(selected_slot)" = "$1" ] || die "slot.ini does not read back as $1"
}

# wipe-storage's walk. $KEEP holds paths relative to /storage: a kept path
# stays whole, a directory with a kept path below it is walked into, and
# everything else is removed.
is_kept()   { local k; for k in $KEEP; do [ "$1" = "$k" ] && return 0; done; return 1; }
holds_kept() { local k; for k in $KEEP; do case "$k" in "$1"/*) return 0 ;; esac; done; return 1; }
wipe_dir() {
  local dir="$S${1:+/$1}" e name rel
  for e in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [ -e "$e" ] || [ -L "$e" ] || continue
    name="${e##*/}"; rel="${1:+$1/}$name"
    if is_kept "$rel"; then
      echo "   keep   $rel"
    elif [ -d "$e" ] && [ ! -L "$e" ] && holds_kept "$rel"; then
      wipe_dir "$rel"
    else
      echo "   remove $rel"; rm -rf "$e"
    fi
  done
}

cmd="${1:-}"
case "$cmd" in
  status)
    r="$(running_slot)"
    echo "running=${r:-none}"
    [ -n "$r" ] || { echo "stick=plain (no A/B slots)"; exit 0; }
    echo "selected=$(selected_slot)"
    for s in A B; do
      m="$F/SLOT_$s.manifest"
      if [ -f "$m" ]; then
        echo "slot_$s=$(mval "$m" VERSION) $(mval "$m" BUILD_ID | cut -c1-12) $(mval "$m" COREELEC_VERSION)"
      else
        echo "slot_$s=empty"
      fi
    done
    ;;

  install)
    src="${2:-}"
    [ -d "$src" ] || die "usage: am9slot.sh install <dir>"
    r="$(running_slot)"
    [ -n "$r" ] || die "this stick has no A/B slots (booted plain SYSTEM) - re-stick with am9usb make"
    sel="$(selected_slot)"
    [ "$sel" = "$r" ] || die "slot.ini already selects $sel but $r is running - a switch is pending; reboot or goback first"
    t="$(other "$r")"
    kodi_playing; rc=$?
    [ $rc -eq 0 ] && die "Kodi is playing - refusing"
    [ $rc -eq 2 ] && die "cannot ask Kodi whether it is playing - refusing"

    for f in kernel.img SYSTEM MANIFEST; do [ -s "$src/$f" ] || die "$src/$f missing or empty"; done
    echo "== checking the bundle"
    for f in kernel SYSTEM; do
      case $f in kernel) p="$src/kernel.img" ;; SYSTEM) p="$src/SYSTEM" ;; esac
      want="$(mval "$src/MANIFEST" "${f}_sha256")"
      [ -n "$want" ] || die "MANIFEST has no ${f}_sha256"
      [ "$(sha256sum "$p" | cut -d' ' -f1)" = "$want" ] || die "staged $p does not match MANIFEST - transfer damaged"
    done
    ver="$(mval "$src/MANIFEST" VERSION)"
    [ -n "$ver" ] || die "MANIFEST has no VERSION"
    case "$ver" in */*|.*) die "MANIFEST VERSION '$ver' is not a plain name" ;; esac
    if [ -f "$src/extra.tar" ]; then
      want="$(mval "$src/MANIFEST" extra_sha256)"
      [ -n "$want" ] || die "the bundle has extra.tar but its MANIFEST has no extra_sha256"
      [ "$(sha256sum "$src/extra.tar" | cut -d' ' -f1)" = "$want" ] || die "staged extra.tar does not match MANIFEST"
    fi

    # Room: what the target slot holds now is freed first.
    need=0; for f in kernel.img SYSTEM; do need=$((need + $(stat -c%s "$src/$f"))); done
    have=$(( $(df -k "$F" | tail -1 | awk '{print $4}') * 1024 ))
    for p in "$F/kernel_$t.img" "$F/SYSTEM_$t"; do [ -f "$p" ] && have=$((have + $(stat -c%s "$p"))); done
    [ $need -lt $((have - 1048576)) ] || die "not enough room on $F for slot $t: need $need, have $have"

    # The running slot's extension first (a backup before anything changes).
    rver="$(mval "$F/SLOT_$r.manifest" VERSION)"
    if [ -n "$rver" ] && [ -f "$X/$rver/pre-install" ]; then
      echo "== running the current extension's pre-install"
      sh "$X/$rver/pre-install" "$S" || echo "am9slot: warning: pre-install failed (continuing)" >&2
    fi
    # The new extension goes to /storage, which no slot install touches, keyed
    # by version so the slot and its extension switch together.
    if [ -f "$src/extra.tar" ]; then
      echo "== unpacking the extension $ver"
      rm -rf "$X/$ver.new"; mkdir -p "$X/$ver.new"
      tar xf "$src/extra.tar" -C "$X/$ver.new" || die "could not unpack extra.tar"
      rm -rf "$X/$ver"; mv "$X/$ver.new" "$X/$ver"
      if [ -f "$X/$ver/install" ]; then
        echo "== running the extension's install"
        sh "$X/$ver/install" "$S" "$ver" || die "the extension's install failed (slot $t not touched)"
      fi
    fi
    echo "== installing $ver into slot $t (running $r)"
    trap 'ro' EXIT
    rw
    # One "== " line per stage: the box's web page shows the latest as the step.
    echo "== clearing slot $t"
    rm -f "$F/SLOT_$t.manifest"; sync
    # dovi_$t.ko is removed too: older slots had one, and leaving it behind
    # would keep the fork's loader preferring a stale module over the one
    # symphony-dovi captures.
    # SLOT_$t.extra.tar too: a stick carries slot A's extension on the FAT,
    # and it would be stale beside the slot written now.
    rm -f "$F/kernel_$t.img" "$F/SYSTEM_$t" "$F/dovi_$t.ko" "$F/SLOT_$t.extra.tar"; sync
    echo "== copying into slot $t"
    cp "$src/kernel.img" "$F/kernel_$t.img" && cp "$src/SYSTEM" "$F/SYSTEM_$t" \
      || die "copy into slot $t failed (slot $t left without a manifest; $r still selected)"
    echo "== writing slot $t to the stick"
    sync
    # Read back from the device, not the page cache.
    [ -n "$TEST" ] || echo 3 > /proc/sys/vm/drop_caches
    cp "$src/MANIFEST" "$F/SLOT_$t.manifest.new" && sync && mv "$F/SLOT_$t.manifest.new" "$F/SLOT_$t.manifest" && sync \
      || die "could not write SLOT_$t.manifest"
    echo "== verifying slot $t (reading it back)"
    if ! out="$(verify_slot "$t")"; then
      rm -f "$F/SLOT_$t.manifest"; sync
      die "verify failed: $out (slot $t invalidated; $r still selected)"
    fi
    set_slot "$t"
    # Leave this installer on the stick for status/goback (the box's web page
    # runs /flash/am9slot.sh goback). Shared, like dtb.img: the newest wins.
    if [ -f "$src/am9slot.sh" ]; then
      { cp "$src/am9slot.sh" "$F/am9slot.sh.new" && sync && mv "$F/am9slot.sh.new" "$F/am9slot.sh" && sync; } \
        || echo "am9slot: warning: could not copy the installer to $F/am9slot.sh (slot $t is fine)" >&2
    fi
    prune_extra
    echo "== slot $t verified; slot.ini -> $t. Reboot to switch (goback undoes it before then)."
    ;;

  goback)
    r="$(running_slot)"
    [ -n "$r" ] || die "this stick has no A/B slots"
    sel="$(selected_slot)"
    if [ "$sel" != "$r" ]; then
      # A switch is pending: going back means staying on the running slot.
      t="$r"
    else
      t="$(other "$r")"
    fi
    out="$(verify_slot "$t")" || die "slot $t does not verify ($out) - not switching"
    trap 'ro' EXIT
    rw
    set_slot "$t"
    echo "== slot.ini -> $t ($(mval "$F/SLOT_$t.manifest" VERSION))"
    [ "$t" = "$r" ] && echo "   pending switch cancelled; no reboot needed" || echo "   reboot to switch"
    ;;

  wipe-storage)
    # What a stick straight out of am9usb make has on /storage, and nothing
    # else. Everything a running box put there goes: Kodi's databases,
    # Thumbnails, the BD-J store, and - the point of the exercise - every
    # settings file, so the image's own /usr/config, /usr/cache and
    # /usr/share/symphony have to supply them again on the next boot.
    # A live slot install cannot test that: its hooks are all "only if
    # missing", so an older file masks whatever the new image brought.
    #
    # KEPT, and each for a reason:
    #   .extra/               the slots' extensions - am9slot.sh put them
    #                         there and nothing at boot restores them.
    #   what the extension of the slot that boots next lists in its keep
    #                         file: software it installed into /storage.
    #   .cache/services/sshd.conf
    #                         ONLY when the kernel command line does not
    #                         already carry "ssh" - see below.
    #   lost+found            ext4's.
    nsel="$(selected_slot)"
    nver="$(mval "$F/SLOT_$nsel.manifest" VERSION)"
    if [ -n "$(mval "$F/SLOT_$nsel.manifest" extra_sha256)" ] && [ ! -d "$X/$nver" ]; then
      die "slot $nsel's extension ($nver) is not in $X - wiping would lose what it keeps"
    fi
    kodi_playing; rc=$?
    [ $rc -eq 0 ] && die "Kodi is playing - refusing"
    [ $rc -eq 2 ] && die "cannot ask Kodi whether it is playing - refusing"

    # Kodi rewrites guisettings.xml when it shuts down, so a wipe with Kodi
    # still running would put the old settings back during the reboot and the
    # test would silently pass against them.
    if [ -z "$TEST" ]; then
      echo "== stopping Kodi so it cannot rewrite guisettings.xml on shutdown"
      systemctl stop kodi || die "could not stop Kodi"
    fi

    # sshd has two on-switches: ConditionKernelCommandLine=|ssh and
    # ConditionPathExists=|/storage/.cache/services/sshd.conf. When the
    # command line carries ssh (config.ini's coreelec='ssh'), SSH does not
    # depend on /storage at all and this wipe can be a true fresh-stick test -
    # including of usercache-setup restoring sshd.conf, which is the path a
    # burned stick actually relies on and the one worth testing.
    #
    # Without it, keep the file. An older SYSTEM in the other slot may have no
    # /usr/cache/services/sshd.conf to restore it from, so a fallback to that
    # slot with this file gone means no SSH and no way in - and a live install
    # never rewrites /flash/config.ini, so the deploy path often lands here.
    KEEP=".extra lost+found $(keep_list "$nver" | tr '\n' ' ')"
    if grep -qw ssh "$CMDLINE" 2>/dev/null; then
      echo "== kernel command line carries 'ssh': clearing sshd.conf too (full fresh-stick test)"
    else
      KEEP="$KEEP .cache/services/sshd.conf"
      echo "== kernel command line has no 'ssh': keeping .cache/services/sshd.conf so the box stays reachable"
    fi

    echo "== clearing $S"
    wipe_dir ""
    sync
    echo "== $S now holds: $(ls -A "$S" | tr '\n' ' ')"
    if [ -z "$TEST" ]; then
      echo "== rebooting into the selected slot with a fresh /storage"
      nohup sh -c 'sleep 1; reboot' >/dev/null 2>&1 &
    fi
    ;;

  *) die "usage: am9slot.sh status | install <dir> | goback | wipe-storage" ;;
esac
