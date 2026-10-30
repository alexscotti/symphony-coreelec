# Symphony CoreELEC for the Ugoos AM9 Pro

Symphony CoreELEC is a CoreELEC 22 build for one box, the Ugoos AM9 Pro
(Amlogic S6 / S905X5). It is aimed at playing Blu-ray and UHD Blu-ray disc
structures as the disc intended: Dolby Vision dual-layer (FEL) content,
BD-J and HDMV disc menus, and lossless audio passthrough. It also adds a way
to update the box from a browser with a one-step rollback.

It is built entirely from source, and every change on top of official
CoreELEC is an ordinary, reviewable git commit. Nothing is carried as a
binary blob or an unexplained patch set.

> Status: built and used daily on one AM9 Pro. Only the AM9 Pro is built
> and tested; the image is CoreELEC's Generic image, and no other board
> images are produced.

## Background and purpose

I have a large collection of movies, heavy on UHD Blu-ray, ripped from discs
that I own with MakeMKV (and sometimes DVDFab) into full disc directory
(BDMV) structures. They are played through a custom UI of my own that drives
playback on external players through a driver architecture, with drivers
for Oppo, Dune and Zidoo players.

Of those, the Oppo UDP-203/205 remained the most capable, but they are no
longer made, and their availability and age are a serious concern. This
work set out to find a viable replacement for the Oppo for my library: a
player that plays every disc I own correctly, equal to or better than the
Oppo. This build, on the Ugoos AM9 Pro, is that replacement.

## Goals

- **Every disc in a real library plays, from its own menus.** A full disc
  ripped from a disc that is owned (the BDMV folder) should behave as the disc does in a standalone
  player: first-play path, menus, Select to the film. That includes BD-J
  menus, HDMV menus, still menus, discs whose menu is a looping playlist, and
  discs that split the film into parts.
- **Dolby Vision as authored.** Dual-layer (FEL) titles play with their
  enhancement layer, in step with the base layer, at the film's frame rate.
  When that cannot happen, playback stops rather than silently degrading to
  the base layer alone.
- **The film plays smoothly.** Judged on what reaches the screen: the
  presented frame rate matches the stream and there are no gaps between
  frames.
- **Unattended control.** The box is meant to be driven by another system
  over Kodi's JSON-RPC, so no setting may raise a dialog that waits for a
  user, and disc-menu state is exposed to the controller.
- **Every fix is found by a test and is a commit.** A failure is reproduced,
  root-caused and fixed in the fork as its own commit, named after what it
  fixes, and the test that found it must then pass.
- **Updates cannot strand the box.** A new build goes into the other slot;
  the running system is never touched and the previous one is a reboot away.

## Lineage

Three layers, each a public git history:

```
CoreELEC/CoreELEC  coreelec-22          official CoreELEC
  + SamuriHL/CoreELEC  samurihl-ce22    SamuriHL's playback work
  + Symphony commits                     this fork
  = alexscotti/CoreELEC  symphony

CoreELEC/xbmc  (the commit official CoreELEC pins)
  + SamuriHL's Kodi commits
  + Symphony commits
  = alexscotti/xbmc  symphony
```

**Official CoreELEC.** The base is `CoreELEC/CoreELEC` branch `coreelec-22`
at the commit named in `UPSTREAM_BASE`. The fork is rebased onto newer
official commits; it is never a merge of them.

**SamuriHL's fork.** SamuriHL maintains a CoreELEC fork focused on disc
playback on Amlogic hardware: Dolby Vision enhancement-layer handling in
the kernel's `amdv` driver, `libdovi` built from source, an updated
`libbluray` with extensive BD-J fixes, multichannel LPCM over HDMI, and an
HDR-composited Kodi GUI. Every one of his commits is cherry-picked here with
`-x`, keeping his authorship, so `git log` shows exactly which work is his.
His Kodi commits are replayed onto CoreELEC's own Kodi tree in the same way.
His update-checker add-on and his boot splash are not carried.

**Symphony's commits.** On top of both, in Kodi and in the CoreELEC tree
(kernel drivers, `libbluray`, packaging). They are listed in "What the fork
fixes" below. Each Kodi change is a commit on
`alexscotti/xbmc` `symphony`, and the CoreELEC fork pins the exact Kodi
commit in `kodi/package.mk`.

## What the fork fixes

Each item is one or more commits, named after what it fixes. Most were
found by the library test below.

### 3D Blu-ray (MVC) works

3D Blu-rays play in full frame-packed 3D. Before, the AM9 Pro showed the
left eye, a green band, and black where the right eye belongs: the video
layer's window for the left eye covered the right eye. The kernel's video
driver now sizes that window from the frame's own left-eye height, and the
on-screen display is clipped to the frame-packed output.

The right eye no longer goes black after a Dolby Vision dual-layer title.
The second eye is read by the second video layer, which a dual-layer title
also uses, for its enhancement layer, through the compressed-frame decoder.
Its source select stayed there afterwards, and 3D never set it back, so
every 3D title showed a black right eye until the box lost power. The video
driver now selects plain reads for that layer whenever it sets it up for 3D.

A vertically shifted 3D picture no longer leaves the next one misaligned.
Kodi grows the driver's gap between the eyes by the shift so both eyes move
together, and it used to read the "default" gap back from the driver: after
Kodi restarted under a shifted picture, it took the shifted gap for the
default, and every later 3D title had its right eye a few lines low. The gap
now returns to the frame-packing standard's 45 lines, and closing a title
also clears the 3D mode it gave the video driver.

### VC-1 plays without artifacts

On the AM9 Pro, hardware VC-1 showed short horizontal lines on moving
pictures. The decoder was innocent: CoreELEC's VC-1 driver copies every
progressive frame on the CPU through a cacheable mapping with no cache
maintenance, and the lines were stale cache lines of an older frame. This
build's driver invalidates the source before the copy, writes the copy back
before the display reads it, and releases the decode buffer only after the
copy. VC-1 and MPEG-2 decode in hardware.

### HDMI output

- Audio stays muted across an audio format change on the HDMI link.
  Together with "Keep audio device alive" off (see Defaults), a TrueHD
  trailer into an AC-3 menu no longer bursts static.
- The HDMI driver no longer sleeps 1.5 s inside its HDR work item.
- Dolby Vision signalling is corrected when it goes wrong: a link carrying
  DV the wrong way is re-trained (also while a disc session holds DV), native
  DV is re-requested when the DV core was left on a conversion or disabled by
  an unplug, and the change is made without blocking playback.
- An HDR type change at an unchanged display mode updates the link in place.
- An HDMI unplug or reconnect: the display's capabilities are kept while it
  is disconnected, a reconnect at the same mode does not rebuild the window,
  the GUI is repainted, and the video keeps its output mode.
- Leaving 3D no longer ends on a black screen: the HDMI PHY is set up again
  after the last mode change out of 3D.

### Dolby Vision

- An FEL title keeps its enhancement layer: the HEVC decoder and the `amdv`
  driver no longer bypass the EL of a stream the player identifies as FEL.
- The enhancement-layer type of a title outlives the codec instance, so a
  decoder reopen mid-title does not forget the title is FEL.
- FEL guard: when an FEL title's enhancement layer is not decoding, playback
  stops instead of silently showing the base layer alone. It judges the
  stream actually being decoded, so a single-layer or MEL stream that
  follows FEL content is not stopped.
- Dual-layer stalls on near-static, very low-bitrate passages: the decoder's
  stream-mode running floor is capped at 16 access units.
- Half-rate judder on discs whose base layer carries wrong timestamps: a
  dual-layer frame takes its timestamp from the enhancement layer when the
  layers disagree.
- Seamless clip joins: a late frame from the clip that ended is dropped,
  not the new clip's queue (which held its first keyframe); the decoder
  reset at a join only happens when the new clip has not yet fed a keyframe.
  This removes multi-second freezes where an intro joins the film.
- Enhancement-layer pairing: an enhancement layer is owed only to a
  base-layer frame that is still missing one; a base-layer keyframe without
  a decode timestamp drops a stale enhancement layer and never pairs with an
  incoming non-keyframe one.
- The HEVC decoder never discards the start of its input, and never takes a
  picture it already output as a new first frame.
- The HEVC decoder's wait for the memory controller to go idle is bounded,
  and a legacy decoder's stream fetch is stopped before its memory port
  closes.
- Video timestamps are checked in at the stream offset they were written at
  (matthane).

### Blu-ray and BD-J menus

- BD-J deadlocks: the player no longer waits for a BD-J picture with its
  loop stopped; an empty demuxer open at the end of a BD-J title releases
  the notifications the application is waiting for.
- A menu the application opens for the playlist that is starting is kept,
  not discarded.
- Opening the demuxer waits for an input that answers "retry", instead of
  failing.
- A held playitem keeps its first bytes, and a BD-J playlist read whole
  while the demuxer opens gets its running time (menus that went black).
- A playitem boundary queued behind another disc event still owns the
  bytes that came with it: one-frame clips at playitem seams are no longer
  dropped.
- Disc stills sync once the picture is ready, without waiting for audio:
  infinite still menus are shown instead of a busy spinner.
- The first frame is shown when input stops, since it may be the only one:
  BD-J still menus are no longer black.
- HDMV menus that ignored every key: interactive-graphics streams are kept
  out of the stream probe and discarded instead of being mistaken for an
  audio track.
- A seek re-arms BD-J's end-of-playlist notification.
- Kodi no longer crashes on every stop after a BD-J disc (the BD-J JVM runs
  with `-Xrs`).
- A retail disc's own BD-J logger can be switched on, for diagnosis.
- Opening a disc no longer reads every playlist on it.
- A secondary (picture-in-picture) video track is never chosen as the
  feature.
- Timed still menus (an FBI warning, for example) are released when their
  time is up instead of sticking.
- Fast forward and rewind work in a BD-J title, refused only where the disc
  forbids seeking.
- Kodi no longer crashes reading the current item during a title change.
- Disc-menu state is published to the controller over JSON-RPC
  (`VideoPlayer.DiscMenuState`, and `VideoPlayer.DiscMenuSignals` with the
  raw inputs: graphics, seeking, BD-J, pop-up, playlist, still).

### Network read-ahead

- Blu-ray folders on a network share get read-ahead that understands the
  disc structure: it follows the playing playlist and reads the next clip
  before the current one ends. Single files (`.mkv`) get plain read-ahead.
  Settings > Services > Caching (256 MB by default; 0 turns it off).

### Playitem seams and seeks

- An audio-only change at a playitem boundary keeps the video decoder, and
  the end of a segment drains and presents its queued pictures instead of
  resetting the decoders at the seam.
- Blu-ray display time is anchored at the demuxer open.
- After a seek, a stale audio start no longer holds the clock back (a frozen
  picture), and untimed fragments from before the seek are dropped before the
  decoder.
- A reused Blu-ray stream with no stated HD colour description is taken as
  BT.709.

### Demuxer

- Packets of streams outside the program are read past instead of stalling
  playback.
- Blu-ray null packets (PID 0x1FFF) are dropped silently, not reported as
  corrupt.

### Audio

- After a DTS sync loss (for example a chapter skip), DTS-HD frames that
  carry no type are skipped instead of breaking the stream.
- The audio engine keeps serving the player while the audio device will not
  open, and recovers when it does.
- Two audio-engine faults on stream teardown (a drained stream with no
  buffers; freeing a stream outside a configured state).

### Video output

- A software-decoded segment after a hardware-decoded menu gets a
  renderer that can draw it, and its frames are released: this was a memory leak that ran the box out of memory.
- 3D Blu-rays switch the output to frame packing with Kodi's default mode
  list (no whitelist set up): on a 4K GUI that list used to leave out every
  1080p frame-packed mode, so 3D played without switching.
- Kodi's vertical picture shift works with frame-packed 3D: both eyes move
  and the picture keeps its height.
- The 3D stereo mode is no longer read from a stale cache.

### Defaults and platform

Kodi and CoreELEC defaults this build changes, so a disc plays as authored
out of the box (each can still be changed in Kodi's settings):

- Blu-ray playback opens the disc's own menus.
- Audio passthrough on, to the AM9 Pro's HDMI output, 7.1 speaker layout.
- "Keep audio device alive" off: streamed silence through silent menus
  caused loud static when the next menu's audio started.
- 3D plays in the preferred mode without asking (the question dialog would
  wedge a box driven over JSON-RPC).
- No thumbnail, flag or HDR10+ extraction passes over the library.
- Kodi's crash-loop "safe mode", which moves the whole profile aside, is
  off.
- Amlogic noise reduction is off.
- The Ugoos UR-02 remote works out of the box.
- AirPlay and Samba file sharing are off (see Security).

Platform:

- The boot script finds the stick's boot configuration on any USB disk, not
  only the first.
- The system features in "What this build adds to the box".

## What this build adds to the box

- **A/B system slots.** The boot partition holds two complete systems
  (kernel and SYSTEM), and `slot.ini` picks which one boots. An update
  installs into the slot that is NOT running, so the running system is never
  touched. If the new kernel will not load, the box falls back to the other
  slot, and going back is one click and a reboot. CoreELEC's own
  `/storage/.update` mechanism and its online updater are disabled on a slot
  stick: an update would overwrite the running slot, and the updater can
  only offer official CoreELEC. The Updates menu is hidden.
- **Host Management web page** on port 80 at
  `http://symphony-coreelec-0.local/host_management`: shows both slots and
  the CoreELEC and Kodi commits each was built from (linked to GitHub);
  uploads a slot bundle or a stick image in resumable chunks; installs it;
  reboots; goes back.
- **BD-J Java runtime in the image.** Disc menus written in Java work out of
  the box. No add-on to install.
- **Dolby Vision module capture.** CoreELEC cannot ship Amlogic's `dovi.ko`
  and neither does this build. Put `dovi.ko` in the root of any FAT32 USB
  stick, plug it in, and boot: the box copies it to
  `/storage/.config/dovi.ko`, where CoreELEC's loader finds it. The file is
  checked first (an aarch64 kernel module, the Dolby Vision driver, a recent
  enough kernel) so a wrong or truncated file is reported, not loaded. The
  stick is only read. Without the module the box runs normally and plays
  Dolby Vision as HDR10. When the module is loaded, the box says so on
  screen once per boot, so you can see it was found.
- **Hostname** `symphony-coreelec-0`, published over mDNS as
  `symphony-coreelec-0.local`. A hostname set in CoreELEC's settings still
  takes precedence.
- **Boot splash**: Symphony's musical notes.

## How it is tested

The fork is tested against a library of full discs ripped from discs that
are owned, not a handful of sample files. The harness is not part of this repo: it drives the box
through the home-automation system it was built for. Its method and results
are described here.

**The whole library, one disc at a time.** Every movie in a library of over
1000 Blu-ray, UHD Blu-ray and 3D discs, ripped from discs that are owned, is
played on the AM9 Pro, unattended, exactly as the controlling system would play it: the full disc folder where
the disc is played from its menus, the single video file where it is not.
For a disc played from its folder the test waits for the disc's own menu,
checks a picture is actually drawn, and presses Select until the feature
starts. Discs whose menus need more than Select (language selects, consent
screens, "Play Part 1", trailers that look like menus) replay a key sequence
recorded once by hand. The feature counts as started when a title within 10
minutes of the film's known running time is playing and no disc menu is up.

Then 90 seconds of the film are watched, and the disc FAILs on any of:

- the menu or the film never arriving
- a disc menu reported during the film
- the clock not advancing at 1:1, or playback stopping
- no video or no audio decoder
- a Dolby Vision title not reported as Dolby Vision
- for FEL, no enhancement-layer decoder, or base and enhancement frame counts
  more than 2 apart
- the presented frame rate more than 2% off the stream's, or any pause over
  100ms between presented frames
- decoder error or drop counters growing
- known failure lines in the Kodi log

Frames are counted where they reach the screen, from the kernel's
presentation trace, not from the decoder's own counter, which runs ahead in
bursts. Each disc starts from a clean BD-J store, so it plays its first-play
path rather than a resume prompt. Every step is time-bounded; a decoder that
wedges is recorded as such, the box is power-cycled, and the run continues.

**Results.** This build has been tested on that library of over 1000 discs.
The fixes for what those runs turned up are most of "What the fork fixes"
above, and the library is re-run against new builds.

**Focused suites,** run for every Kodi change before it is pinned:

- repeated automated runs of the opening minutes of a Dolby Vision FEL title,
  judged on presented frames and layer pairing
- a menu regression over 15 BD-J and HDMV discs
- a Dolby Vision FEL guard test: a forced loss of the enhancement layer must
  stop playback, and a single-layer or MEL title must not be stopped

## Installing

### What you need

- A **Ugoos AM9 Pro** (Amlogic S905X5-J). Not the plain AM9 (S905X5), which
  has no Dolby Vision at all.
- Ugoos Android firmware **2.2.0** or later on the box. This build's device
  tree does not boot on 2.1.x.
- **A USB 3.0 stick of 8 GB or more** for the system (the image is about
  6 GB uncompressed). USB 3.0 is measurably faster than an SD card on this
  box.
- **A second, small FAT32 USB stick** for Amlogic's Dolby Vision module (any
  size; the file is under 1 MB).
- A Mac or Windows PC on the same network as the box, for the one-time
  switch from Android (step 4).

### 1. Download a release

From this repository's **Releases** page, download:

| file | what |
|---|---|
| `...-am9pro-usb.img.gz` | the system image: written to a stick for the first install, uploaded to the box for every update after it |
| `...-am9pro-usb.img.gz.sha256` | its checksum |

Check the download:

```
shasum -a 256 -c <image>.img.gz.sha256        # macOS / Linux
certutil -hashfile <image>.img.gz SHA256      # Windows: compare by eye
```

### 2. Write the stick

Any tool that writes a compressed disk image to a whole device works; there
is no need to decompress it first. Writing replaces everything on the stick,
so pick the right device.

- **balenaEtcher** (Windows, macOS, Linux): Flash from file, choose the
  `.img.gz`, choose the stick, Flash. Leave its validation on.
- **Raspberry Pi Imager**: Choose OS -> Use custom -> the `.img.gz`.
- **Linux**: `gzip -dc <image>.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync status=progress`

**Do not let the computer open the stick after writing it.** The stick has a
FAT partition (`COREELEC`) and a Linux partition (`STORAGE`).

- On **macOS**, the system mounts `COREELEC` the moment a write finishes and
  Spotlight writes its index files into it, over space that belongs to the
  system image. The system image then fails its checksum and the box hangs
  at the Ugoos logo, which looks exactly like a broken build. It does not
  happen every time. Eject the stick the moment the writer finishes, and
  never open it in Finder. If the box hangs at the logo, write the stick
  again.
- On **Windows**, a prompt to format the `STORAGE` partition may appear,
  because Windows cannot read it. Cancel it. Never format.

Nothing needs to be copied onto the system stick: the device tree and every
setting are already in the image. That is also why the Dolby Vision module
goes on a separate stick rather than onto this one.

### 3. Prepare the Dolby Vision stick

Amlogic's Dolby Vision kernel module, `dovi.ko`, cannot be distributed by
CoreELEC or by this project; every user downloads it. Profile 7 FEL needs the
FEL-fixed module from the CoreELEC forum:

- `5.15_2.6_dovi_patched_fix_fel.ko`, linked from the first post of
  [FEL - Amlogic NO support](https://discourse.coreelec.org/t/fel-amlogic-no-support/58631)
  on the CoreELEC forum. Not the older `5.15_2.6_dovi_patched.ko`, which that
  post marks as no longer to be used.

On the small stick:

1. Format it FAT32.
2. Copy the module to the **root** of the stick and rename it to exactly
   `dovi.ko`. Check the name: some browsers append an extension
   (`dovi.ko.ko`), and the box will not find it.
3. Eject it.

At boot, the box looks at every FAT32 stick for `dovi.ko` in its root,
checks that it is an aarch64 kernel module that is the Dolby Vision driver
for a recent enough kernel, and copies it to `/storage/.config/dovi.ko`.
From then on it loads from there; the stick is only ever read and can be
removed. Keep it, though: a new system stick, or a reset of `/storage`,
needs it again, and leaving it plugged in costs nothing (a box that already
has a valid module does not look at the sticks at all).

A wrong or damaged file is reported in the boot log and skipped, never
loaded. Once Kodi is up, on every boot where the module loaded, the box
shows "Dolby Vision: Driver loaded from the USB stick" (the module it copied
from the stick, even after the stick is removed). No message means no module
was loaded. Without the
module the box runs normally and plays Dolby Vision as HDR10.

To replace the module later: put the new one on the stick, delete
`/storage/.config/dovi.ko` on the box (over SSH), and reboot.

### 4. First boot: the one-time switch from Android

The box starts from the stick only after Android has restarted it once in a
special way, which Android's menus cannot do. A small program on your Mac or
Windows PC does it for you. After this, the box starts from the stick
whenever it is plugged in.

1. On the box, in Android, with its remote: check Settings -> About says
   firmware **2.2.0** or later (if not, update it first: Settings -> About
   -> System update -> Local update, with the firmware zip from Ugoos' AM9
   Pro page on a stick).
2. Note the box's **IP address**: Settings -> Network & Internet -> your
   connection.
3. Download the first-boot program from this repository's Releases page
   and run it. (These programs have not yet been run against a real box in
   Android: if one fails, use the manual adb steps below, and please open
   an issue.)
   - **Mac:** `am9-first-boot.command`. Double-click it. The first time,
     macOS may say it cannot be opened: right-click it, choose **Open**, then
     **Open** again.
   - **Windows:** `am9-first-boot.cmd` and `am9-first-boot.ps1`, in the same
     folder. Double-click `am9-first-boot.cmd`. If Windows says "Windows
     protected your PC", choose **More info**, then **Run anyway**.
4. Type the IP address when asked. The program downloads Google's `adb`
   (once), connects to the box, and checks it is an AM9 Pro on firmware
   2.2.0 or later.
5. The TV asks **"Allow USB debugging?"**: tick **Always allow from this
   computer** and choose **Allow**.
6. When the program says so, plug the system stick into one of the box's
   USB-A ports (all three are USB 3.0) and the Dolby Vision stick into
   another, then press Return (Enter). The box restarts into Symphony
   CoreELEC.

<details>
<summary>Doing it by hand with adb</summary>

```
adb connect <box-ip>:5555        # accept the dialog on the TV, then repeat
adb reboot update                # with the system stick plugged in
```

</details>

After the first boot:

- The box is `symphony-coreelec-0.local` on your network, and the Host
  Management page is `http://symphony-coreelec-0.local/host_management`.
- SSH is on: `ssh root@symphony-coreelec-0.local`, password `coreelec`.
  **Change it** with `passwd` (see Security).
- Android is still on the box's internal storage, untouched. Power off,
  remove the system stick and power on to go back to it.

Swapping system sticks later needs no Android step: power off, swap, power
on.

### Playing a disc folder

Add your share in Kodi: Videos, Files, Add videos..., Browse, Add network
location. With the source's content left as "None", selecting a disc's folder
opens it like any other folder: go into its `BDMV` folder and select
`index.bdmv`. The disc then plays as the disc does, from its first-play
title into its own menu. To have selecting the disc's folder play it
instead, set the source's content to Movies (Kodi then scrapes the
library).

### Updating, after the first install

Updates go over the network and never touch the running system. The stick
holds two complete systems, slot A and slot B; the first install fills slot
A.

1. Download the new release's `...-am9pro-usb.img.gz`, the same file a first
   install writes to a stick: the page installs the system inside it. (It
   also takes a `coreelec_..._slot.tar` slot bundle, the same system without
   the rest of the stick, as built locally.)
2. Open `http://symphony-coreelec-0.local/host_management`. It shows both
   slots, which one is running, and the CoreELEC and Kodi commits each was
   built from.
3. Choose the file and upload it. The upload is chunked and resumable: an
   interrupted upload carries on where it stopped.
4. Press **Install**. The bundle's checksums are verified and it is written
   into the slot that is NOT running. Nothing can be installed while
   something is playing.
5. Press **Reboot**. The box starts the new system.

If the new system is not right, press **Go back** and reboot: the previous
system is still in the other slot, unchanged. If the new kernel does not load
at all, the box falls back to the other slot by itself.

Updates keep `/storage`: settings and the Dolby Vision module stay as they
are. CoreELEC's own update mechanism (`/storage/.update`) and its online
updater are disabled on this stick, because an update would overwrite the
running slot.

From a build host, the same can be done from the command line:

```
./am9usb install symphony-coreelec-0.local <bundle>.tar   # into the other slot
./am9usb reboot  symphony-coreelec-0.local
./am9usb status  symphony-coreelec-0.local                # both slots
./am9usb goback  symphony-coreelec-0.local
```

## Building

Builds run in Docker. The build tree lives in a sparse ext4 image (the kernel
source has case-colliding file names), so any host filesystem works.

Requirements, as built and tested:

- An Apple-silicon Mac with Docker Desktop, "Use Rosetta for x86_64/amd64
  emulation" ON (the kernel and u-boot compilers are prebuilt x86 binaries),
  and as many CPUs and as much memory (>= 16 GB) as you can give it.
- About 120 GB free for the build tree, sources and output.
- `unsquashfs` (`brew install squashfs`) to make slot bundles.

```
./cebuild setup                                   # once: Docker images, build volume, clone
./makeimgce --version current --full              # ~4-5 h cold
./makeimgce --version current --incremental       # later: only what changed
```

`PIN` names the fork commit every image is built from; `cebuild update <ref>`
moves it. Kodi follows automatically through `kodi/package.mk`.

Output, in the build directory's `target/`:

| file | use |
|---|---|
| `*-am9pro-usb.img.gz` | a ready-to-boot USB stick: slot A filled, our device tree, an empty `/storage` |
| `coreelec_<date>_<version>_aarch64_slot.tar` | a slot bundle: slot A of the stick image as its own file, for `am9usb install` (the Host Management page takes the image as well) |
| `*-Generic.img.gz` | CoreELEC's bare Generic image, as upstream publishes it |

After every build, `tests/verify_image.sh` checks what can be checked
without booting.

## Configuration

`/storage` holds no configuration from this build: every default is in the
image, and is put back on every boot where it is missing (a reset profile
gets this build's settings again, not Kodi's). Settings changed on the box
are kept across updates, because an update only writes a slot. `--wipe-storage` on an install resets `/storage`
to what a new stick has.

## Support

This build is focused on one thing: correct playback. If a disc does not
play correctly, open a GitHub issue on this repository with the disc's title
and edition, and what you saw.

- **A disc I own:** I will almost surely fix it.
- **A disc I do not own:** I will probably buy it and fix it, but no
  guarantees.

I do not use the Kodi GUI in my own system and am not working on anything
related to it: skins, library scanning, add-ons, and Kodi's own menus and
settings screens are out of scope. (A disc's own menus are playback, and in
scope.)

**Please report problems with this build only to me.** Not to CoreELEC,
Kodi, SamuriHL, or their forums and issue trackers: they did not make these
changes and cannot support them.

## Security

This build is for a trusted home network. Do not expose the box to the
internet.

- **The Host Management page has no authentication.** It listens on port 80
  on every interface. Anyone who can reach the box can upload a bundle,
  install it, switch slots or reboot.
- **No CSRF protection.** Install, go back and reboot are plain form posts
  with no token, so a web page open in any browser on the same network can
  trigger them. (Upload cannot be triggered this way: it needs a CORS
  preflight the server does not answer.)
- **Bundles are not signed.** The checksums in a bundle's MANIFEST catch a
  corrupted upload, not a malicious one. A bundle's installer runs as root,
  as does an optional extension a bundle may carry (`extra.tar`; release
  bundles carry none).
- **SSH is on by default with CoreELEC's default root password, `coreelec`.**
  Change it with `passwd` on first boot.
- **A USB stick present at boot can supply a kernel module.** `dovi.ko` is
  taken from any FAT32 stick when the box does not already have a valid one.
  The checks are sanity checks, not a signature, so physical access to the
  box means the ability to load kernel code.
- **Samba file sharing is off** in this build (CoreELEC turns it on by
  default). If you turn it on in CoreELEC's settings, turn on Samba password
  authentication and change its password from `coreelec`: unsecured, it
  lets anyone on the network write to the box's configuration as root.
- **AirPlay is off** in this build (CoreELEC turns it on by default). If you
  turn it on, set its password (Services -> AirPlay): without one, any device
  on the network can play to the box.
- **Kodi's web server (JSON-RPC over HTTP) is off** by default. If you turn
  it on to control the box from another system, authentication is on by
  default with username `kodi` and an empty password; set a password.
- **Kodi's EventServer is on, local only** by default: it accepts
  connections from the box itself, not from the network.
- **Zeroconf (Avahi) and WS-Discovery are on**, so the box announces itself
  on the network. This is what makes `symphony-coreelec-0.local` work.

## Credits and licences

- [CoreELEC](https://github.com/CoreELEC/CoreELEC) and
  [LibreELEC](https://github.com/LibreELEC/LibreELEC.tv), on which it is
  built.
- [Kodi](https://github.com/xbmc/xbmc) and CoreELEC's Kodi tree.
- [SamuriHL](https://github.com/SamuriHL/CoreELEC), whose disc-playback work
  this fork carries commit for commit.
- matthane, for the video timestamp check-in fix in the decoder.
- Azul Zulu 8 JRE (BD-J).

Each component keeps its own licence; the fork's own files are GPL-2.0 or
later. Amlogic's `dovi.ko` is not distributed.

**Source code.** Every release names the commit of this repository it was
built from. That commit's `PIN` names the commit of the CoreELEC fork
([alexscotti/CoreELEC](https://github.com/alexscotti/CoreELEC), branch
`symphony`), whose `kodi/package.mk` names the commit of the Kodi fork
([alexscotti/xbmc](https://github.com/alexscotti/xbmc), branch `symphony`).
Every other package's upstream source is named, with its sha256, by its
`package.mk` in the CoreELEC fork. Checksums are published unsigned.
