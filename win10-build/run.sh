#!/usr/bin/env bash
# run.sh — dummy runtime, counterpart to build-installer.sh.
# Boots the pinned Windows fixture, stages artifacts/delivery (installer
# staging tree from build-installer.sh) plus the driver (-d) over SSH, then
# triggers boot-into-installer.ps1. The driver is this script's input, not
# the prep step's: edit the ps1 freely and just rerun, no installer reassembly.
#
# Per-run state lives in artifacts/run/ (disk overlay + NVRAM copy), fresh
# each run: the pinned base image and the OVMF template are never written.
# The VM is left running at the end:
#   - see the guest screen:     vncviewer 127.0.0.1:5900   (loopback VNC)
#   - watch the installer boot:  tail -f artifacts/run/serial.log
#     (artifacts/run/serial.log captures ALL serial output from kernel start:
#      a bare telnet serial drops output while no nc client is attached, the
#      logfile backend does not; nc on the serial port is still available
#      for interactive use)
#   - guest reboots stay inside the same QEMU process (NVRAM persists)
#   - if QEMU dies, relaunch with the SAME artifacts/run files:
#     artifacts/run/vars.fd carries the one-shot BootNext entry; fresh vars
#     would silently boot Windows.
#
# Usage:
#   ./run.sh -b artifacts/win10-base-v1.qcow2 -d boot-into-installer.ps1
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<EOF
usage: $0 -b <win10-base.qcow2> -d <boot-into-installer.ps1>
                  [-c <OVMF_CODE>] [-v <OVMF_VARS>] [-p <ssh-port>]
                  [-s <serial-port>] [-n <vnc-display>] [-m <memory-mb>] [-w <password>]
  -b  pinned Windows base image (required)
  -d  driver: boot-into-installer.ps1 (required, staged fresh on every run)
  -c  OVMF firmware code    (default: /usr/share/OVMF/OVMF_CODE_4M.fd)
  -v  OVMF NVRAM template   (default: /usr/share/OVMF/OVMF_VARS_4M.fd)
  -p  forwarded ssh port     (default: 2222)
  -s  serial telnet port    (default: 4444)
  -n  vnc display number    (default: 0 = port 5900, loopback only)
  -m  guest memory, MB      (default: 4096)
  -w  Administrator password (default: the autounattend one)
EOF
  exit 2
}

OVMF_CODE="/usr/share/OVMF/OVMF_CODE_4M.fd"
OVMF_VARS="/usr/share/OVMF/OVMF_VARS_4M.fd"
SSH_PORT=2222
SERIAL_PORT=4444
VNC_DISPLAY=0
MEM=4096
PASSWORD="Packer42!"
ADMIN="Administrator"
DRIVER=""
BASE=""

while getopts ":b:d:c:v:p:s:m:w:n:h" opt; do
  case "$opt" in
    b) BASE=$OPTARG ;;
    d) DRIVER=$OPTARG ;;
    c) OVMF_CODE=$OPTARG ;;
    v) OVMF_VARS=$OPTARG ;;
    p) SSH_PORT=$OPTARG ;;
    s) SERIAL_PORT=$OPTARG ;;
    n) VNC_DISPLAY=$OPTARG ;;
    m) MEM=$OPTARG ;;
    w) PASSWORD=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# --- hard checks on inputs --------------------------------------------
[[ -n "$BASE" ]] || usage
[[ -n "$DRIVER" ]] || usage
[[ -r "$BASE" ]] || fail "base image not found (or unreadable): $BASE"
[[ -s "$DRIVER" ]] || fail "driver script not found (or empty): $DRIVER"
[[ -r "$OVMF_CODE" ]] || fail "OVMF firmware code not found: $OVMF_CODE"
[[ -r "$OVMF_VARS" ]] || fail "OVMF NVRAM template not found: $OVMF_VARS"
for f in bzImage initrd cmdline.txt systemd-bootx64.efi; do
  [[ -s "artifacts/delivery/payload/$f" ]] || fail "missing artifacts/delivery/payload/$f (run build-installer.sh first)"
done
command -v qemu-system-x86_64 >/dev/null || fail "missing dependency: qemu-system-x86_64"
command -v qemu-img >/dev/null        || fail "missing dependency: qemu-img"
command -v sshpass >/dev/null         || fail "missing dependency: sshpass"
if [[ -z "$PWD" || "$PWD" == "/" || "$PWD" == "$HOME" ]]; then
  fail "refusing to run in '$PWD'; run inside a build directory"
fi
[[ -w "$PWD" ]] || fail "no write access to $PWD"
BASE=$(realpath "$BASE")   # record absolute path: the overlay resolves its
                           # backing file relative to itself, not to $PWD

# --- per-run state: fresh overlay + fresh NVRAM -------------------------
mkdir -p artifacts/run
rm -f artifacts/run/overlay.qcow2 artifacts/run/vars.fd artifacts/run/qemu.pid
qemu-img create -f qcow2 -F qcow2 -b "$BASE" artifacts/run/overlay.qcow2 >/dev/null
cp "$OVMF_VARS" artifacts/run/vars.fd

# --- boot ---------------------------------------------------------------
qemu-system-x86_64 \
  -enable-kvm -m "$MEM" -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
  -drive if=pflash,format=raw,file=artifacts/run/vars.fd \
  -drive file=artifacts/run/overlay.qcow2,if=ide,format=qcow2 \
  -netdev user,id=net0,hostfwd=tcp::${SSH_PORT}-:22 \
  -device e1000,netdev=net0 \
  -chardev socket,id=ser0,host=127.0.0.1,port=${SERIAL_PORT},telnet=on,server=on,wait=off,logfile=artifacts/run/serial.log \
  -serial chardev:ser0 \
  -vnc 127.0.0.1:${VNC_DISPLAY} \
  -display none -daemonize -pidfile artifacts/run/qemu.pid
QEMU_PID=$(cat artifacts/run/qemu.pid)
trap 'rc=$?; if (( rc != 0 )); then kill "$QEMU_PID" 2>/dev/null || true; fi' EXIT

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
echo "== fixture booting (pid $QEMU_PID); waiting for SSH on port $SSH_PORT =="
deadline=$(( SECONDS + 900 ))
until sshpass -p "$PASSWORD" ssh $SSHOPTS -p "$SSH_PORT" "$ADMIN@127.0.0.1" "echo up" >/dev/null 2>&1; do
  kill -0 "$QEMU_PID" 2>/dev/null || fail "QEMU died during boot (check OVMF code/vars pairing, KVM, or a busy ssh/serial/vnc port: ${SSH_PORT}/${SERIAL_PORT}/$((5900 + VNC_DISPLAY)))"
  (( SECONDS < deadline )) || fail "fixture not SSH-ready within 15 min on port $SSH_PORT"
  sleep 5
done
echo "   Windows is up"

# --- stage the delivery tree --------------------------------------------
echo "== staging artifacts/delivery/ (installer) + driver over scp =="
cp "$DRIVER" artifacts/delivery/boot-into-installer.ps1
sshpass -p "$PASSWORD" ssh $SSHOPTS -p "$SSH_PORT" "$ADMIN@127.0.0.1" \
  "powershell -Command \"if (Test-Path C:/Users/Administrator/delivery) { Remove-Item -Recurse -Force C:/Users/Administrator/delivery }\"" >/dev/null || true

# sshpass strips the tty, so scp prints no progress meter while it pushes
# ~500 MB over QEMU user-mode NAT (minutes). Background it and report the
# staged byte count from the Windows side instead. A frozen counter means
# the transfer itself is stalled, not that the script hung.
DELIVERY_BYTES=$(du -sb artifacts/delivery | cut -f1)
echo "   pushing $(( DELIVERY_BYTES / 1024 / 1024 )) MB (progress reports below)"
sshpass -p "$PASSWORD" scp $SSHOPTS -r -P "$SSH_PORT" artifacts/delivery "$ADMIN@127.0.0.1:C:/Users/Administrator/delivery" &
SCP_PID=$!
while kill -0 "$SCP_PID" 2>/dev/null; do
  staged=$(sshpass -p "$PASSWORD" ssh $SSHOPTS -p "$SSH_PORT" "$ADMIN@127.0.0.1" \
    "powershell -Command \"(Get-ChildItem -Recurse C:/Users/Administrator/delivery -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum\"" 2>/dev/null | tr -d '\r')
  if [[ "$staged" =~ ^[0-9]+$ ]]; then
    printf '   staged %d / %d MB\n' "$(( staged / 1024 / 1024 ))" "$(( DELIVERY_BYTES / 1024 / 1024 ))"
  fi
  sleep 15
done
wait "$SCP_PID" || fail "scp of artifacts/delivery/ failed (exit $?)"
echo "   staged at C:/Users/Administrator/delivery"

# --- trigger -------------------------------------------------------------
echo "== triggering boot-into-installer.ps1 =="
timeout 300 sshpass -p "$PASSWORD" ssh $SSHOPTS -p "$SSH_PORT" "$ADMIN@127.0.0.1" \
  "powershell -ExecutionPolicy Bypass -File C:\\Users\\Administrator\\delivery\\boot-into-installer.ps1 -PayloadDir C:\\Users\\Administrator\\delivery\\payload" \
  || echo "   warning: the ssh call returned nonzero - normal if the machine rebooted mid-call (that is success); if the VM is still Windows and never rebooted, investigate via serial/ssh"

echo
echo "== DONE: VM still running (pid $QEMU_PID) =="
echo "see the screen:            vncviewer 127.0.0.1:$((5900 + VNC_DISPLAY))   (loopback VNC, display $VNC_DISPLAY)"
echo "watch the installer boot:  tail -f artifacts/run/serial.log   (full capture from kernel start)"
echo "or interact on serial:     nc 127.0.0.1 $SERIAL_PORT"
echo "once it is up, the installer answers on the same ssh port with the baked key:"
echo "  ssh -p $SSH_PORT root@127.0.0.1"
echo "per-run state: artifacts/run/ (reuse overlay.qcow2 AND vars.fd on any relaunch; vars.fd carries BootNext)"
