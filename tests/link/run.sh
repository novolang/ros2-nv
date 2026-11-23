#!/usr/bin/env bash
# tests/link/run.sh -- the host proof of the radio link transport.
#
# A node built on `roslink` (examples/link_stdio_node.nv) speaks the serial framing of
# Micro XRCE-DDS through a radio that moves 20 octets a call; the radio is a
# pseudoterminal. A bridge (examples/link_bridge.nv) stands on the other end of the
# pseudoterminal pair and speaks UDP to a Micro XRCE-DDS Agent. ROS 2 Jazzy's own
# command line tools then see the node:
#
#   publication   `ros2 topic echo /novo_counter` prints consecutive integers the
#                 node published.
#   subscription  `ros2 topic pub /novo_cmd` sends 7 and the node reports "command 7".
#   reopen        the node ends and a second run opens a session with the same client
#                 key against the same bridge and agent; the second run's counter is
#                 echoed again.
#
# Usage, from anywhere:
#
#   bash tests/link/run.sh
#
# Environment: NOVO (default: novo on PATH), AGENT (default: MicroXRCEAgent on PATH or
# ~/tools/xrce-agent/install/bin/MicroXRCEAgent), ROS_SETUP (default
# /opt/ros/jazzy/setup.bash), KEEP=1 keeps the logs of a passing run.
#
# Exit status: 0 when every leg passed, 1 when one failed, 2 when a tool is missing.

set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"
NOVO="${NOVO:-$(command -v novo)}"
ROS_SETUP="${ROS_SETUP:-/opt/ros/jazzy/setup.bash}"

die() { echo "ERROR: $*" >&2; exit 2; }

[ -n "$NOVO" ] && [ -x "$NOVO" ] || die "no novo compiler; set NOVO"
[ -r "$ROS_SETUP" ] || die "no ROS 2 setup file at $ROS_SETUP; set ROS_SETUP"
command -v socat >/dev/null || die "socat is needed for the pseudoterminal pair"
if [ -z "${AGENT:-}" ]; then
    AGENT="$(command -v MicroXRCEAgent || true)"
    [ -n "$AGENT" ] || AGENT="$HOME/tools/xrce-agent/install/bin/MicroXRCEAgent"
fi
[ -x "$AGENT" ] || die "no Micro XRCE-DDS Agent; set AGENT"
AGENT_LIB="$(cd "$(dirname "$AGENT")/../lib" 2>/dev/null && pwd)"

# shellcheck disable=SC1090
source "$ROS_SETUP"
export ROS_DOMAIN_ID=0
command -v ros2 >/dev/null || die "ros2 is not on PATH after sourcing $ROS_SETUP"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ros2-nv-link.XXXXXX")"
BIN="$WORK/bin"
mkdir -p "$BIN"
PIDS=()
PASS=0
FAIL=0

cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null; done
    wait 2>/dev/null
    if [ "$FAIL" -eq 0 ] && [ "${KEEP:-0}" != 1 ]; then rm -rf "$WORK"; else echo "logs: $WORK"; fi
}
trap cleanup EXIT

pass() { echo "  ok   $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL $1"; [ -n "${2:-}" ] && echo "       $2"; FAIL=$((FAIL + 1)); }

wait_for() {
    local limit=$1; shift
    local deadline=$((SECONDS + limit))
    while ! "$@" 2>/dev/null; do
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 0.1
    done
}

background() {
    local log=$1; shift
    "$@" >"$log" 2>&1 &
    LAST_PID=$!
    PIDS+=("$LAST_PID")
}

echo "building the examples with $("$NOVO" --version)"
for name in link_stdio_node link_bridge; do
    (cd "$PKG" && "$NOVO" build "examples/$name.nv" -o "$BIN/$name") >"$WORK/build-$name.log" 2>&1 || {
        echo "ERROR: examples/$name.nv did not build:" >&2
        sed 's/^/    /' "$WORK/build-$name.log" >&2
        exit 1
    }
done

# The air: a pseudoterminal pair, one end for the node and one for the bridge.
background "$WORK/socat.log" socat pty,raw,echo=0,link="$WORK/ttyNODE" pty,raw,echo=0,link="$WORK/ttyBRIDGE"
wait_for 10 test -e "$WORK/ttyBRIDGE" || { echo "ERROR: socat made no pseudoterminals" >&2; exit 2; }

PORT="$(python3 -I -c 'import socket; s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
background "$WORK/agent.log" timeout 300 env LD_LIBRARY_PATH="${AGENT_LIB:+$AGENT_LIB:}${LD_LIBRARY_PATH:-}" \
    "$AGENT" udp4 --port "$PORT" -v 6
AGENT_PID=$LAST_PID
wait_for 30 command grep -q 'running\.\.\.' "$WORK/agent.log" || { echo "ERROR: the agent did not start" >&2; exit 2; }

# Standard input and output are the link, so the redirections are the bridge's own.
timeout 200 "$BIN/link_bridge" 127.0.0.1 "$PORT" 60 <>"$WORK/ttyBRIDGE" >&0 2>"$WORK/bridge.log" &
BRIDGE_PID=$!
PIDS+=("$BRIDGE_PID")

# `ros2 topic echo` and `ros2 topic pub` are the ROS 2 side.
background "$WORK/echo.log" timeout 100 ros2 topic echo /novo_counter std_msgs/msg/Int32
ECHO_PID=$LAST_PID
background "$WORK/pub.log" timeout 100 ros2 topic pub -r 5 /novo_cmd std_msgs/msg/Int32 "{data: 7}"
PUB_PID=$LAST_PID
sleep 3

run_node() {
    local log=$1
    timeout 60 "$BIN/link_stdio_node" 14 <>"$WORK/ttyNODE" >&0 2>"$log"
}

echo "the first run"
run_node "$WORK/node1.log"
echo "  node: $(tail -1 "$WORK/node1.log")"
sleep 1
sed -n 's/^data: \(-\{0,1\}[0-9][0-9]*\)$/\1/p' "$WORK/echo.log" >"$WORK/heard1"
N1=$(wc -l <"$WORK/heard1")
if [ "$N1" -ge 5 ] && awk 'NR > 1 && $1 != prev + 1 { bad = 1 } { prev = $1 } END { exit bad }' "$WORK/heard1"; then
    pass "ros2 topic echo /novo_counter heard $N1 consecutive integers ($(head -1 "$WORK/heard1") to $(tail -1 "$WORK/heard1"))"
else
    fail "ros2 topic echo /novo_counter heard: $(tr '\n' ' ' <"$WORK/heard1")" "wanted 5 or more consecutive integers"
fi
if command grep -q '^command 7$' "$WORK/node1.log"; then
    pass "ros2 topic pub /novo_cmd reached the node ($(command grep -c '^command 7$' "$WORK/node1.log") commands)"
else
    fail "the node reported no command 7" "$(tail -3 "$WORK/node1.log" | tr '\n' ' ')"
fi
if command grep -q ' 0 refused, 0 dropped' "$WORK/node1.log"; then
    pass "the link refused and dropped no octet"
else
    fail "the link refused or dropped octets" "$(tail -1 "$WORK/node1.log")"
fi

echo "the second run: the same client key, the same bridge and agent"
# The first run ended with its session open, so the agent keeps sending the
# HEARTBEATs of that session and the bridge keeps writing them to the pseudoterminal,
# where they queue for a node that is not there. A radio with no device in range
# queues nothing; the pseudoterminal is emptied by hand to be the same.
timeout 2 cat "$WORK/ttyNODE" >/dev/null
: >"$WORK/echo.log"
run_node "$WORK/node2.log"
echo "  node: $(tail -1 "$WORK/node2.log")"
sleep 1
sed -n 's/^data: \(-\{0,1\}[0-9][0-9]*\)$/\1/p' "$WORK/echo.log" >"$WORK/heard2"
N2=$(wc -l <"$WORK/heard2")
if command grep -q '^session open$' "$WORK/node2.log" && [ "$N2" -ge 3 ]; then
    pass "the second session opened and /novo_counter was echoed again ($N2 integers)"
else
    fail "the second run: $(head -2 "$WORK/node2.log" | tr '\n' ' ')" "echo heard $N2 integers"
fi

kill "$ECHO_PID" "$PUB_PID" 2>/dev/null
# The bridge reports its counters when its time is up.
wait "$BRIDGE_PID" 2>/dev/null
echo "  bridge: $(tail -1 "$WORK/bridge.log")"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
