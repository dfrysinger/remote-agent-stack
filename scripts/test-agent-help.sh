#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEMP_ROOT"' EXIT

export HOME="$TEMP_ROOT/home"
export XDG_CONFIG_HOME="$TEMP_ROOT/config"
mkdir -p "$HOME" "$XDG_CONFIG_HOME/remote-agent-stack" "$TEMP_ROOT/bin"
cat > "$XDG_CONFIG_HOME/remote-agent-stack/config" <<'EOF'
SCREEN_SHARING_PORT="16666"
EOF

cat > "$TEMP_ROOT/bin/tailscale" <<'EOF'
#!/bin/bash
if [ "${NO_DNS:-false}" = true ]; then
  printf '%s\n' '{"Self":{"DNSName":""}}'
else
  printf '%s\n' '{"Self":{"DNSName":"test-mac.example.ts.net."}}'
fi
EOF
chmod +x "$TEMP_ROOT/bin/tailscale"

cat > "$TEMP_ROOT/bin/fake-sudo" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$TEMP_ROOT/sudo.log"
shift
shift
case "\${1:-}" in
  on)
    if [ -f "$TEMP_ROOT/omit-helper-port" ]; then
      printf '%s\n' 'CREATED_LEASE=true' 'EXPIRY_EPOCH=4102444800'
    else
      printf '%s\n' 'CREATED_LEASE=true' 'EXPIRY_EPOCH=4102444800' 'SCREEN_SHARING_PORT=16666'
    fi
    ;;
  off) ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TEMP_ROOT/bin/fake-sudo"

export PATH="$TEMP_ROOT/bin:/usr/bin:/bin"
export TAILSCALE_BIN="$TEMP_ROOT/bin/tailscale"
export SS_SUDO_BIN="$TEMP_ROOT/bin/fake-sudo"
export SS_ROOT_HELPER="/fake/ss-on-demand"
printf '%s\n' "SCREEN_SHARING_PORT='17777'" > "$TEMP_ROOT/root-config"
export SS_ROOT_CONFIG_FILE="$TEMP_ROOT/root-config"

RESULT="$("$REPO_ROOT/bin/ss" on 2 --json)"
/usr/bin/python3 -c '
import json, sys
data=json.loads(sys.argv[1])
assert data == {
  "enabled": True,
  "createdLease": True,
  "expiryEpoch": 4102444800,
  "port": 16666,
  "url": "screens://test-mac:16666",
}
' "$RESULT"

"$REPO_ROOT/bin/ss" on --json |
  /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin)["enabled"] is True'

"$REPO_ROOT/bin/ss" off --json |
  /usr/bin/python3 -c 'import json,sys; assert json.load(sys.stdin) == {"enabled": False}'

: > "$TEMP_ROOT/sudo.log"
touch "$TEMP_ROOT/omit-helper-port"
if "$REPO_ROOT/bin/ss" on 1 --json >/dev/null 2>&1; then
  echo "ss accepted incomplete privileged helper output" >&2
  exit 1
fi
rm -f "$TEMP_ROOT/omit-helper-port"
grep -q -- '-n /fake/ss-on-demand on 1' "$TEMP_ROOT/sudo.log"
grep -q -- '-n /fake/ss-on-demand off' "$TEMP_ROOT/sudo.log"

if "$REPO_ROOT/bin/ss" on 9 --json >/dev/null 2>&1; then
  echo "ss accepted an out-of-range lease" >&2
  exit 1
fi

: > "$TEMP_ROOT/sudo.log"
if NO_DNS=true "$REPO_ROOT/bin/ss" on 1 --json >/dev/null 2>&1; then
  echo "ss opened access without a Tailscale DNS identity" >&2
  exit 1
fi
[ ! -s "$TEMP_ROOT/sudo.log" ] || {
  echo "ss called the privileged helper after hostname resolution failed" >&2
  exit 1
}

HELPER_ROOT="$TEMP_ROOT/helper"
mkdir -p "$HELPER_ROOT/state"
cat > "$HELPER_ROOT/config" <<EOF
INSTALL_USER='$(id -un)'
TAILSCALE_BIN='$HELPER_ROOT/tailscale'
SCREEN_SHARING_PORT='16666'
EOF
cat > "$HELPER_ROOT/tailscale" <<EOF
#!/bin/bash
state='$HELPER_ROOT/mapping'
if [ "\${1:-}" = serve ] && [ "\${2:-}" = status ]; then
  [ ! -f '$HELPER_ROOT/fail-status' ] || exit 1
  if [ -f "\$state" ]; then
    target="\$(cat "\$state")"
    [ ! -f '$HELPER_ROOT/prefixed-target' ] || target="tcp://\$target"
    printf '{"TCP":{"16666":{"TCPForward":"%s"}}}\\n' "\$target"
  else
    printf '%s\\n' '{"TCP":{}}'
  fi
elif [ "\${1:-}" = serve ] && [ "\${*: -1}" = off ]; then
  rm -f "\$state"
elif [ "\${1:-}" = serve ]; then
  printf '%s' 'localhost:5900' > "\$state"
else
  exit 2
fi
EOF
cat > "$HELPER_ROOT/launchctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "__LAUNCHCTL_LOG__"
exit 0
EOF
sed -i '' "s|__LAUNCHCTL_LOG__|$HELPER_ROOT/launchctl.log|" "$HELPER_ROOT/launchctl"
cat > "$HELPER_ROOT/noop" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$HELPER_ROOT/tailscale" "$HELPER_ROOT/launchctl" "$HELPER_ROOT/noop"

HELPER_ENV=(
  SS_ON_DEMAND_TEST_MODE=true
  SS_ON_DEMAND_CONFIG_FILE="$HELPER_ROOT/config"
  SS_ON_DEMAND_STATE_DIR="$HELPER_ROOT/state"
  SS_ON_DEMAND_SS_PLIST="$HELPER_ROOT/screensharing.plist"
  SS_ON_DEMAND_LAUNCHCTL_BIN="$HELPER_ROOT/launchctl"
  SS_ON_DEMAND_ARD_KICKSTART="$HELPER_ROOT/noop"
  SS_ON_DEMAND_LOGGER_BIN="$HELPER_ROOT/noop"
)

env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" on 1 > "$HELPER_ROOT/on.out"
grep -q '^CREATED_LEASE=true$' "$HELPER_ROOT/on.out"
[ -f "$HELPER_ROOT/mapping" ]
[ -f "$HELPER_ROOT/state/screen-sharing-lease" ]
[ "$(stat -f %Lp "$HELPER_ROOT/state/screen-sharing.lock")" = "600" ]

touch "$HELPER_ROOT/prefixed-target"
env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" on 1 > "$HELPER_ROOT/prefixed.out"
grep -q '^CREATED_LEASE=false$' "$HELPER_ROOT/prefixed.out"
rm -f "$HELPER_ROOT/prefixed-target"

env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" on 2 > "$HELPER_ROOT/extend.out"
grep -q '^CREATED_LEASE=false$' "$HELPER_ROOT/extend.out"

# A watchdog tick before the deadline must preserve the active lease.
env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" expire
[ -f "$HELPER_ROOT/mapping" ]
[ -f "$HELPER_ROOT/state/screen-sharing-lease" ]

# Once the absolute deadline has passed, the same tick removes both surfaces.
printf '%s\n' 'EXPIRY_EPOCH=1' > "$HELPER_ROOT/state/screen-sharing-lease"
touch "$HELPER_ROOT/fail-status"
if env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" expire >/dev/null 2>&1; then
  echo "helper discarded a lease while Tailscale mapping state was unknown" >&2
  exit 1
fi
[ -f "$HELPER_ROOT/mapping" ]
[ -f "$HELPER_ROOT/state/screen-sharing-lease" ]
grep -q 'disable system/com.apple.screensharing' "$HELPER_ROOT/launchctl.log"
rm -f "$HELPER_ROOT/fail-status"
env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" expire
[ ! -f "$HELPER_ROOT/mapping" ]
[ ! -f "$HELPER_ROOT/state/screen-sharing-lease" ]

printf '%s' 'localhost:6000' > "$HELPER_ROOT/mapping"
if env "${HELPER_ENV[@]}" "$REPO_ROOT/libexec/ss-on-demand" on 1 >/dev/null 2>&1; then
  echo "helper overwrote a foreign Tailscale port mapping" >&2
  exit 1
fi
[ "$(cat "$HELPER_ROOT/mapping")" = "localhost:6000" ]
[ ! -f "$HELPER_ROOT/state/screen-sharing-lease" ]

grep -q '^  PATH=/usr/bin:/bin:/usr/sbin:/sbin$' "$REPO_ROOT/libexec/ss-on-demand"
grep -q "Defaults!%s secure_path=/usr/bin:/bin:/usr/sbin:/sbin" "$REPO_ROOT/install.sh"

SUDOERS_TEST="$TEMP_ROOT/ss-on-demand.sudoers"
{
  printf '%s\n' 'Defaults!/usr/local/libexec/ss-on-demand secure_path=/usr/bin:/bin:/usr/sbin:/sbin'
  printf '%s ALL=(root) NOPASSWD:' "$(id -un)"
  separator=' '
  for hours in 1 2 3 4 5 6 7 8; do
    printf '%s/usr/local/libexec/ss-on-demand on %s' "$separator" "$hours"
    separator=', '
  done
  printf '%s\n' ', /usr/local/libexec/ss-on-demand off'
} > "$SUDOERS_TEST"
chmod 0440 "$SUDOERS_TEST"
/usr/sbin/visudo -c -f "$SUDOERS_TEST" >/dev/null

echo "agent-help shell tests passed"
