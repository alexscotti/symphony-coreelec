#!/bin/bash
# verify_image.sh [<new .system>] [<reference .system>]
#
# Checks a public build (the default, as for cebuild); SYMPHONY_THEATER=yes
# checks the theater flavor instead (its skin and rig settings present).
#
# What can be established about a built image WITHOUT booting it. Run after
# every build, before a stick or a deploy. Defaults: the two newest *.system in
# $CEBUILD_ROOT/target, newest first.
#
# The seed tarball these settings replaced is retired, so the two checks that
# compare against it (settings_equiv.py, seed_sources.py) are not here; they
# need the seed out of git history. See CONFIG.md.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${CEBUILD_ROOT:-$HOME/cebuild}"
NEW="${1:-$(ls -t "$ROOT"/target/*.system 2>/dev/null | head -1)}"
REF="${2:-$(ls -t "$ROOT"/target/*.system 2>/dev/null | sed -n 2p)}"
[ -f "$NEW" ] || { echo "verify_image: no .system to check" >&2; exit 1; }
command -v unsquashfs >/dev/null || { echo "verify_image: unsquashfs is not on the PATH (brew install squashfs)" >&2; exit 1; }

[ "${SYMPHONY_THEATER:-no}" = yes ] && FLAVOR=theater || FLAVOR=public
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
N=0; FAILS=0
ok()  { N=$((N+1)); echo "ok   $N $*"; }
bad() { N=$((N+1)); FAILS=$((FAILS+1)); echo "FAIL $N $*"; }
have() { grep -qx "$1" "$W/paths.new" && ok "$2" || bad "$2 ($1 missing)"; }

echo "== image:     $(basename "$NEW")"
[ -n "$REF" ] && echo "== reference: $(basename "$REF")"
echo "== flavor:    $FLAVOR"
unsquashfs -l "$NEW" 2>/dev/null | sed 's|^squashfs-root||' | sort > "$W/paths.new"
echo "   $(wc -l < "$W/paths.new" | tr -d ' ') paths"

# --- every Symphony build: symphony-defaults, symphony-jre, symphony-dovi
for p in /usr/config/rc_maps.cfg /usr/config/rc_keymaps/ugoos_ur02.toml /usr/config/safemode.disable \
         /usr/share/symphony/guisettings.d/10-symphony.xml /usr/lib/symphony/symphony-userdata-merge \
         /usr/lib/systemd/system/symphony-userdata.service \
         /usr/lib/systemd/system/sysinit.target.wants/symphony-userdata.service \
         /usr/lib/tmpfiles.d/symphony-jre.conf /etc/profile.d/15-symphony-jre.conf \
         /usr/lib/kodi/addons/tools.jre.zulu/jre/bin/java \
         /usr/lib/coreelec/symphony-dovi \
         /usr/lib/systemd/system/symphony-dovi.service \
         /usr/lib/systemd/system/multi-user.target.wants/symphony-dovi.service \
         /usr/lib/systemd/system/symphony-dovi-notify.service \
         /usr/lib/systemd/system/kodi.target.wants/symphony-dovi-notify.service; do
  have "$p" "$p"
done

# --- the theater flavor (SYMPHONY_THEATER=yes) adds the skin and
# symphony-config; a public build must carry none of it
THEATER_PATHS="/usr/config/autostart.sh /usr/cache/services/sshd.conf /usr/cache/services/samba.conf
  /usr/cache/timezone /usr/cache/journald.conf.d/00_settings.conf
  /usr/share/symphony/guisettings.d/50-theater.xml
  /usr/share/symphony/userdata/peripheral_data/cec_HDMI.xml
  /usr/share/symphony/userdata/addon_data/service.coreelec.settings/oe_settings.xml
  /usr/lib/systemd/system/tz-data.service.d/tz-data-after-usercache.conf
  /usr/share/kodi/addons/skin.estuary.symphony/addon.xml"
if [ "$FLAVOR" = theater ]; then
  for p in $THEATER_PATHS; do have "$p" "$p"; done
else
  for p in $THEATER_PATHS; do
    grep -qx "$p" "$W/paths.new" && bad "public build carries $p" || ok "public build has no $p"
  done
fi

# The JRE's own libX11 copies are gone on purpose (one copy, in /usr/lib);
# PKG_DEPENDS_TARGET is what puts them there and is load-bearing.
grep -q '^/usr/lib/kodi/addons/tools.jre.zulu/lib/' "$W/paths.new" \
  && bad "the JRE still carries private X libs" || ok "no private X libs in the JRE"
for l in libX11.so.6 libXext.so.6 libXi.so.6 libXrender.so.1 libXtst.so.6 libXinerama.so.1 libxcb.so.1; do
  have "/usr/lib/$l" "/usr/lib/$l (for the JVM)"
done

# --- the shipped settings. They used to be a whole guisettings.xml, and the
# first build shipped Kodi's four-line default; read what is actually there.
unsquashfs -q -d "$W/x" -no-xattrs "$NEW" /usr/share/symphony/guisettings.d >/dev/null 2>&1
setting() { sed -n "s|.*<setting id=\"$2\"[^>]*>\\([^<]*\\)<.*|\\1|p" "$W/x/usr/share/symphony/guisettings.d/$1" 2>/dev/null | head -1; }
for kv in disc.playback=2 audiooutput.passthrough=true audiooutput.channels=10 audiooutput.streamsilence=0 \
          videoplayer.stereoscopicplaybackmode=1 services.airplay=false; do
  [ "$(setting 10-symphony.xml "${kv%%=*}")" = "${kv#*=}" ] && ok "10-symphony.xml: $kv" || bad "10-symphony.xml: wanted $kv"
done
setting 10-symphony.xml audiooutput.passthroughdevice | grep -q AML-AUGESOUND \
  && ok "10-symphony.xml: the AM9 Pro's passthrough device" || bad "10-symphony.xml: no AM9 passthrough device"
if [ "$FLAVOR" = theater ]; then
  [ "$(setting 50-theater.xml lookandfeel.skin)" = skin.estuary.symphony ] \
    && ok "50-theater.xml selects the Symphony skin" || bad "50-theater.xml does not select the Symphony skin"
  [ "$(setting 50-theater.xml services.webserver)" = true ] \
    && ok "50-theater.xml turns the web server on (the driver's JSON-RPC)" || bad "50-theater.xml: web server not on"
fi

# --- the skin is an OPTIONAL system add-on: enabled on first install where it
# ships, and no reason for Kodi to refuse to start where it does not
unsquashfs -q -d "$W/m" -no-xattrs "$NEW" /usr/share/kodi/system/addon-manifest.xml >/dev/null 2>&1
grep -q '<addon optional="true">skin.estuary.symphony</addon>' "$W/m/usr/share/kodi/system/addon-manifest.xml" 2>/dev/null \
  && ok "addon-manifest.xml lists the skin as optional" || bad "the skin is not an optional entry in addon-manifest.xml"

# --- Samba is opt-in: smbd and nmbd need samba.conf
unsquashfs -q -d "$W/s" -no-xattrs "$NEW" /usr/lib/systemd/system/smbd.service /usr/lib/systemd/system/nmbd.service >/dev/null 2>&1
for u in smbd nmbd; do
  grep -qx 'ConditionPathExists=/storage/.cache/services/samba.conf' "$W/s/usr/lib/systemd/system/$u.service" 2>/dev/null \
    && ok "$u.service needs samba.conf (opt-in)" || bad "$u.service starts without samba.conf"
done

# --- BD-J: the native half and the Java half must be the SAME build
unsquashfs -q -d "$W/b" -no-xattrs "$NEW" /usr/lib/libbluray.so.4.0.0 /usr/share/java >/dev/null 2>&1
jar="$(ls "$W/b"/usr/share/java/libbluray-j2se-*.jar 2>/dev/null | head -1)"
if [ -n "$jar" ] && [ -f "$W/b/usr/lib/libbluray.so.4.0.0" ]; then
  miss=0
  for sym in updateBackgroundN getUOMaskN; do
    s=$(strings "$W/b/usr/lib/libbluray.so.4.0.0" | grep -cx "$sym")
    j=$(unzip -p "$jar" org/videolan/Libbluray.class 2>/dev/null | strings | grep -cx "$sym")
    [ "$s" -ge 1 ] && [ "$j" -ge 1 ] || miss=1
  done
  [ $miss -eq 0 ] && ok "libbluray native and jar halves agree (our patched pair)" \
                  || bad "libbluray halves disagree - a patched jar that is never loaded looks like a patch that does not work"
else
  bad "libbluray.so or its jar is missing"
fi
[ "$(grep -c '^/usr/share/java/libbluray-j2se-.*\.jar$' "$W/paths.new")" = 1 ] \
  && ok "exactly one libbluray jar in the image" || bad "not exactly one libbluray jar"

# --- against the previous image: nothing may disappear. Only meaningful for
# the same flavor (a public image lacks the theater's files by design).
if [ -n "$REF" ] && [ -f "$REF" ]; then
  unsquashfs -l "$REF" 2>/dev/null | sed 's|^squashfs-root||' | sort > "$W/paths.ref"
  gone=$(comm -23 "$W/paths.ref" "$W/paths.new" | wc -l | tr -d ' ')
  [ "$gone" = 0 ] && ok "nothing from $(basename "$REF") disappeared" \
                  || { bad "$gone paths vanished vs the reference"; comm -23 "$W/paths.ref" "$W/paths.new" | head -10 | sed 's/^/        /'; }
  echo "     (added vs reference: $(comm -13 "$W/paths.ref" "$W/paths.new" | wc -l | tr -d ' '))"
fi

echo
[ $FAILS -eq 0 ] && echo "$((N-FAILS))/$N passed" || echo "$FAILS of $N FAILED"
[ $FAILS -eq 0 ]
