#!/usr/bin/env bash
# 04-verify-install.sh — post-install assertions.
#
# Waits for the THIRD tenant of the forwarded port (the installed system's
# sshd, which comes up after the firmware reboot), then asserts the machine
# booted the EXACT system 03 installed:
#     readlink -f /run/current-system == the result-system built by 03
# os-release alone cannot make this assertion: the installer is also NixOS.
# The toplevel comparison is the real acceptance criterion (handoff doc:
# "the VM boots into the NixOS system-to-install toplevel").
#
# Usage:
#   ./04-verify-install.sh [-k <identity>] [-p <port>] [-t <timeout-sec>] [-s <result-system>]
set -euo pipefail

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  cat <<EOF
usage: $0 [-k <identity>] [-p <port>] [-t <timeout-sec>] [-s <result-system>]
  -k  ssh identity (default: ~/.ssh/id_ed25519)
  -p  forwarded ssh port (default: 2222)
  -t  how long to wait for the installed system (default: 900 s)
  -s  the toplevel 03 built (default: artifacts/result-system)
EOF
  exit 2
}

IDENTITY="$HOME/.ssh/id_ed25519" PORT=2222 TIMEOUT=900 SYSTEM="artifacts/result-system"
while getopts ":k:p:t:s:h" opt; do
  case "$opt" in
    k) IDENTITY=$OPTARG ;;
    p) PORT=$OPTARG ;;
    t) TIMEOUT=$OPTARG ;;
    s) SYSTEM=$OPTARG ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

# --- hard checks --------------------------------------------------------
[[ -e "$SYSTEM" ]] || fail "toplevel artifact not found: $SYSTEM (run 03-install-nixos.sh first, or pass -s)"
[[ -r "$IDENTITY" ]] || fail "ssh identity not found (or unreadable): $IDENTITY"

# --- agent: at most ONE passphrase per run -------------------------------
# The polling loop would otherwise prompt for the key passphrase on every
# iteration. rc 2 from `ssh-add -l` means no agent is reachable at all
# (fresh shell / other tab without SSH_AUTH_SOCK); then a private agent is
# started for this run and torn down at exit. An ambient agent holding the
# key makes this whole section a silent no-op.
rc=0; ssh-add -l >/dev/null 2>&1 || rc=$?
if (( rc == 2 )); then
  eval "$(ssh-agent -s)" >/dev/null
  trap 'ssh-agent -k >/dev/null 2>&1 || true' EXIT
fi
ssh-add "$IDENTITY" || fail "could not load $IDENTITY into the agent (wrong passphrase?)"

SSHOPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
# multiplexing: one key passphrase per script run, not one per iteration of
# the polling loop; the master socket survives tenant changes (after the
# reboot the dead socket is taken over by a fresh connection automatically)
CTRL="-o ControlMaster=auto -o ControlPath=$PWD/artifacts/.ssh-ctl-%r-%h-%p -o ControlPersist=120"
expected=$(readlink -f "$SYSTEM")

echo "== waiting up to $TIMEOUT s for the installed system on port $PORT =="
echo "   expected toplevel: $expected"
deadline=$(( SECONDS + TIMEOUT ))
cur=""
while :; do
  cur=$(ssh $SSHOPTS $CTRL -i "$IDENTITY" -p "$PORT" root@127.0.0.1 "readlink -f /run/current-system" 2>/dev/null) || cur=""
  if [[ "$cur" == "$expected" ]]; then
    echo "   booted system:  $cur"
    break
  fi
  if (( SECONDS > deadline )); then
    fail "timeout: port $PORT never reported the expected toplevel.
  expected:  $expected
  last seen: ${cur:-<no answer>}
Did the machine actually reboot after 03 finished, and does VNC (127.0.0.1:5900) show a stuck boot menu?"
  fi
  sleep 10
done

echo "== booted system identity =="
ssh $SSHOPTS $CTRL -i "$IDENTITY" -p "$PORT" root@127.0.0.1 "head -3 /etc/os-release; uname -a"
echo
echo "== PASS: acceptance criterion met — the machine boots system-to-install =="
