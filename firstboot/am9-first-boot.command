#!/bin/zsh
# am9-first-boot.command - the one-time switch of a Ugoos AM9 Pro from
# Android to the Symphony CoreELEC stick, from a Mac.
#
# The box's bootloader looks on USB for the stick's aml_autoscript only when
# Android restarts with the reason "update", and Android's menus have no
# entry that does that. adb does: `adb reboot update`. This script is that
# one command, plus everything an ordinary user would otherwise have to do
# by hand around it: get adb, connect, get the TV's "Allow USB debugging?"
# accepted, check the box is an AM9 Pro on firmware 2.2.0 or later, and make
# sure the stick is in.
#
# Uses only what every Mac has (zsh, curl, unzip, shasum, nc). adb is
# Google's own platform-tools, downloaded once into ~/Library/Caches and
# checked against a pinned SHA-256; nothing is installed system-wide. The adb
# server runs on its own port and is stopped at the end, so an adb the user
# already has is not touched.
#
# Double-click it in Finder. The first time, macOS may refuse to open a
# downloaded script: right-click it, choose Open, then Open again.

PT_VERSION=37.0.1
PT_URL="https://dl.google.com/android/repository/platform-tools_r${PT_VERSION}-darwin.zip"
# sha256 of that zip; Google's repository2-3.xml publishes sha1
# 6ae73f4de6452dc57e62ec02b68eed92a4c21661 for the same file.
PT_SHA256=ee39ad5967e95c2a07f04dbcbde96b1a0c916ba376096db5d2f498b7727a5d1d
CACHE="$HOME/Library/Caches/symphony-am9/platform-tools-r$PT_VERSION"
ADB="$CACHE/platform-tools/adb"
MIN_FW=(2 2 0)

export ANDROID_ADB_SERVER_PORT=5099

say_() { print -r -- "$*"; }
step() { print; print -r -- "== $*"; }

finish() {
  [[ -x "$ADB" ]] && "$ADB" kill-server >/dev/null 2>&1
  print
  read -rs "?Press Return to close this window. "
  print
  exit "${1:-0}"
}

fail() {
  print
  print -r -- "STOPPED: $*"
  finish 1
}

trap 'fail "interrupted"' INT

clear 2>/dev/null
cat <<'EOF'
Symphony CoreELEC - first boot of a Ugoos AM9 Pro

Before you start:
  - The AM9 Pro is on, in Android, on the same network as this Mac.
  - You know its IP address (Android: Settings -> Network & Internet ->
    your connection).
  - The Symphony system stick is written and in your hand.
  - The Dolby Vision stick (dovi.ko) is ready, if you have one.
EOF

# ---------------------------------------------------------------- adb
get_adb() {
  [[ -x "$ADB" ]] && return 0
  step "Downloading Google's adb (platform-tools $PT_VERSION, about 16 MB)"
  mkdir -p "$CACHE" || return 1
  local zip="$CACHE/pt.zip"
  curl -fL --progress-bar -o "$zip" "$PT_URL" || { say_ "Download failed."; return 1; }
  local got
  got="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  if [[ "$got" != "$PT_SHA256" ]]; then
    rm -f "$zip"
    say_ "The download does not match the expected checksum; not using it."
    return 1
  fi
  unzip -q -o "$zip" -d "$CACHE" || return 1
  rm -f "$zip"
  [[ -x "$ADB" ]]
}

get_adb || fail "could not get adb. Check this Mac's internet connection and run this again."

# ------------------------------------------------------------- address
valid_ip() {
  [[ "$1" =~ '^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$' ]] || return 1
  local o
  for o in "${match[@]}"; do (( o <= 255 )) || return 1; done
  return 0
}

while true; do
  print
  read -r "IP?The AM9 Pro's IP address (for example 192.168.1.50): "
  IP="${IP//[[:space:]]/}"
  valid_ip "$IP" && break
  say_ "That is not an IP address. It is four numbers separated by dots."
done
T="$IP:5555"

step "Looking for the box at $IP"
if ! nc -z -G 3 "$IP" 5555 >/dev/null 2>&1; then
  fail "nothing answered at $IP on port 5555.
  - Check the address in Android's network settings.
  - Check the box and this Mac are on the same network.
  - The box must be running Android firmware 2.2.0 or later, which has
    network debugging on."
fi

# ------------------------------------------------------------- connect
state() {
  "$ADB" devices 2>/dev/null | awk -v t="$T" '$1 == t { print $2 }'
}

"$ADB" start-server >/dev/null 2>&1
"$ADB" connect "$T" >/dev/null 2>&1

told=0
deadline=$(( SECONDS + 180 ))
while true; do
  s="$(state)"
  case "$s" in
    device) break ;;
    unauthorized)
      if (( ! told )); then
        print
        say_ "Look at the TV: it asks \"Allow USB debugging?\"."
        say_ "Tick \"Always allow from this computer\", then choose Allow (or OK)."
        say_ "Waiting for that..."
        told=1
      fi ;;
    "")
      "$ADB" connect "$T" >/dev/null 2>&1 ;;
  esac
  (( SECONDS < deadline )) || fail "the box did not accept this Mac within 3 minutes.
  If no question appeared on the TV, restart the box and run this again."
  sleep 2
done
say_ "Connected."

prop() { "$ADB" -s "$T" shell getprop "$1" 2>/dev/null | tr -d '\r'; }

# --------------------------------------------------------------- model
step "Checking the box"
MODEL="$(prop ro.product.model)"
norm="${${MODEL:u}//[ -]/_}"
say_ "Model: ${MODEL:-unknown}"
if [[ "$norm" != "AM9_PRO" ]]; then
  fail "this is not a Ugoos AM9 Pro. This build is for the AM9 Pro only (not the plain AM9)."
fi

# ------------------------------------------------------------ firmware
# TODO: pin the property Ugoos keeps "2.2.0" in, read once from a box with
# `adb shell getprop`. Until then: the first x.y.z found in these.
FW_RAW=""
for p in ro.build.display.id ro.build.version.incremental ro.product.version ro.build.description; do
  v="$(prop "$p")"
  [[ -n "$v" ]] && FW_RAW="$FW_RAW $v"
done
FW=""
if [[ "$FW_RAW" =~ '(^|[^0-9.])v?([0-9]+)\.([0-9]+)\.([0-9]+)([^0-9.]|$)' ]]; then
  FW_PARTS=("${match[2]}" "${match[3]}" "${match[4]}")
  FW="${(j:.:)FW_PARTS}"
fi

older() {   # older a b c -> true when a.b.c < MIN_FW
  local i
  for i in 1 2 3; do
    (( $argv[i] < MIN_FW[i] )) && return 0
    (( $argv[i] > MIN_FW[i] )) && return 1
  done
  return 1
}

if [[ -n "$FW" ]]; then
  say_ "Firmware: $FW"
  if older "${FW_PARTS[@]}"; then
    fail "firmware $FW is too old: this build needs 2.2.0 or later.
  Update Android first (Settings -> About -> System update -> Local update,
  with the firmware from Ugoos' AM9 Pro page), then run this again."
  fi
else
  say_ "Firmware: could not read a version number from the box."
  say_ "Check Settings -> About on the TV: it must say 2.2.0 or later."
  read -r "ans?Is it 2.2.0 or later? (y/n) "
  [[ "${ans:l}" == y* ]] || fail "update Android to 2.2.0 or later first, then run this again."
fi

# ---------------------------------------------------------------- go
step "Ready"
cat <<'EOF'
Plug the Symphony system stick into one of the box's USB-A ports (all three are USB 3.0),
and the Dolby Vision stick (if you have one) into any other port.

The box will restart from the stick. You should see the Symphony splash
within a few seconds, then Kodi. This switch is needed only once: from now
on the box starts from the stick whenever it is plugged in.
EOF
print
read -r "ans?Sticks in? Press Return to restart the box into Symphony (or type q to stop): "
[[ "${ans:l}" == q* ]] && fail "stopped; nothing was changed."

"$ADB" -s "$T" reboot update >/dev/null 2>&1
rc=$?
"$ADB" disconnect "$T" >/dev/null 2>&1
(( rc == 0 )) || fail "the box did not accept the restart command (adb exit $rc)."

print
say_ "Done. The box is restarting into Symphony CoreELEC."
say_ "If it starts Android again instead, check the system stick is in a USB-A port and run this again."
finish 0
