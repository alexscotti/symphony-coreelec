#!/bin/sh
# test_am9slot.sh - drive am9slot.sh through install / goback / refusal cases
# against a fake /flash, under busybox sh like the box. From the Mac:
#   tests/test_am9slot.sh
# re-runs itself in a busybox container.
if [ -z "${IN_CONTAINER:-}" ]; then
  d="$(cd "$(dirname "$0")/.." && pwd)"
  exec docker run --rm -e IN_CONTAINER=1 -v "$d":/t:ro busybox:1.36 sh /t/tests/test_am9slot.sh
fi
set -u
S=/t/am9slot.sh
W=/tmp/w; FAILS=0; N=0
export AM9SLOT_TEST=1 AM9SLOT_FLASH=$W/flash AM9SLOT_CMDLINE=$W/cmdline AM9SLOT_STORAGE=$W/storage

ok()   { N=$((N+1)); echo "ok   $N $*"; }
bad()  { N=$((N+1)); FAILS=$((FAILS+1)); echo "FAIL $N $*"; }
run()  { sh "$S" "$@" > $W/out 2>&1; echo $? > $W/rc; }
rc()   { cat $W/rc; }
expect_rc() { [ "$(rc)" = "$1" ] && ok "$2" || { bad "$2 (rc $(rc)): $(cat $W/out)"; }; }
has()  { grep -q "$1" $W/out && ok "$2" || bad "$2: wanted '$1' in: $(cat $W/out)"; }
sel()  { sed -n 's/^ceslot=//p' $W/flash/slot.ini; }

# bundle <dir> <version> <payload> [noextra]: kernel/SYSTEM + MANIFEST, and
# an extra.tar (install, keep, and a payload the install moves into
# /storage/.app/<version>) unless noextra
bundle() {
  mkdir -p "$1"
  echo "k-$3" > "$1/kernel.img"; head -c 300000 /dev/urandom > "$1/SYSTEM"
  cp "$S" "$1/am9slot.sh"
  if [ "${4:-}" != noextra ]; then
    mkdir -p "$1/ex/payload"; echo "$2" > "$1/ex/payload/VERSION"
    printf '#!/bin/sh\nset -e\nmkdir -p "$1/.app" "$1/.config/app.d"\nrm -rf "$1/.app/$2"; mv "$(dirname "$0")/payload" "$1/.app/$2"\necho unit > "$1/.config/app.d/app.service"\n' > "$1/ex/install"
    printf '# what wipe-storage keeps for this extension\n.app\n.config/app.d\n' > "$1/ex/keep"
    (cd "$1/ex" && tar cf ../extra.tar install keep payload); rm -rf "$1/ex"
  fi
  { echo "VERSION=$2"; echo "BUILD_ID=pin$2"; echo "COREELEC_VERSION=cv$2"
    [ -f "$1/extra.tar" ] && echo "extra_sha256=$(sha256sum "$1/extra.tar" | cut -d' ' -f1)"
    echo "kernel_sha256=$(sha256sum "$1/kernel.img" | cut -d' ' -f1)"
    echo "SYSTEM_sha256=$(sha256sum "$1/SYSTEM" | cut -d' ' -f1)"; } > "$1/MANIFEST"
}
boot() { echo "BOOT_IMAGE=kernel_$1.img SYSTEM_IMAGE=SYSTEM_$1 quiet" > $W/cmdline; }

# A fresh A/B stick: slot A = v1, slot B empty, slot.ini -> A, running A.
reset() {
  rm -rf $W; mkdir -p $W/flash $W/storage
  bundle $W/v1 v1 one
  cp $W/v1/kernel.img $W/flash/kernel_A.img; cp $W/v1/SYSTEM $W/flash/SYSTEM_A
  cp $W/v1/MANIFEST $W/flash/SLOT_A.manifest
  echo ceslot=A > $W/flash/slot.ini
  bundle $W/v2 v2 two
  boot A
}

# --- plain stick refuses
reset; echo "BOOT_IMAGE=kernel.img quiet" > $W/cmdline
run status;          has "stick=plain" "status on a plain stick"
run install $W/v2;   expect_rc 1 "install refused on a plain stick"; has "no A/B slots" "plain-stick message"

# --- install v2 into B
reset
run install $W/v2;   expect_rc 0 "install v2 into B"
[ "$(sel)" = B ] && ok "slot.ini -> B" || bad "slot.ini is $(sel)"
cmp -s $W/flash/SYSTEM_B $W/v2/SYSTEM && ok "SYSTEM_B is v2" || bad "SYSTEM_B differs"
cmp -s $W/flash/SLOT_B.manifest $W/v2/MANIFEST && ok "manifest B is v2" || bad "manifest B differs"
cmp -s $W/flash/SYSTEM_A $W/v1/SYSTEM && ok "slot A untouched" || bad "slot A changed"
run status;          has "slot_B=v2" "status shows B=v2"; has "selected=B" "status selected=B"

# --- a stale dovi_<slot>.ko from an older bundle is cleared, so the fork's
# dovi-loader cannot keep preferring it over what symphony-dovi captures
reset
echo stale > $W/flash/dovi_B.ko
run install $W/v2; expect_rc 0 "install over a slot that has a dovi_B.ko"
[ -e $W/flash/dovi_B.ko ] && bad "stale dovi_B.ko survived the install" || ok "stale dovi_B.ko removed"
[ -e $W/flash/dovi_A.ko ] && bad "wrote a dovi_A.ko" || ok "no dovi.ko written into a slot"

# --- the extension landed in storage, keyed by version, and its install ran
# with (storage, version)
[ -f $W/storage/.extra/v2/keep ] && ok "extension v2 unpacked to storage/.extra/v2" || bad "no extension v2"
[ "$(cat $W/storage/.app/v2/VERSION)" = v2 ] && ok "its install ran with the storage path and version" || bad "install did not run"
[ -f $W/storage/.config/app.d/app.service ] && ok "its install wrote under storage" || bad "nothing written by install"

# --- a damaged extension refuses before anything is touched
reset; echo corrupt >> $W/v2/extra.tar
run install $W/v2; expect_rc 1 "extension sha mismatch refused"; has "extra.tar does not match" "extension message"
[ ! -f $W/flash/SLOT_B.manifest ] && ok "slot untouched after extension refusal" || bad "slot B written"
[ -d $W/storage/.extra/v2 ] && bad "damaged extension unpacked" || ok "damaged extension not unpacked"

# --- extra.tar without extra_sha256 refuses
reset; sed -i '/^extra_sha256=/d' $W/v2/MANIFEST
run install $W/v2; expect_rc 1 "extra.tar with no extra_sha256 refused"; has "no extra_sha256" "missing-sha message"

# --- an extension whose install fails leaves the slot alone
reset
mkdir -p $W/fx; (cd $W/fx && printf '#!/bin/sh\nexit 3\n' > install && tar cf ../fail.tar install)
cp $W/fail.tar $W/v2/extra.tar
sed -i "s/^extra_sha256=.*/extra_sha256=$(sha256sum $W/v2/extra.tar | cut -d' ' -f1)/" $W/v2/MANIFEST
run install $W/v2; expect_rc 1 "failed extension install refused"; has "install failed" "install-failure message"
[ ! -f $W/flash/SLOT_B.manifest ] && ok "slot untouched after a failed extension install" || bad "slot B written"
[ "$(sel)" = A ] && ok "slot.ini stays A after a failed extension install" || bad "slot.ini is $(sel)"

# --- the RUNNING slot's pre-install runs before the slot is written
reset
mkdir -p $W/storage/.extra/v1
printf '#!/bin/sh\necho "pre-install ran on $1" > "$1/pre.log"; ls "%s" > "$1/flash.at.pre"\n' "$W/flash" > $W/storage/.extra/v1/pre-install
run install $W/v2; expect_rc 0 "install with a running extension's pre-install"
grep -q "pre-install ran on $W/storage" $W/storage/pre.log 2>/dev/null && ok "pre-install ran with the storage path" || bad "pre-install did not run"
grep -q SLOT_B.manifest $W/storage/flash.at.pre && bad "pre-install ran after slot B was written" || ok "pre-install ran before the slot was written"
reset
mkdir -p $W/storage/.extra/v1; printf '#!/bin/sh\nexit 1\n' > $W/storage/.extra/v1/pre-install
run install $W/v2; expect_rc 0 "a failing pre-install is a warning"; has "pre-install failed" "pre-install warning"

# --- a bundle with no extension installs, and leaves storage alone
reset; bundle $W/v9 v9 nine noextra
run install $W/v9; expect_rc 0 "install a bundle without extra.tar"
[ -e $W/storage/.extra/v9 ] && bad "made an extension from nothing" || ok "no extension for a bundle without one"

# --- .extra keeps only the extensions the two slots name
reset
mkdir -p $W/storage/.extra/v1 $W/storage/.extra/old $W/storage/.extra/older
run install $W/v2; expect_rc 0 "install v2 (prune check)"
[ -d $W/storage/.extra/v1 ] && ok "running slot's extension kept" || bad "pruned v1"
[ -d $W/storage/.extra/v2 ] && ok "new slot's extension kept" || bad "pruned v2"
[ -e $W/storage/.extra/old ] || [ -e $W/storage/.extra/older ] && bad "stale extensions kept" || ok "stale extensions pruned"

reset
run install $W/v2; expect_rc 0 "install v2 into B (again)"

# --- the installer leaves itself on the stick
cmp -s $W/flash/am9slot.sh $S && ok "installer copied to /flash/am9slot.sh" || bad "no /flash/am9slot.sh"

# --- second install while the switch is pending refuses
run install $W/v2;   expect_rc 1 "install refused while a switch is pending"; has "switch is pending" "pending message"

# --- goback while pending cancels (stay on A)
run goback;          expect_rc 0 "goback cancels the pending switch"
[ "$(sel)" = A ] && ok "slot.ini back on A" || bad "slot.ini is $(sel)"

# --- reboot into B, goback to A
echo ceslot=B > $W/flash/slot.ini; boot B
run goback;          expect_rc 0 "goback from running B"
[ "$(sel)" = A ] && ok "goback -> A" || bad "slot.ini is $(sel)"
echo ceslot=B > $W/flash/slot.ini

# --- install from running B writes A, never the running slot
bundle $W/v3 v3 three
run install $W/v3;   expect_rc 0 "install v3 from running B"
cmp -s $W/flash/SYSTEM_A $W/v3/SYSTEM && ok "v3 went into A" || bad "A is not v3"
cmp -s $W/flash/SYSTEM_B $W/v2/SYSTEM && ok "running B untouched" || bad "running B changed"

# --- damaged staging (truncated SYSTEM) refuses, nothing touched
reset
head -c 1000 $W/v2/SYSTEM > $W/t; mv $W/t $W/v2/SYSTEM
run install $W/v2;   expect_rc 1 "truncated SYSTEM refused"; has "transfer damaged" "damaged message"
[ "$(sel)" = A ] && ok "slot.ini stays A" || bad "slot.ini is $(sel)"
[ ! -f $W/flash/SLOT_B.manifest ] && ok "no manifest B written" || bad "manifest B exists"

# --- verify-after-write failure invalidates the slot, slot.ini unchanged
reset
# a manifest whose SYSTEM hash is for other bytes, but staging matches it:
# simulate the device returning different bytes by corrupting in a cp shim.
mkdir -p $W/bin; cat > $W/bin/cp <<'SH'
#!/bin/sh
/bin/cp "$@" || exit $?
case "$2" in */SYSTEM_[AB]) echo corrupt >> "$2" ;; esac
SH
chmod +x $W/bin/cp
PATH=$W/bin:$PATH run install $W/v2
expect_rc 1 "bad read-back refused"; has "verify failed" "verify message"
[ "$(sel)" = A ] && ok "slot.ini stays A after bad verify" || bad "slot.ini is $(sel)"
[ ! -f $W/flash/SLOT_B.manifest ] && ok "manifest B removed after bad verify" || bad "manifest B left behind"

# --- goback refuses an unverifiable other slot
reset
run goback;          expect_rc 1 "goback refused: B empty"; has "does not verify" "goback message"
[ "$(sel)" = A ] && ok "slot.ini stays A" || bad "slot.ini is $(sel)"

# --- Kodi
reset
AM9SLOT_KODI=playing run install $W/v2; expect_rc 1 "refused while Kodi plays"
AM9SLOT_KODI=error   run install $W/v2; expect_rc 1 "refused when Kodi cannot be asked"
[ ! -f $W/flash/SLOT_B.manifest ] && ok "nothing written while refused" || bad "manifest B written"

# --- garbage slot.ini reads as A
reset; echo "ceslot=Q" > $W/flash/slot.ini
run status; has "selected=A" "garbage slot.ini -> A"

# --- wipe-storage leaves exactly what a freshly written stick has
reset
run install $W/v2; expect_rc 0 "install v2 before the wipe"
mkdir -p $W/storage/.kodi/userdata/peripheral_data $W/storage/.cache/services \
         $W/storage/.cache/bluray $W/storage/.config/rc_keymaps $W/storage/.ssh \
         $W/storage/lost+found
echo old > $W/storage/.kodi/userdata/guisettings.xml
echo old > $W/storage/.cache/services/sshd.conf
echo old > $W/storage/.cache/services/samba.conf
echo old > $W/storage/.cache/timezone
echo old > $W/storage/.cache/bluray/junk
echo old > $W/storage/.config/rc_maps.cfg
echo old > $W/storage/.config/rc_keymaps/ugoos_ur02.toml
echo old > $W/storage/app.db
run wipe-storage; expect_rc 0 "wipe-storage exits 0"
has "no 'ssh'" "says it is keeping sshd.conf for reachability"
for keep in .extra/v2 .app .config/app.d .cache/services/sshd.conf lost+found; do
  [ -e "$W/storage/$keep" ] && ok "kept $keep" || bad "wiped $keep"
done
for gone in .kodi .cache/timezone .cache/bluray .cache/services/samba.conf \
            .config/rc_maps.cfg .config/rc_keymaps app.db .ssh; do
  [ -e "$W/storage/$gone" ] && bad "survived the wipe: $gone" || ok "removed $gone"
done
[ -f $W/storage/.config/app.d/app.service ] \
  && ok "what the extension installed under .config survives" || bad "extension's .config files lost"
[ -f $W/storage/.app/v2/VERSION ] && ok "the extension's payload survives" || bad "payload lost"

# --- with ssh on the kernel command line, sshd.conf goes too: a burned stick
# has none either, and usercache-setup restoring it is the path worth testing
reset
run install $W/v2 >/dev/null 2>&1
mkdir -p $W/storage/.cache/services; echo old > $W/storage/.cache/services/sshd.conf
echo "BOOT_IMAGE=kernel_B.img SYSTEM_IMAGE=SYSTEM_B coreelec=ssh quiet" > $W/cmdline
run wipe-storage; expect_rc 0 "wipe-storage exits 0 with ssh on the cmdline"
has "carries 'ssh'" "says why it can clear sshd.conf"
[ -e $W/storage/.cache/services/sshd.conf ] && bad "kept sshd.conf despite ssh on the cmdline" \
  || ok "cleared sshd.conf when ssh is on the cmdline"
[ -d $W/storage/.app ] && ok "extension payload still kept" || bad "payload lost"

# --- wipe-storage refuses when the next slot's extension is missing
reset
run install $W/v2 >/dev/null 2>&1; rm -rf $W/storage/.extra/v2
run wipe-storage; expect_rc 1 "refused when the next slot's extension is missing"; has "is not in" "missing-extension message"

# --- a box with no extension at all (a public build) wipes everything else
reset; bundle $W/v9 v9 nine noextra
run install $W/v9 >/dev/null 2>&1
mkdir -p $W/storage/.kodi $W/storage/.config/app.d $W/storage/.app
echo old > $W/storage/.kodi/guisettings.xml
run wipe-storage; expect_rc 0 "wipe-storage with no extension"
for gone in .kodi .config/app.d .app; do
  [ -e "$W/storage/$gone" ] && bad "survived a no-extension wipe: $gone" || ok "no-extension wipe removed $gone"
done

# --- keep entries that escape /storage are ignored
reset
run install $W/v2 >/dev/null 2>&1
printf '.app\n/etc\n../flash\n.kodi/../x\n  # comment\n\n' > $W/storage/.extra/v2/keep
mkdir -p $W/storage/.kodi; echo old > $W/storage/.kodi/x
run wipe-storage; expect_rc 0 "wipe-storage with hostile keep entries"
[ -d $W/flash ] && ok "/flash untouched" || bad "/flash gone"
[ -e $W/storage/.kodi ] && bad ".kodi kept through a .. entry" || ok "a .. entry keeps nothing"

# --- wipe-storage refuses while Kodi plays, and writes nothing
reset
run install $W/v2 >/dev/null 2>&1
mkdir -p $W/storage/.kodi; echo old > $W/storage/.kodi/guisettings.xml
AM9SLOT_KODI=playing run wipe-storage; expect_rc 1 "refused while Kodi plays"
[ -f $W/storage/.kodi/guisettings.xml ] && ok "nothing wiped while Kodi plays" || bad "wiped anyway"

echo "$((N-FAILS))/$N passed"
[ $FAILS -eq 0 ]
