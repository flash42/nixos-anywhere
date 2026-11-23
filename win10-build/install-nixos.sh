#!/usr/bin/env bash
# 03-install-nixos.sh — run stock nixos-anywhere against the live installer.
#
# The pipeline's "kexec phase" was the one-shot firmware boot performed by
# boot-into-installer.ps1; the machine on the forwarded port already IS the
# installer, so this wrapper only runs the remaining phases (disko, install)
# with unmodified upstream nixos-anywhere. From this script on, the flow is
# indistinguishable from the Linux path.
#
# Wrapper responsibilities (kept explicit for the later refactor):
#   1. build the two target artifacts from the flake:
#        <flake>#nixosConfigurations.<config>.config.system.build.diskoScriptNoDeps
#        <flake>#nixosConfigurations.<config>.config.system.build.toplevel
#   2. preflight: assert the installer answers on the forwarded port with
#      the baked key (fail fast instead of deep inside nixos-anywhere)
#   3. invoke nixos-anywhere with --phases disko,install and --store-paths
#
# Reboot is deliberately NOT in the default phase list: after disko wipes
# the disk, the firmware's normal boot order still lists the (now dead)
# Windows Boot Manager first, and the reboot relies on the firmware falling
# through to the "Linux Boot Manager" entry the installed system's bootctl
# creates (the same fallthrough upstream's Linux test relies on). Reboot
# manually after this script succeeds and watch VNC for the firmware walk.
#
# Usage:
#   ./03-install-nixos.sh -f <flake> -c <config-attr> [-k <identity>] [-p <port>] [-r] [-n <cmd>]
#   ./03-install-nixos.sh -f . -c win10-target
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<EOF
usage: $0 -f <flake> -c <config-attr> [-k <identity>] [-p <port>] [-r] [-n <cmd>]
  -f  flake holding the target config (required): . or /path or github:...
  -c  nixosConfigurations attribute (required), e.g. win10-target
  -k  ssh identity for the installer (default: ~/.ssh/id_ed25519)
  -p  forwarded ssh port (default: 2222)
  -r  also run nixos-anywhere's reboot phase (default: off, reboot manually)
  -n  nixos-anywhere invocation, split on spaces
      (default: nix run github:nix-community/nixos-anywhere --)
EOF
  exit 2
}

FLAKE="" CONFIG="" IDENTITY="$HOME/.ssh/id_ed25519" PORT=2222 REBOOT=0
NA_CMD="nix run github:nix-community/nixos-anywhere --"
while getopts ":f:c:k:p:n:rh" opt; do
  case "$opt" in
    f) FLAKE=$OPTARG ;;
    c) CONFIG=$OPTARG ;;
    k) IDENTITY=$OPTARG ;;
    p) PORT=$OPTARG ;;
    n) NA_CMD=$OPTARG ;;
    r) REBOOT=1 ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# --- hard checks --------------------------------------------------------
[[ -n "$FLAKE" && -n "$CONFIG" ]] || usage
command -v nix >/dev/null || fail "missing dependency: nix"
[[ -r "$IDENTITY" ]] || fail "ssh identity not found (or unreadable): $IDENTITY"
if [[ -z "$PWD" || "$PWD" == "/" || "$PWD" == "$HOME" ]]; then
  fail "refusing to run in '$PWD'; run inside a build directory"
fi
[[ -w "$PWD" ]] || fail "no write access to $PWD"
mkdir -p artifacts

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"

echo "== preflight: is the installer answering on port $PORT? =="
if ! ssh $SSHOPTS -i "$IDENTITY" -p "$PORT" root@127.0.0.1 true 2>/dev/null; then
  fail "key-auth ssh to root@127.0.0.1:$PORT failed. Run 02-run-fixture.sh first and let it finish booting the installer."
fi
echo "   installer is reachable"

echo "== building target artifacts ($FLAKE # $CONFIG) =="
nix build "$FLAKE#nixosConfigurations.$CONFIG.config.system.build.diskoScriptNoDeps" -o artifacts/result-disko
nix build "$FLAKE#nixosConfigurations.$CONFIG.config.system.build.toplevel" -o artifacts/result-system

PHASES="disko,install"
if (( REBOOT )); then PHASES="disko,install,reboot"; fi

echo "== nixos-anywhere: phases=$PHASES =="
IFS=" " read -r -a NA <<< "$NA_CMD"
"${NA[@]}" \
  --phases "$PHASES" \
  --store-paths "$(realpath artifacts/result-disko)" "$(realpath artifacts/result-system)" \
  --ssh-port "$PORT" \
  --ssh-option "IdentityFile=$IDENTITY" \
  --ssh-option "StrictHostKeyChecking=no" \
  --ssh-option "UserKnownHostsFile=/dev/null" \
  root@127.0.0.1

if (( ! REBOOT )); then
  echo
  echo "== DONE: disko + install phases complete =="
  echo "reboot into the installed system:"
  echo "  ssh -i $IDENTITY -p $PORT root@127.0.0.1 systemctl reboot"
  echo "(watch the firmware walk its boot order: vncviewer 127.0.0.1:5900)"
  echo "then verify:"
  echo "  ./04-verify-install.sh -k $IDENTITY -p $PORT"
fi
