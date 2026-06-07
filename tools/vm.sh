#!/usr/bin/env bash
# Launch the Hadron sway-desktop image in QEMU with the CORRECT flags for an
# accurate picture of the real boot.
#
# WHY THIS EXISTS: QEMU's *default* VGA gives a glitchy UEFI framebuffer that
# mangles the kairos boot console into colored static (looks "broken" between
# GRUB and the splash). It's purely a QEMU artifact — on real hardware, or with
# virtio-gpu (what this script uses), the boot renders cleanly. Always launch
# test VMs through this script so we don't trip over that again.
#
# Usage:
#   tools/vm.sh install [ISO]   # fresh disk, boot the installer ISO (then it reboots to disk)
#   tools/vm.sh run             # boot the already-installed disk   (default)
#
# Env knobs (all optional):
#   DISK         disk image path        (default build/vm/disk.qcow2)
#   DISK_SIZE    size for a fresh disk   (default 20G)
#   FRESH=1      recreate the disk even if it exists
#   ISO          installer ISO          (default: newest build/sway-desktop/iso/*.iso)
#   MEM CPUS     guest resources        (default 4096, 4)
#   VNC          VNC display number     (default 10  -> TCP 5910)
#   NOVNC=1      also serve noVNC web    (needs websockify + a noVNC checkout)
#   NOVNC_PORT   noVNC web port         (default 6090)
#   BIND         VNC/noVNC bind address (default 0.0.0.0)
set -euo pipefail

cd "$(dirname "$0")/.."          # repo root
REPO="$PWD"

MODE="${1:-run}"
MEM="${MEM:-4096}"
CPUS="${CPUS:-4}"
VNC="${VNC:-10}"
VNC_PORT=$((5900 + VNC))
NOVNC_PORT="${NOVNC_PORT:-6090}"
BIND="${BIND:-0.0.0.0}"
DISK="${DISK:-build/vm/disk.qcow2}"
DISK_SIZE="${DISK_SIZE:-20G}"

# --- locate OVMF (UEFI firmware) across distros ----------------------------
find_first() { for f in "$@"; do [ -f "$f" ] && { echo "$f"; return; }; done; }
OVMF_CODE="$(find_first \
  /usr/share/OVMF/OVMF_CODE_4M.fd \
  /usr/share/OVMF/OVMF_CODE.fd \
  /usr/share/edk2-ovmf/x64/OVMF_CODE.fd \
  /usr/share/edk2/x64/OVMF_CODE.4m.fd \
  /usr/share/qemu/edk2-x86_64-code.fd)"
OVMF_VARS_TMPL="$(find_first \
  /usr/share/OVMF/OVMF_VARS_4M.fd \
  /usr/share/OVMF/OVMF_VARS.fd \
  /usr/share/edk2-ovmf/x64/OVMF_VARS.fd \
  /usr/share/edk2/x64/OVMF_VARS.4m.fd \
  /usr/share/qemu/edk2-i386-vars.fd)"
[ -n "${OVMF_CODE:-}" ] && [ -n "${OVMF_VARS_TMPL:-}" ] || {
  echo "error: OVMF firmware not found. Install the 'ovmf' (or 'edk2-ovmf') package." >&2
  exit 1
}

mkdir -p build/vm
OVMF_VARS="build/vm/OVMF_VARS.fd"      # per-VM writable copy of the UEFI vars

# --- disk ------------------------------------------------------------------
if [ "${FRESH:-0}" = "1" ] || [ ! -f "$DISK" ]; then
  echo "==> creating fresh disk $DISK ($DISK_SIZE)"
  qemu-img create -f qcow2 "$DISK" "$DISK_SIZE" >/dev/null
  rm -f "$OVMF_VARS"                    # fresh disk -> fresh UEFI vars
fi
[ -f "$OVMF_VARS" ] || cp "$OVMF_VARS_TMPL" "$OVMF_VARS"

# --- mode-specific bits ----------------------------------------------------
CDROM=()
if [ "$MODE" = "install" ]; then
  ISO="${ISO:-$(ls -t "$REPO"/build/sway-desktop/iso/*.iso 2>/dev/null | head -1 || true)}"
  [ -n "${2:-}" ] && ISO="$2"
  [ -n "${ISO:-}" ] && [ -f "$ISO" ] || {
    echo "error: no installer ISO found. Run 'make iso' or pass one: tools/vm.sh install path/to.iso" >&2
    exit 1
  }
  echo "==> install mode, ISO: $ISO"
  # boot the ISO once; subsequent reboots boot the freshly-installed disk
  CDROM=(-cdrom "$ISO" -boot once=d)
elif [ "$MODE" != "run" ]; then
  echo "error: unknown mode '$MODE' (use 'install' or 'run')" >&2
  exit 1
fi

ACCEL=(); [ -e /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)

# Optional QMP control socket (for scripting/screenshots): QMP=/path/to.sock
QMP_ARGS=(); [ -n "${QMP:-}" ] && QMP_ARGS=(-qmp "unix:$QMP,server,nowait")

# --- optional noVNC web proxy ----------------------------------------------
WS_PID=""
cleanup() { [ -n "$WS_PID" ] && kill "$WS_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
if [ "${NOVNC:-0}" = "1" ]; then
  WS="$(command -v websockify || echo "$HOME/.local/bin/websockify")"
  NOVNC_ROOT="$(find_first "$HOME/novnc/vnc.html" /usr/share/novnc/vnc.html /usr/share/webapps/novnc/vnc.html)"
  NOVNC_ROOT="${NOVNC_ROOT%/vnc.html}"
  if [ -x "$WS" ] && [ -n "$NOVNC_ROOT" ]; then
    "$WS" --web "$NOVNC_ROOT" "$BIND:$NOVNC_PORT" "127.0.0.1:$VNC_PORT" >/tmp/hadron-novnc.log 2>&1 &
    WS_PID=$!
    echo "==> noVNC:  http://$(hostname -I 2>/dev/null | awk '{print $1}'):$NOVNC_PORT/vnc.html?autoconnect=1"
  else
    echo "!! NOVNC=1 but websockify or a noVNC checkout was not found; serving plain VNC only." >&2
    echo "   (git clone --depth 1 https://github.com/novnc/noVNC ~/novnc)" >&2
  fi
fi

echo "==> VNC:    $(hostname -I 2>/dev/null | awk '{print $1}'):$VNC_PORT  (display :$VNC)"
echo "==> Ctrl-C in this terminal stops the VM."

# virtio-vga is the whole point — clean UEFI framebuffer, no garbled boot.
exec qemu-system-x86_64 \
  -name hadron-desktop-vm \
  "${ACCEL[@]}" \
  -m "$MEM" -smp "$CPUS" \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,unit=1,file="$OVMF_VARS" \
  -drive if=virtio,format=qcow2,file="$DISK" \
  "${CDROM[@]}" \
  -device virtio-vga \
  -netdev user,id=net0 -device virtio-net-pci,netdev=net0 \
  -audiodev none,id=snd0 -device intel-hda -device hda-output,audiodev=snd0 \
  "${QMP_ARGS[@]}" \
  -vnc "$BIND:$VNC"
