# Sway desktop on Hadron

A full [Sway](https://swaywm.org/) Wayland desktop built on top of the minimal
[Hadron](https://github.com/kairos-io/hadron) base image, with NetworkManager,
PipeWire audio, wifi and bluetooth. Everything is compiled from source against
the Hadron musl toolchain in a single multi-stage `Dockerfile`.

The repo is self-contained (single `Dockerfile`, a `rootfs/` overlay, a `test/`
harness) and depends only on the published Hadron images
(`ghcr.io/kairos-io/hadron{,-toolchain}:main`) — no Hadron source checkout needed.

> Status: built incrementally — see the milestone table below.

## What's inside

- **Compositor:** Sway (wlroots), running under **systemd-logind** seat
  management — `ly` logs a user in on `tty1`, launching Sway, and `pam_systemd`
  registers a logind session that grants DRM/input device access.
- **Terminal:** `foot`.
- **Display stack:** wayland, wlroots, Mesa, libinput, libxkbcommon, pixman,
  pango/cairo, freetype/fontconfig (+ DejaVu fonts).
- **Networking:** NetworkManager + wpa_supplicant (wifi).
- **Audio:** PipeWire + WirePlumber.
- **Bluetooth:** BlueZ.
- **Desktop polish:** waybar, mako, fuzzel, wl-clipboard, slurp, swayidle.
- **Real-hardware firmware:** optional curated `linux-firmware` subset
  (`--build-arg FIRMWARE=true`).
- **Hardware GL:** optional Mesa `iris`/`radeonsi` (`--build-arg GPU=full`).

## Build

```sh
make            # build the image + the installer ISO
make image      # just the image (extends ghcr.io/kairos-io/hadron:main)
make iso        # just the ISO (AuroraBoot)
```

## Try it in a VM

```sh
make vm-install   # fresh disk, boot the newest installer ISO (then it reboots to disk)
make vm           # boot the already-installed disk
```

Both call `tools/vm.sh`, which launches QEMU with UEFI (OVMF) **and virtio-gpu**.
Use it rather than a hand-rolled `qemu-system-x86_64` line: QEMU's *default* VGA
gives a glitchy UEFI framebuffer that mangles the boot console into colored
static (a QEMU artifact, not an image bug — real hardware renders fine).
Connect over VNC (`<host>:5910`); set `NOVNC=1` for a browser client. See the
header of `tools/vm.sh` for knobs (`MEM`, `VNC`, `FRESH=1`, `ISO=…`, …).

The Kairos init layer is folded into the Dockerfile's final stage, so a plain
`docker build -t sway-desktop:dev .` already produces a bootable artifact
AuroraBoot can turn into an ISO (build `--target default` for the bare desktop
image without it).

## Run on real hardware

The image is a bootable Kairos/Hadron OS image. Build an ISO/disk with AuroraBoot
(`make iso`) and install it to a machine. On boot it autologins the `sway` user
on `tty1` and starts Sway. (Real wifi/bluetooth/audio require the
`linux-firmware` blobs — see milestone M6.)

## Test (headless, autonomous)

The `test/` harness builds the image, builds a bootable ISO
with AuroraBoot, boots it headless in QEMU, and asserts that the desktop and each
subsystem come up — entirely without a display. It exercises even wifi and
bluetooth using virtual kernel devices (`mac80211_hwsim`, `hci_vhci`).

```sh
# Run all assertions up to a given milestone (default M0)
MILESTONE=M1 test/run.sh

# Faster iteration
SKIP_BUILD=1 test/run.sh   # reuse built images
SKIP_ISO=1   test/run.sh   # reuse existing ISO
```

The guest emits `SWAYTEST: PASS/FAIL <name>` markers on the serial console; the
harness parses them and exits non-zero on any failure. Screenshots captured with
`grim` are written to a scratch disk and extracted to `test/artifacts/`.

### Users and login

The image bakes in **no user**. The desktop user is created at install time and
lives on the persistent `/home`. On boot the **`ly`** display manager (TUI, on
tty1) authenticates that user and launches the Sway session
(`/usr/share/wayland-sessions/sway.desktop` → `start-sway`), giving Sway a
proper logind seat session and the DRM/KMS backend.

There are two ways to create that user:

- **Interactive installer (default).** Boot the live ISO with nothing else and a
  small wizard (`/usr/local/bin/sway-install`, wired in via
  `system/oem/90_sway_installer.yaml`) prompts on tty1 for **hostname, username,
  password, and target disk**, assigns the desktop groups (admin, audio, video,
  render, input, bluetooth, seat), hashes the password (`openssl passwd -6`),
  writes the cloud-config, and installs.
- **Unattended cloud-config.** Provide a `cloud-config.yaml` (`users:`/`install:`
  block — see the example file) via AuroraBoot `--cloud-config` or a datasource.
  When one is present the wizard detects it and runs the normal unattended
  install instead of prompting — so CI and automated installs are unaffected.

### Production vs test launch

`ly`'s interactive TUI login can't be driven over a headless VT, and headless
QEMU has no active VT / `virtio-gpu` gets zero scanouts (`-display none`). So the
**test image** (via `test/Dockerfile.test`) creates a throwaway user, **masks
`ly`**, and launches Sway from a dedicated `sway-headless.service` using the
wlroots **headless backend + pixman** renderer — the canonical way Sway is
exercised in CI. The harness still asserts `ly` is installed and wired up. The
real `ly` → DRM login path is validated on physical hardware.

## Milestones

All green and verified by the headless harness (M6's firmware blobs excepted —
those are hardware-validated):

| # | Scope | Autonomous test |
|---|-------|-----------------|
| M0 | e2e QEMU harness | boot, serial markers, scratch-disk round-trip |
| M1 | Sway + logind seat + foot | logind session, `swaymsg`, active output, grim screenshot |
| M2 | NetworkManager + wifi | DHCP on virtio-net + `mac80211_hwsim`/hostapd association |
| M3 | PipeWire + WirePlumber | user services up, `wpctl` sink from emulated HDA |
| M4 | BlueZ bluetooth | virtual adapter via `hci_vhci`+`btvirt`, `bluetoothctl`, bluez5 plugin |
| M5 | Desktop polish | swaybar, mako, fuzzel, wl-clipboard, slurp, swayidle |
| M6 | Real-hardware firmware | `regulatory.db` present; vendor blobs via `--build-arg FIRMWARE=true` (manual HW validation) |

### Real hardware

The default image is VM-slim. For real laptops, build with the firmware subset:

```sh
docker build --build-arg FIRMWARE=true -t sway-desktop:hw .
```

This bundles a curated `linux-firmware` subset (iwlwifi, ath, rtw, brcm, intel
bluetooth, i915, amdgpu, …) into `/lib/firmware`. Wifi/BT/audio on real hardware
is validated by booting on a physical machine.

### Hardware GPU (accelerated GL)

The default Mesa build (`GPU=vm`) ships only software/virtual drivers
(virgl/softpipe/svga) — correct for QEMU and needs nothing from LLVM. For
accelerated GL on real Intel/AMD laptops, build with `GPU=full`:

```sh
docker build --build-arg GPU=full --build-arg FIRMWARE=true \
  -t sway-desktop:hw .
```

`GPU=full` builds Mesa `iris` (Intel) + `radeonsi` (AMD), which require LLVM.
The example builds its **own** LLVM/clang/libclc + SPIRV stack on top of the
published `hadron-toolchain` (same musl ABI — no Alpine cross-mix) as dedicated
stages in this Dockerfile, so **the main Hadron toolchain is never touched and
no extra orchestration is needed** — a plain `docker build` is enough. Those
stages are gated: for `GPU=vm` (the default) BuildKit prunes them, so a normal
build never compiles LLVM.

For the hardware path the example flips `-Dllvm=true`, sets `-Dcpp_rtti=false`
(its libLLVM is built without RTTI), and bundles `libLLVM.so` + `libelf.so` into
the image (the megadriver links them at runtime, ~125 MB). Building LLVM adds
~15–20 min to the `GPU=full` build.

Validated: Mesa 25.3 builds `iris`/`radeonsi`/`virgl`/`softpipe` into
`libgallium-25.3.0.so` against the example-built libLLVM, the megadriver resolves
all runtime symbols, and the resulting ISO boots. Actual GPU *rendering* is
validated on physical hardware — QEMU has no real GPU, so a VM boot falls back to
softpipe/virgl (software) while the hardware drivers ride along for real metal.

## Layout

```
hadron-desktop/
  Dockerfile          # multi-stage build of the whole desktop stack
  cloud-config.yaml   # example Kairos install config (creates the desktop user)
  rootfs/             # overlay: sway config, ly session entry, launcher, env
  test/
    run.sh            # build -> kairos -> ISO -> QEMU -> assert
    Dockerfile.test   # injects in-guest test instrumentation
    guest/check.sh    # in-guest assertions (emit SWAYTEST: markers)
    artifacts/        # console logs + screenshots (gitignored)
```
