#!/usr/bin/env bash
# build-installer.sh — assemble the delivery tree for the dummy.
# Run inside a build directory; every path is relative to $PWD. Rerunnable:
# extraction, payload outputs and delivery dir are rebuilt fresh each run
# (read-only Nix store modes never accumulate), so the cpio append runs
# exactly once per run.
#
# Produces in $PWD/artifacts:
#   artifacts/payload/         installer payload: bzImage, initrd (+pubkey appended),
#                              cmdline.txt, systemd-bootx64.efi
#   artifacts/delivery/        the installer staging tree the runner scps into Windows
#                              and augments with the driver at runtime (run.sh -d):
#                              artifacts/delivery/payload/*, artifacts/delivery/payload.sha256
#   artifacts/payload.sha256   installer identity (4 installer files only,
#                              created AFTER the key append)
#   artifacts/fixture-host-keys/  generated once, reused every run: the installer's
#                              stable host identity (the restore unit installs these
#                              into the booted installer's /etc/ssh)
#   artifacts/tarball.sha256   upstream tarball pin (recorded on first run)
#
# Reads from $PWD/artifacts:
#   artifacts/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz (downloaded
#                              on first run if missing)
#
# Usage:
#   ./build-installer.sh -k ~/.ssh/id_ed25519.pub
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<EOF
usage: $0 -k <ssh-pubkey> [-u <tarball-url>]
  -k  path to the ssh public key appended to the installer initrd (required)
  -u  upstream tarball URL (default: nixos-25.11 noninteractive x86_64)
EOF
  exit 2
}

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
command -v ssh-keygen >/dev/null || fail "missing dependency: ssh-keygen"
if [[ -z "$PWD" || "$PWD" == "/" || "$PWD" == "$HOME" ]]; then
  fail "refusing to run in '$PWD'; run inside a build directory"
fi
[[ -w "$PWD" ]] || fail "no write access to $PWD"
mkdir -p artifacts

TARBALL="artifacts/nixos-kexec-installer-noninteractive-x86_64-linux.tar.gz"
PIN="artifacts/tarball.sha256"
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
KEXEC=artifacts/kexec
rm -rf $KEXEC
tar xzf "$TARBALL" -C artifacts
[[ -f ${KEXEC}/bzImage && -f ${KEXEC}/initrd && -f ${KEXEC}/run ]] || fail "tarball did not contain ${KEXEC}/{bzImage,initrd,run}"

echo "== 3. kernel + cmdline (cmdline verbatim from the tarball's own run script) =="
mkdir -p artifacts/payload
# The Nix store tarball extracts its files read-only (mode 444) and plain cp
# propagates source modes: the first run CREATES artifacts/payload/bzImage 444,
# and any later run's in-place overwrite then dies with Permission denied
# (truncate needs write permission on the file). Rebuild the per-run outputs
# fresh instead of truncating stale read-only copies; the chainloader stays cached.
rm -f artifacts/payload/bzImage artifacts/payload/initrd artifacts/payload/cmdline.txt
cp ${KEXEC}/bzImage artifacts/payload/bzImage
init=$(grep '^init=' ${KEXEC}/run | head -1 | cut -d'"' -f2)
params=$(grep '^kernelParams=' ${KEXEC}/run | head -1 | cut -d'"' -f2)
[[ -n "$init" && -n "$params" ]] || fail "could not extract init/kernelParams from ${KEXEC}/run"
printf 'init=%s %s\n' "$init" "$params" > artifacts/payload/cmdline.txt
echo "   $(cat artifacts/payload/cmdline.txt)"

echo "== 4. initrd + state (kexec-run.sh's append, mirrored file-for-file) =="
before=$(stat -c %s ${KEXEC}/initrd)
cp ${KEXEC}/initrd artifacts/payload/initrd
chmod u+w artifacts/payload/initrd
mkdir -p "$WORK/ssh"
cat "$PUBKEY" > "$WORK/ssh/authorized_keys"
# The installer's restore-state-from-initrd unit runs UNGUARDED globs:
#   install -m 400 ssh/ssh_host_* /sysroot/etc/ssh
#   cp *.json /sysroot/root/network/
# Upstream kexec always ships host keys (harvested from a Linux target) and
# three `ip --json` dumps, so those globs never go empty there. A Windows
# origin has neither, so the whole unit would fail and take rw-etc and
# /sysroot/etc down with it (observed live). Generate fixture host keys and
# inert jsons to give the globs what upstream's environment always had.
# Host keys are generated ONCE per build dir and reused, so the installer
# presents a stable host identity across prep runs (your known_hosts entry
# for [127.0.0.1]:2222 stays valid); regenerating per run would churn it.
if [[ ! -s artifacts/fixture-host-keys/ssh_host_ed25519_key ]]; then
  mkdir -p artifacts/fixture-host-keys
  ssh-keygen -q -t ed25519 -N "" -C win10-nixos-fixture -f artifacts/fixture-host-keys/ssh_host_ed25519_key
fi
cp artifacts/fixture-host-keys/ssh_host_ed25519_key artifacts/fixture-host-keys/ssh_host_ed25519_key.pub "$WORK/ssh/"
printf '{}' > "$WORK/addrs.json"
printf '{}' > "$WORK/routes-v4.json"
printf '{}' > "$WORK/routes-v6.json"
( cd "$WORK" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) >> artifacts/payload/initrd
after=$(stat -c %s artifacts/payload/initrd)
(( after > before )) || fail "append failed: initrd did not grow"
echo "   initrd: $before -> $after bytes (+$((after - before)))"

echo "== 5. chainloader (only nix fetch; cached in artifacts/payload afterwards) =="
if [[ ! -f artifacts/payload/systemd-bootx64.efi ]]; then
  command -v nix >/dev/null || fail "missing dependency: nix (needed once for systemd-bootx64.efi)"
  nix build nixpkgs#systemd --out-link artifacts/result-systemd
  cp artifacts/result-systemd/lib/systemd/boot/efi/systemd-bootx64.efi artifacts/payload/
  rm artifacts/result-systemd
fi

echo "== 6. installer identity: checksum only the 4 installer files =="
( cd artifacts/payload && sha256sum bzImage initrd cmdline.txt systemd-bootx64.efi ) > artifacts/payload.sha256
cat artifacts/payload.sha256

echo "== 7. delivery tree: installer (subdir) + manifest (root) =="
rm -rf artifacts/delivery
mkdir -p artifacts/delivery/payload
cp artifacts/payload/bzImage artifacts/payload/initrd artifacts/payload/cmdline.txt artifacts/payload/systemd-bootx64.efi artifacts/delivery/payload/
cp artifacts/payload.sha256 artifacts/delivery/

echo
echo "== DONE (build dir: $PWD) =="
find artifacts/delivery -type f | sort
echo
echo "next: ./run.sh -b artifacts/win10-base-v1.qcow2 -d boot-into-installer.ps1"
