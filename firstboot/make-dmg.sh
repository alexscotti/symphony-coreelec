#!/bin/zsh
# make-dmg.sh <out.dmg> - the Mac first-boot program as a disk image.
#
# A browser download of a bare .command loses its execute permission, so
# Finder refuses to run it. A disk image keeps the file's mode: the user
# double-clicks the .dmg, then the program inside it.
set -euo pipefail
out="${1:?usage: make-dmg.sh <out.dmg>}"
here="${0:A:h}"
stage="$(mktemp -d)"
trap 'rm -r -- "$stage"' EXIT
install -m 755 "$here/am9-first-boot.command" "$stage/AM9 First Boot.command"
hdiutil create -quiet -ov -volname "AM9 First Boot" -fs HFS+ -format UDZO \
  -srcfolder "$stage" "$out"
