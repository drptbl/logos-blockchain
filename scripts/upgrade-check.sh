#!/usr/bin/env bash
set -euo pipefail

# Checks that a node built from this tree can take over the data directory of
# an earlier release, the way an operator upgrades.
#
#   scripts/upgrade-check.sh <old-node-binary> <new-node-binary> [<work-dir>]
#
# The old binary writes a config and keystore with `init-config` and runs once,
# so the data directory holds what that release really writes, not a checked-in
# fixture. Then the new binary runs on the same directory. Checks:
# - the keystore is byte-identical afterwards;
# - the new build loads the upgraded config;
# - on the same genesis, the new node starts on the old state and keeps that
#   genesis. A new genesis needs a fresh state, so there the old state is only
#   reported;
# - every 64-hex-digit value (public keys, key ids) in the effective config of
#   the upgraded node (`--show-config`) sits in the same field in a fresh config
#   the new build derives from the same keystore, so no key from an old
#   derivation stays in use.
#
# Nodes run one at a time with `--skip-ibd`, no peers and random loopback ports.
# A node without peers stays at its genesis block.
#
# Exit codes:
# - 0: the upgrade passed every check.
# - 1: a check failed.
# - 255: internal/tooling error.

FAILURE_DETECTED_EXIT_CODE=1
INTERNAL_ERROR_EXIT_CODE=255
START_TIMEOUT=120

trap 'echo "error: command failed at line $LINENO" >&2; exit "$INTERNAL_ERROR_EXIT_CODE"' ERR

if [ $# -lt 2 ]; then
  echo "usage: $0 <old-node-binary> <new-node-binary> [<work-dir>]" >&2
  exit "$INTERNAL_ERROR_EXIT_CODE"
fi

for bin in "$1" "$2"; do
  [ -x "$bin" ] || {
    echo "error: $bin is not an executable file" >&2
    exit "$INTERNAL_ERROR_EXIT_CODE"
  }
done
old_bin=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
new_bin=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
work_dir=${3:-$(mktemp -d)}
mkdir -p "$work_dir"
work_dir=$(cd "$work_dir" && pwd)

port_base=$((20000 + RANDOM % 20000))
net_port=$port_base
blend_port=$((port_base + 1))
api="http://127.0.0.1:$((port_base + 2))"

upgraded="$work_dir/upgraded"
fresh="$work_dir/fresh"
node_pid=""

failed=0
fail() {
  echo "FAIL: $*"
  failed=1
}

die() {
  echo "error: $*" >&2
  exit "$INTERNAL_ERROR_EXIT_CODE"
}

note() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::notice::$*"; else echo "note: $*"; fi
}

stop_node() {
  [ -n "$node_pid" ] || return 0
  kill -INT "$node_pid" 2>/dev/null || true
  for _ in $(seq 30); do
    kill -0 "$node_pid" 2>/dev/null || break
    sleep 1
  done
  kill -KILL "$node_pid" 2>/dev/null || true
  wait "$node_pid" 2>/dev/null || true
  node_pid=""
}
trap stop_node EXIT

sha() {
  sha256sum "$1" | cut -d' ' -f1
}

version() {
  "$1" --version | head -n 2 | tr '\n' ' '
}

# init_config <binary> <dir>: a config in <dir>, reusing <dir>/keystore.yaml if
# it exists.
init_config() {
  "$1" init-config -o "$2/user_config.yaml" --skip-ibd \
    --net-port "$net_port" \
    --blend-addr "/ip4/127.0.0.1/udp/$blend_port/quic-v1" \
    --http-host "${api#http://}" \
    --state-path "$2/state" --storage-path "$2/db" \
    >"$2/init-config.log" 2>&1 || {
    cat "$2/init-config.log" >&2
    die "$1 init-config failed"
  }
}

# run_node <binary> <dir> <label>: run the node on <dir>/user_config.yaml until
# its API answers, save its chain info to $work_dir/<label>.json and stop it.
# Returns 1 when the node exits or hangs before its API answers.
run_node() {
  local log="$work_dir/$3.log" info=""
  if curl -fsS -m 2 "$api/cryptarchia/info" >/dev/null 2>&1; then
    die "something already answers on $api"
  fi
  (cd "$2" && exec "$1" "$2/user_config.yaml") >"$log" 2>&1 &
  node_pid=$!
  local deadline=$((SECONDS + START_TIMEOUT))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if ! kill -0 "$node_pid" 2>/dev/null; then
      wait "$node_pid" 2>/dev/null || true
      node_pid=""
      echo "$3 node exited before its API answered:"
      grep -v '^[[:space:]]*$' "$log" | tail -n 5 | sed 's/^/  /'
      return 1
    fi
    if info=$(curl -fsS -m 2 "$api/cryptarchia/info" 2>/dev/null); then
      break
    fi
    sleep 1
  done
  if [ -z "$info" ]; then
    stop_node
    echo "$3 node API did not answer within ${START_TIMEOUT}s:"
    grep -v '^[[:space:]]*$' "$log" | tail -n 5 | sed 's/^/  /'
    return 1
  fi
  # The answer has to come from this node, and it has to stay up.
  sleep 2
  kill -0 "$node_pid" 2>/dev/null || die "$3 node exited right after its API answered"
  echo "$info" >"$work_dir/$3.json"
  echo "$3 node: $(jq -c '.cryptarchia_info | {height, lib, state}' "$work_dir/$3.json")"
  stop_node
}

# chain_info <label> <field>: a field of the chain info saved by run_node.
chain_info() {
  jq -r ".cryptarchia_info.$2" "$work_dir/$1.json"
}

# hex_values <binary> <config>: "<field> <value>" for every 64-hex-digit value
# in the effective config, the shape of the public keys and key ids. <field> is
# the YAML key on that line, or "-" for a list item. Fails when the build cannot
# load the config.
hex_values() {
  local shown
  shown=$(cd "$(dirname "$2")" && "$1" "$2" --show-config 2>&1) || {
    echo "$shown" | grep -v '^[[:space:]]*$' | tail -n 5 | sed 's/^/  /'
    return 1
  }
  echo "$shown" | awk '{
    field = "-"
    if (match($0, /^[[:space:]]*(- )?[A-Za-z0-9_]+:/)) {
      field = substr($0, RSTART, RLENGTH - 1)
      sub(/^[[:space:]]*(- )?/, "", field)
    }
    line = $0
    while (match(line, /[0-9a-fA-F]{64}/)) {
      value = tolower(substr(line, RSTART, RLENGTH))
      print (field == value ? "(map key)" : field), value
      line = substr(line, RSTART + RLENGTH)
    }
  }' | sort -u
}

command -v jq >/dev/null || die "jq is required"
command -v curl >/dev/null || die "curl is required"
rm -rf "$upgraded" "$fresh"
mkdir -p "$upgraded" "$fresh"

echo "old: $(version "$old_bin")"
echo "new: $(version "$new_bin")"

init_config "$old_bin" "$upgraded"
run_node "$old_bin" "$upgraded" old || die "the old release does not start on its own config"
[ "$(chain_info old height)" = 0 ] || die "the old node left its genesis block; this check needs it to stay there"
keystore_before=$(sha "$upgraded/keystore.yaml")

new_started=1
run_node "$new_bin" "$upgraded" upgraded || new_started=0

if [ "$(sha "$upgraded/keystore.yaml")" != "$keystore_before" ]; then
  fail "the keystore changed during the upgrade"
fi

# A fresh config from the new build and the same keystore: its keys are the
# ones the keystore's secrets derive today, and its node shows the new genesis.
cp "$upgraded/keystore.yaml" "$fresh/keystore.yaml"
init_config "$new_bin" "$fresh"
run_node "$new_bin" "$fresh" fresh || die "the new build does not start on a fresh config"

old_genesis=$(chain_info old lib)
if [ "$(chain_info fresh lib)" != "$old_genesis" ]; then
  note "new genesis ($old_genesis -> $(chain_info fresh lib)), the old state has to be removed"
elif [ "$new_started" -eq 0 ]; then
  fail "the new node cannot start on the state of the old release, on the same genesis"
elif [ "$(chain_info upgraded lib)" != "$old_genesis" ]; then
  fail "the upgraded node left the old genesis $old_genesis for $(chain_info upgraded lib)"
fi

hex_values "$new_bin" "$fresh/user_config.yaml" >"$work_dir/keys.fresh" ||
  die "the new build cannot show its own fresh config"
grep -q '^funding_pk ' "$work_dir/keys.fresh" ||
  die "no funding_pk in the fresh effective config; update hex_values for the new format"

if ! hex_values "$new_bin" "$upgraded/user_config.yaml" >"$work_dir/keys.upgraded"; then
  fail "the new build cannot load the upgraded config"
  cat "$work_dir/keys.upgraded"
else
  echo "keys: $(wc -l <"$work_dir/keys.upgraded") in the upgraded config, $(wc -l <"$work_dir/keys.fresh") derived fresh"
  stale=$(comm -23 "$work_dir/keys.upgraded" "$work_dir/keys.fresh")
  if [ -n "$stale" ]; then
    fail "the upgraded config uses keys this build does not derive from the keystore:"
    echo "  ${stale//$'\n'/$'\n'  }"
  fi
fi

if [ "$failed" -ne 0 ]; then
  echo "upgrade check failed; logs and configs are in $work_dir"
  exit "$FAILURE_DETECTED_EXIT_CODE"
fi
echo "upgrade check passed"
