#!/usr/bin/env bash

# Build installer with public key
#
# Produces in $PWD:
#   ./installer-image/         installer installer-image: bzImage, initrd (+pubkey appended),
#                      cmdline.txt, systemd-bootx64.efi
#   ./delivery/        what the VM receives on drive D::
#   ./installer-image.sha256   installer identity (4 installer files only,
#   ./tarball.sha256   upstream tarball pin (recorded on first run)
#
# Usage:
#   ./build-installer.sh -k ~/.ssh/id_ed25519.pub -s
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<EOF
usage: $0 -k <ssh-pubkey> -s <driver.ps1> [-u <tarball-url>]
  -k  path to the ssh public key appended to the installer initrd (required)
  -u  upstream tarball URL (default: nixos-25.11 noninteractive x86_64)
EOF
  exit 2
}

mkdir -p artifacts
cd artifacts
URL="https://github.com/nix-community/nixos-images/releases/download/nixos-25.11/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"
PUBKEY=""
while getopts ":k:u:h" opt; do
  case "$opt" in
    k) PUBKEY=$OPTARG ;;
    u) URL=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# --- hard checks on inputs --------------------------------------------
[[ -n "$PUBKEY" ]] || usage
[[ -s "$PUBKEY" ]] >/dev/null 2>&1 || fail "ssh pubkey not found (or empty): $PUBKEY"
grep -qE '^(ssh|ecdsa|sk)-[A-Za-z0-9]+ ' "$PUBKEY" || fail "does not look like an ssh public key: $PUBKEY"

command -v cpio >/dev/null || fail "missing dependency: cpio"
if [[ -z "$PWD" || "$PWD" == "/" || "$PWD" == "$HOME" ]]; then
  fail "refusing to run in '$PWD'; run inside a build directory"
fi
[[ -w "$PWD" ]] || fail "no write access to $PWD"

TARBALL="./nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"
PIN="./tarball.sha256"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo "== 1. upstream tarball: reuse if present, verify against the pin =="
if [[ ! -f "$TARBALL" ]]; then
  command -v curl >/dev/null || fail "missing dependency: curl (or pre-download $TARBALL)"
  curl -fL --retry 3 -o "$TARBALL" "$URL"
fi
if [[ -f "$PIN" ]]; then
  sha256sum -c "$PIN"
else
  sha256sum "$TARBALL" | tee "$PIN"
  echo "^ pin recorded (one-time); keep this file with the build records"
fi

echo "== 2. fresh extraction (dodges the read-only-overwrite wall) =="
rm -rf kexec
tar xzf "$TARBALL"
[[ -f kexec/bzImage && -f kexec/initrd && -f kexec/run ]] || fail "tarball did not contain kexec/{bzImage,initrd,run}"

echo "== 3. kernel + cmdline (cmdline verbatim from the tarball's own run script) =="
mkdir -p installer-image
rm -f installer-image/*
cp kexec/bzImage installer-image/bzImage
init=$(grep '^init=' kexec/run | head -1 | cut -d'"' -f2)
params=$(grep '^kernelParams=' kexec/run | head -1 | cut -d'"' -f2)
[[ -n "$init" && -n "$params" ]] || fail "could not extract init/kernelParams from kexec/run"
printf 'init=%s %s\n' "$init" "$params" > installer-image/cmdline.txt
echo "   $(cat installer-image/cmdline.txt)"

echo "== 4. initrd + pubkey (upstream kexec-run.sh's own mechanism, writable copy, once) =="
before=$(stat -c %s kexec/initrd)
cp kexec/initrd installer-image/initrd
chmod u+w installer-image/initrd
mkdir -p "$WORK/ssh"
cat "$PUBKEY" > "$WORK/ssh/authorized_keys"
( cd "$WORK" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) >> installer-image/initrd
after=$(stat -c %s installer-image/initrd)
(( after > before )) || fail "append failed: initrd did not grow"
echo "   initrd: $before -> $after bytes (+$((after - before)))"

echo "== 5. chainloader (only nix fetch; cached in ./installer-image afterwards) =="
if [[ ! -f installer-image/systemd-bootx64.efi ]]; then
  command -v nix >/dev/null || fail "missing dependency: nix (needed once for systemd-bootx64.efi)"
  nix build nixpkgs#systemd --out-link ./result-systemd
  cp ./result-systemd/lib/systemd/boot/efi/systemd-bootx64.efi installer-image/
  rm ./result-systemd
fi

echo "== 6. delivery disk: installer installer-image (subdir) + driver (root) =="
rm -rf delivery
mkdir -p delivery/installer-image
cp installer-image/bzImage installer-image/initrd installer-image/cmdline.txt installer-image/systemd-bootx64.efi delivery/installer-image/

echo "== 7. installer identity: checksum"
( cd installer-image && sha256sum bzImage initrd cmdline.txt systemd-bootx64.efi ) > ./installer-image.sha256
cat ./installer-image.sha256

echo
echo "== DONE (build dir: $PWD) =="
find delivery -type f | sort
echo
echo '1) boot the pinned Windows image with the delivery disk attached:'
echo "     -drive file=fat:rw:$PWD/delivery,format=raw,if=virtio \\"
echo '     -serial telnet:127.0.0.1:4444,server,nowait'
echo '2) once Windows is up, trigger (check drive letter via: wmic logicaldisk get name):'
echo '     ssh -p 2222 Administrator@127.0.0.1 "powershell -ExecutionPolicy Bypass -File D:\boot-into-installer.ps1 -Installer-ImageDir D:\installer-image"'
echo '3) watch serial:'
echo '     nc 127.0.0.1 4444'
