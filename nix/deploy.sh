#!/usr/bin/env bash
# Ship Hireme to fsn1-2: the release (the node + the WebTransport gate) and,
# with --switch, the host configuration that runs it.
#
# The workstation builds the release from this flake at a pushed revision,
# read from this checkout (the repository is private, so nothing fetches
# from GitHub), runs its dev check (checks.dev: a VM, and the /mcp outage
# of 2026-10-20 replayed through the module's nginx; a revision that fails
# it never ships, and there is no flag to skip it: an emergency is a profile
# rollback), copies the closures over the YubiKey SSH master, and on
# the host: takes an online SQLite backup, flips
# /nix/var/nix/profiles/hireme, switches the system when asked, and restarts
# hireme (the node migrates at boot, drains its sessions on the way down and
# runs the gate itself), then proves the result from outside. An exit status
# of zero means the public names serve this revision.
#
# The host is nixos-server's fsn1-2 (NIXOS_SERVER, default
# ~/workspace/nixos-server), which imports nixosModules.hireme; its
# hetzner-master holds the SSH session.
#
#   $NIXOS_SERVER/scripts/hetzner-master fsn1-2 open   # in your own shell: asks for the FIDO2 PIN
#   nix/deploy.sh                  # origin/main, release only
#   nix/deploy.sh --switch         # also build and switch the host
#   nix/deploy.sh --ref <rev>      # another pushed revision
#   nix/deploy.sh --build-only     # steps 1-2 only; no SSH, no host
#
# Rollback: ssh root@HOST nix-env --profile /nix/var/nix/profiles/hireme --rollback,
# then systemctl restart hireme. A rollback does not undo
# migrations; restore the backup this run took (its path is printed).
set -euo pipefail

target=${TARGET:-root@49.12.102.5}
ref=${REF:-main}
outLink=${HIREME_OUT_LINK:-$HOME/tmp/hireme-release}
hostAttr=hetzner-fsn1-2
domain=hireme.anghel4d.com
gateUrl=https://wt.hireme.anghel4d.com/wt
profile=/nix/var/nix/profiles/hireme
lockFile=${TMPDIR:-/tmp}/hireme-deploy.lock
switch=0
buildOnly=0

repo="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
server=${NIXOS_SERVER:-$HOME/workspace/nixos-server}

while (($#)); do
  case $1 in
    --ref) ref=$2; shift 2 ;;
    --switch) switch=1; shift ;;
    --build-only) buildOnly=1; shift ;;
    -h | --help) sed -n '2,25p' "$0"; exit 0 ;;
    *) printf 'unknown argument %s\n' "$1" >&2; exit 2 ;;
  esac
done

say() { printf '[hireme] %s\n' "$*"; }
die() { say "FAILED: $*"; exit 1; }

exec 9>"$lockFile"
flock --nonblock 9 || die "another deploy holds $lockFile"

if ((!buildOnly)); then
  socket=$("$server/scripts/hetzner-master" fsn1-2 path)
  "$server/scripts/hetzner-master" fsn1-2 check >/dev/null 2>&1 || die "no SSH master; run $server/scripts/hetzner-master fsn1-2 open"
  sshOpts=(-F /dev/null -S "$socket" -o ControlMaster=no)
  export NIX_SSHOPTS="-F /dev/null -S $socket -o ControlMaster=no"
fi
remote() { ssh "${sshOpts[@]}" "$target" "$@"; }

# 1. A pushed revision.
git -C "$repo" fetch --quiet origin "$ref"
rev=$(git -C "$repo" rev-parse FETCH_HEAD)
short=${rev:0:12}
say "revision $short"
flake="git+file://$repo?rev=$rev"

# 2. Build the release here, and the host when switching; check the revision.
nix build -o "$outLink" "$flake#hireme"
release=$(readlink -f "$outLink")
test -x "$release/bin/hireme" -a -x "$release/bin/hireme-gate" || die "$release lacks bin/hireme or bin/hireme-gate"
say "release $release"
if ((switch)); then
  system=$(nix build --no-link --print-out-paths --override-input hireme "$flake" "$server#nixosConfigurations.$hostAttr.config.system.build.toplevel")
  say "system $system"
fi
nix build --no-link "$flake#checks.x86_64-linux.dev" || die "the dev check failed at $short; nix log names why"
say "dev check passed"

if ((buildOnly)); then
  say "built only; nothing shipped"
  exit 0
fi

# 3. Ship the closures. Local builds are unsigned, so the target is told to
#    accept them.
nix copy --no-check-sigs --to "ssh-ng://$target" "$release" ${system:+"$system"}

# 4. Back up, flip, switch, restart.
# The running node backs itself up on request. It is named on loopback
# (hireme@127.0.0.1); a node from before that was named by its host, so the
# call falls back to that once.
remote "rpc() { systemd-run --quiet --wait --pipe --uid=hireme --gid=hireme -p EnvironmentFile=/run/agenix/hireme-env \
    -E HOME=/var/lib/hireme -E RELEASE_TMP=/var/lib/hireme/tmp \"\$@\" \
    $profile/bin/hireme rpc '{:ok, _} = Hireme.Release.Backup.run()'; }
  { rpc -E ERL_EPMD_ADDRESS=127.0.0.1 -E RELEASE_DISTRIBUTION=name -E RELEASE_NODE=hireme@127.0.0.1 || rpc; } &&
  ls -1t /var/lib/hireme/backups | head -1" |
  sed 's/^/[hireme] backup /'
remote "nix-env --profile $profile --set $release"
if ((switch)); then
  remote "nix-env --profile /nix/var/nix/profiles/system --set $system && $system/bin/switch-to-configuration switch"
fi
remote 'systemctl restart hireme.service'

# 5. Prove it from outside, not from the commands that ran.
for _ in $(seq 1 30); do
  remote 'systemctl is-active --quiet hireme' && break
  sleep 2
done
remote 'systemctl is-active hireme' | sed 's/^/[hireme] unit /'
[ "$(remote "readlink -f $profile")" = "$release" ] || die "the profile does not resolve to $release"
remote "journalctl -u hireme --since '-2 min' -p err --no-pager -q" | head -20 | sed 's/^/[hireme] error: /'
remote "ss -Hulpn 'sport = :4433'" | sed 's/^/[hireme] udp: /'

code=""
for _ in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://$domain/sign-in") || true
  [ "$code" = 200 ] && break
  sleep 2
done
[ "$code" = 200 ] || die "https://$domain/sign-in answered $code"
say "https://$domain answers 200"

# The checkout's probe (build output, kept between deploys).
probe="$repo/native/target/release/examples/probe"
[ -x "$probe" ] || cargo build --quiet --release -p gate --example probe --manifest-path "$repo/native/Cargo.toml"
"$probe" handshake "$gateUrl" --n 3 | sed 's/^/[hireme] gate: /' || die "the gate did not accept a WebTransport session"

say "done: $short live on https://$domain and $gateUrl"
