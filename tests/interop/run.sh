#!/usr/bin/env bash
# tests/interop/run.sh -- the interoperability suite.
#
# A node built on ros2-nv talks to a micro-ROS agent, and a ROS 2 node talks to
# the same agent through DDS. This script runs the node and the ROS 2 node
# against each other, through a Micro XRCE-DDS Agent, under ROS 2 Jazzy, over
# TCP and over UDP:
#
#   talker    examples/host_talker.nv publishes /novo_counter; an rclpy
#             subscription hears the integers 0 to 9, in order.
#   listener  an rclpy publisher sends integers on /novo_cmd; examples/
#             host_listener.nv takes them from the agent, in order, none
#             missing between the first and the last it took.
#   text      an rclpy publisher sends a String of 1,000 characters on
#             /novo_text; examples/host_listener.nv takes it, whole, as the
#             pieces of a long sample, and reports its length, head and tail.
#   server    examples/host_server.nv serves /add_two_ints; `ros2 service call`
#             calls it three times and each reply carries the right sum.
#   client    an rclpy server serves /add_two_ints; examples/host_client.nv calls
#             it twice and prints the right sum each time.
#   bigendian an rclpy publisher sends the integer 42 as a big-endian CDR message
#             (from the raw bytes, as a publisher on a big-endian processor sends
#             it); examples/host_listener.nv takes four bytes that read as
#             704643072 little-endian: the agent strips the encapsulation header,
#             and the node has no way to tell the byte order (docs/agent-run.md,
#             "A big-endian publisher").
#   longtalk  examples/host_long_talker.nv publishes Strings of 1,000, 2,000,
#             2,040, 4,000 and 20,000 characters on /novo_text; an rclpy
#             subscription hears each whole, in order.
#   longreply `ros2 service call /long_reply` is answered by
#             examples/host_long_server.nv with a text of 4,000 characters.
#   longcall  an rclpy server serves /long_request; examples/host_long_client.nv
#             calls it with a name of 4,000 characters and the server counts all
#             of them.
#
# Every leg starts a fresh agent on a free port. A leg that fails is repeated,
# with a fresh agent, up to ATTEMPTS times (3): the agent does not tell a node
# whether a reader has matched its writer, so the first sample of a talker, or
# the first request of a client, can reach a graph that has not discovered the
# other side yet (docs/agent-run.md, "The first samples and a reader that is
# not there yet"). The line of a leg that needed a second attempt says so.
#
# Usage, from anywhere:
#
#   bash tests/interop/run.sh
#
# Environment:
#
#   NOVO           the compiler; default: novo on PATH
#   AGENT          the agent, MicroXRCEAgent or micro-ros-agent; default: the first
#                  of those on PATH. Its libraries are taken from ../lib next to
#                  its bin directory when that exists.
#   ROS_SETUP      the ROS 2 setup file; default /opt/ros/jazzy/setup.bash
#   ROS_OVERLAY    an install prefix with more ROS 2 packages, such as
#                  <dir>/opt/ros/jazzy of unpacked .deb files, for
#                  example_interfaces when the system has none
#   TRANSPORTS     the transports to run, default "tcp udp"
#   LEGS           the legs to run, default "talker listener text server client
#                  bigendian longtalk longreply longcall"
#   ATTEMPTS       attempts per leg, default 3
#   KEEP           1 keeps the logs of a passing run too
#
# Exit status: 0 when every leg passed, 1 when one failed, 2 when a tool the
# suite needs is missing.
#
# The examples join the DDS domain 0, so the suite owns the topics
# /novo_counter, /novo_cmd, /novo_text and /add_two_ints on that domain while
# it runs; a second run on the same machine waits for the first.

set -o pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PKG="$(cd "$HERE/../.." && pwd)"

NOVO="${NOVO:-$(command -v novo)}"
ROS_SETUP="${ROS_SETUP:-/opt/ros/jazzy/setup.bash}"
TRANSPORTS="${TRANSPORTS:-tcp udp}"
LEGS="${LEGS:-talker listener text server client bigendian longtalk longreply longcall}"
ATTEMPTS="${ATTEMPTS:-3}"

die() { echo "ERROR: $*" >&2; exit 2; }

# One suite at a time on a machine: the examples fix the domain and the topics.
if command -v flock >/dev/null 2>&1; then
    exec 9>"${TMPDIR:-/tmp}/ros2-nv-interop.lock"
    flock -w 900 9 || die "another interop run held the lock for 15 minutes"
fi

[ -n "$NOVO" ] && [ -x "$NOVO" ] || die "no novo compiler; set NOVO"
[ -r "$ROS_SETUP" ] || die "no ROS 2 setup file at $ROS_SETUP; set ROS_SETUP"

if [ -z "${AGENT:-}" ]; then
    AGENT="$(command -v MicroXRCEAgent || command -v micro-ros-agent)"
fi
[ -n "$AGENT" ] && [ -x "$AGENT" ] || die "no Micro XRCE-DDS Agent; set AGENT (tests/interop/build_agent.sh builds one)"
AGENT_LIB="$(cd "$(dirname "$AGENT")/../lib" 2>/dev/null && pwd)"

# ROS 2 and, when named, the overlay. setup.bash reads variables it has not set,
# so this runs before anything that would stop on one.
# shellcheck disable=SC1090
source "$ROS_SETUP"
if [ -n "${ROS_OVERLAY:-}" ]; then
    export AMENT_PREFIX_PATH="$ROS_OVERLAY:${AMENT_PREFIX_PATH:-}"
    export LD_LIBRARY_PATH="$ROS_OVERLAY/lib:${LD_LIBRARY_PATH:-}"
    for site in "$ROS_OVERLAY"/lib/python3*/site-packages; do
        export PYTHONPATH="$site:${PYTHONPATH:-}"
    done
fi
export ROS_DOMAIN_ID=0
command -v ros2 >/dev/null || die "ros2 is not on PATH after sourcing $ROS_SETUP"
ros2 interface show example_interfaces/srv/AddTwoInts >/dev/null 2>&1 \
    || die "example_interfaces is missing; install ros-jazzy-example-interfaces or set ROS_OVERLAY"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ros2-nv-interop.XXXXXX")"
BIN="$WORK/bin"
mkdir -p "$BIN"
PIDS=()
PASS=0
FAIL=0

cleanup() {
    local pid
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    if [ "$FAIL" -eq 0 ] && [ "${KEEP:-0}" != 1 ]; then
        rm -rf "$WORK"
    else
        echo "logs: $WORK"
    fi
}
trap cleanup EXIT

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; FAIL=$((FAIL + 1)); }

# wait_for SECONDS COMMAND...: poll the command every tenth of a second.
wait_for() {
    local limit=$1
    shift
    local deadline=$((SECONDS + limit))
    while ! "$@" 2>/dev/null; do
        [ "$SECONDS" -ge "$deadline" ] && return 1
        sleep 0.1
    done
}

free_port() {
    python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

# background LOGFILE COMMAND...: start a command that cannot outlive its limit.
background() {
    local log=$1
    shift
    "$@" >"$log" 2>&1 &
    LAST_PID=$!
    PIDS+=("$LAST_PID")
}

# The agent of one attempt: AGENT_PID, AGENT_PORT and a log in $1.
start_agent() {
    local dir=$1 transport=$2
    AGENT_PORT="$(free_port)"
    background "$dir/agent.log" timeout 600 env LD_LIBRARY_PATH="${AGENT_LIB:+$AGENT_LIB:}${LD_LIBRARY_PATH:-}" \
        "$AGENT" "${transport}4" --port "$AGENT_PORT" -v 6
    AGENT_PID=$LAST_PID
    wait_for 30 command grep -q 'running\.\.\.' "$dir/agent.log" || {
        REASON="the agent did not start on port $AGENT_PORT"
        return 1
    }
}

# stop PID...: end background commands; the status of the killed is not the caller's.
stop() {
    kill "$@" 2>/dev/null
    wait "$@" 2>/dev/null
    return 0
}

file_exists() { [ -e "$1" ]; }

not_running() { ! kill -0 "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# The programs, built once.

build_programs() {
    local name
    local started=$SECONDS
    echo "building the examples with $("$NOVO" --version)"
    for name in host_talker host_listener host_server host_client host_long_talker \
        host_long_server host_long_client; do
        (cd "$PKG" && "$NOVO" build "examples/$name.nv" -o "$BIN/$name") >"$WORK/build-$name.log" 2>&1 || {
            echo "ERROR: examples/$name.nv did not build:" >&2
            sed 's/^/    /' "$WORK/build-$name.log" >&2
            FAIL=$((FAIL + 1))
            return 1
        }
    done
    echo "built in $((SECONDS - started)) s"
}

# ---------------------------------------------------------------------------
# The legs. Each takes the directory of its attempt and the transport, and
# answers 0 when the leg passed or 1 with REASON set.

leg_talker() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/listen.log" timeout 120 python3 -I "$HERE/listen.py" \
        --topic /novo_counter --type int32 --out "$dir/heard" --ready "$dir/ready" --count 10 --timeout 100
    local listener=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy listener did not start"; return 1; }
    timeout 120 "$BIN/host_talker" 127.0.0.1 "$AGENT_PORT" reliable "$tr" >"$dir/node.log" 2>&1
    local node=$?
    # The listener ends by itself after the tenth integer; one that is still
    # waiting ten seconds after the talker has finished is not going to hear more.
    wait_for 10 not_running "$listener"
    stop "$listener"
    [ "$node" -eq 0 ] || { REASON="host_talker exited $node"; return 1; }
    if [ "$(tr '\n' ' ' <"$dir/heard")" != "0 1 2 3 4 5 6 7 8 9 " ]; then
        REASON="the listener heard: $(tr '\n' ' ' <"$dir/heard")(wanted 0 to 9)"
        return 1
    fi
}

# The numbers `sample N: data V, 4 bytes` lines of a listener log carry.
heard_numbers() {
    sed -n 's/^sample [0-9]*: data \(-\{0,1\}[0-9][0-9]*\), 4 bytes$/\1/p' "$1"
}

leg_listener() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/talk.log" timeout 120 python3 -I "$HERE/talk.py" \
        --topic /novo_cmd --type int32 --start 100 --period 0.2 --out "$dir/sent" --ready "$dir/ready" --timeout 100
    local talker=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy talker did not start"; return 1; }
    timeout 120 "$BIN/host_listener" 127.0.0.1 "$AGENT_PORT" reliable 10 int32 "$tr" >"$dir/node.log" 2>&1
    local node=$?
    stop "$talker"
    [ "$node" -eq 0 ] || { REASON="host_listener exited $node"; return 1; }
    heard_numbers "$dir/node.log" >"$dir/heard"
    local n first last top
    n=$(wc -l <"$dir/heard")
    first=$(head -1 "$dir/heard")
    last=$(tail -1 "$dir/heard")
    top=$(sort -n "$dir/sent" | tail -1)
    if [ "$n" -lt 5 ]; then
        REASON="host_listener took $n samples (wanted 5 or more)"
        return 1
    fi
    if ! awk 'NR > 1 && $1 != prev + 1 { bad = 1 } { prev = $1 } END { exit bad }' "$dir/heard"; then
        REASON="the integers host_listener took are not consecutive: $(tr '\n' ' ' <"$dir/heard")"
        return 1
    fi
    if [ "$first" -lt 100 ] || [ "$last" -gt "$top" ]; then
        REASON="host_listener took $first to $last; the publisher sent 100 to $top"
        return 1
    fi
    command grep -q "^received $n sample(s)$" "$dir/node.log" \
        || { REASON="host_listener did not end with 'received $n sample(s)'"; return 1; }
}

leg_text() {
    local dir=$1 tr=$2
    local body text head tail
    body=$(printf '0123456789abcdef%.0s' $(seq 1 62))
    text="HEAD-${body:0:990}-TAIL"
    head=${text:0:24}
    tail=${text: -24}
    start_agent "$dir" "$tr" || return 1
    background "$dir/talk.log" timeout 120 python3 -I "$HERE/talk.py" \
        --topic /novo_text --type string --text "$text" --period 0.5 --out "$dir/sent" --ready "$dir/ready" --timeout 100
    local talker=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy talker did not start"; return 1; }
    timeout 120 "$BIN/host_listener" 127.0.0.1 "$AGENT_PORT" reliable 10 string "$tr" >"$dir/node.log" 2>&1
    local node=$?
    stop "$talker"
    [ "$node" -eq 0 ] || { REASON="host_listener exited $node"; return 1; }
    local want="text of ${#text} characters, 1008 bytes, begins \"$head\", ends \"$tail\""
    sed -n 's/^sample [0-9]*: \(text of .*\)$/\1/p' "$dir/node.log" >"$dir/heard"
    local n bad
    n=$(wc -l <"$dir/heard")
    bad=$(command grep -cvxF "$want" "$dir/heard")
    if [ "$n" -lt 3 ]; then
        REASON="host_listener took $n samples (wanted 3 or more)"
        return 1
    fi
    if [ "$bad" -ne 0 ]; then
        REASON="a sample differs from: $want; first line: $(head -1 "$dir/heard")"
        return 1
    fi
}

# The three calls of the server leg and the sum each is answered with.
CALLS=("2 3 5" "40 2 42" "-7 1000000000000 999999999993")

leg_server() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/node.log" timeout 180 "$BIN/host_server" 127.0.0.1 "$AGENT_PORT" 150 "$tr"
    local server=$LAST_PID
    local call a b sum out tries
    for call in "${CALLS[@]}"; do
        read -r a b sum <<<"$call"
        tries=0
        while :; do
            out=$(timeout 40 ros2 service call /add_two_ints example_interfaces/srv/AddTwoInts "{a: $a, b: $b}" 2>&1)
            echo "$out" >"$dir/call-$a-$b.log"
            if echo "$out" | command grep -qx "example_interfaces.srv.AddTwoInts_Response(sum=$sum)"; then
                break
            fi
            tries=$((tries + 1))
            if [ "$tries" -ge 3 ]; then
                REASON="ros2 service call a=$a b=$b answered: $(echo "$out" | tail -1) (wanted sum=$sum)"
                stop "$server"
                return 1
            fi
        done
    done
    stop "$server"
}

leg_client() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/serve.log" timeout 240 python3 -I "$HERE/serve.py" \
        --service /add_two_ints --out "$dir/requests" --ready "$dir/ready" --timeout 220
    local server=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy server did not start"; return 1; }
    local call a b sum
    for call in "40 2 42" "-7 1000000000000 999999999993"; do
        read -r a b sum <<<"$call"
        timeout 90 "$BIN/host_client" 127.0.0.1 "$AGENT_PORT" "$a" "$b" "$tr" >"$dir/node-$a.log" 2>&1
        if ! command grep -Eq "^reply to request [0-9]+: sum = $sum$" "$dir/node-$a.log"; then
            REASON="host_client a=$a b=$b printed: $(tail -1 "$dir/node-$a.log") (wanted sum = $sum)"
            stop "$server"
            return 1
        fi
        command grep -qxF -- "$a $b" "$dir/requests" \
            || { REASON="the rclpy server never saw a=$a b=$b"; stop "$server"; return 1; }
    done
    stop "$server"
}

# A big-endian publisher: the node takes the bytes, with no sign of their order.
leg_bigendian() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/talk.log" timeout 120 python3 -I "$HERE/talk.py" \
        --topic /novo_cmd --type int32 --start 42 --period 0.2 --big-endian --out "$dir/sent" --ready "$dir/ready" --timeout 100
    local talker=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy talker did not start"; return 1; }
    timeout 120 "$BIN/host_listener" 127.0.0.1 "$AGENT_PORT" reliable 4 int32 "$tr" >"$dir/node.log" 2>&1
    local node=$?
    stop "$talker"
    [ "$node" -eq 0 ] || { REASON="host_listener exited $node"; return 1; }
    heard_numbers "$dir/node.log" >"$dir/heard"
    # 42, 43, ...: the bytes 00 00 00 2A read least significant first are 42 * 2^24,
    # and each number after it is the next multiple, so every number the node took
    # is a multiple of 2^24 and none is below 42 * 2^24.
    if [ "$(wc -l <"$dir/heard")" -lt 3 ] \
        || ! awk '$1 % 16777216 != 0 || $1 < 42 * 16777216 { bad = 1 } END { exit bad }' "$dir/heard"; then
        REASON="host_listener took: $(tr '\n' ' ' <"$dir/heard")(wanted multiples of 16777216 from $((42 * 16777216)): the big-endian bytes read little-endian, so the agent strips the header)"
        return 1
    fi
}

# The leg of the long talker: the five texts it publishes, each heard whole.
leg_longtalk() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/listen.log" timeout 150 python3 -I "$HERE/listen.py" \
        --topic /novo_text --type string --out "$dir/heard" --ready "$dir/ready" --count 5 --timeout 120
    local listener=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy listener did not start"; return 1; }
    timeout 150 "$BIN/host_long_talker" 127.0.0.1 "$AGENT_PORT" "$tr" >"$dir/node.log" 2>&1
    local node=$?
    wait_for 10 not_running "$listener"
    stop "$listener"
    [ "$node" -eq 0 ] || { REASON="host_long_talker exited $node"; return 1; }
    if ! python3 -I - "$dir/heard" <<'PY'
import sys
lines = open(sys.argv[1]).read().split("\n")[:-1]
want = [1000, 2000, 2040, 4000, 20000]
got = [len(x) for x in lines]
ok = got == want and all(x == "".join(chr(97 + i % 26) for i in range(len(x))) for x in lines)
print("the listener heard texts of", got, "(wanted %s, a to z round again)" % want, file=sys.stderr)
sys.exit(0 if ok else 1)
PY
    then
        REASON="the listener did not hear the five texts whole and in order: $(awk '{ print length($0) }' "$dir/heard" | tr '\n' ' ')"
        return 1
    fi
}

# A Trigger reply of 4,000 characters, called with `ros2 service call`.
leg_longreply() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/node.log" timeout 180 "$BIN/host_long_server" 127.0.0.1 "$AGENT_PORT" 150 "$tr" 4000
    local server=$LAST_PID
    local out tries=0
    while :; do
        out=$(timeout 40 ros2 service call /long_reply std_srvs/srv/Trigger 2>&1)
        echo "$out" >"$dir/call.log"
        if python3 -I - "$dir/call.log" <<'PY'
import re, sys
m = re.search(r"message='([a-z]*)'", open(sys.argv[1]).read())
text = m.group(1) if m else ""
sys.exit(0 if len(text) == 4000 and text == "".join(chr(97 + i % 26) for i in range(4000)) else 1)
PY
        then
            break
        fi
        tries=$((tries + 1))
        if [ "$tries" -ge 3 ]; then
            REASON="ros2 service call /long_reply did not answer a text of 4,000 characters: $(echo "$out" | tail -1 | cut -c1-120)"
            stop "$server"
            return 1
        fi
    done
    stop "$server"
}

# A GetParameters request of one name of 4,000 characters, called by the node.
leg_longcall() {
    local dir=$1 tr=$2
    start_agent "$dir" "$tr" || return 1
    background "$dir/serve.log" timeout 240 python3 -I "$HERE/serve_long.py" \
        --service /long_request --out "$dir/names" --ready "$dir/ready" --timeout 220
    local server=$LAST_PID
    wait_for 60 file_exists "$dir/ready" || { REASON="the rclpy server did not start"; return 1; }
    timeout 90 "$BIN/host_long_client" 127.0.0.1 "$AGENT_PORT" 4000 "$tr" >"$dir/node.log" 2>&1
    stop "$server"
    command grep -Eq "^reply to request [0-9]+: the server counted 4000 characters$" "$dir/node.log" \
        || { REASON="host_long_client printed: $(tail -1 "$dir/node.log") (wanted 'the server counted 4000 characters')"; return 1; }
    command grep -q "^4000 abcdefghijklmnopqrstuvwx yzabcdefghijklmnopqrstuv$" "$dir/names" \
        || { REASON="the rclpy server did not see the name whole: $(head -1 "$dir/names")"; return 1; }
}

# ---------------------------------------------------------------------------

LEG_TITLE_talker="novo talker -> rclpy listener"
LEG_TITLE_listener="rclpy talker -> novo listener"
LEG_TITLE_text="rclpy String of 1,000 characters -> novo listener"
LEG_TITLE_server="ros2 service call -> novo server"
LEG_TITLE_client="novo client -> rclpy server"
LEG_TITLE_bigendian="rclpy big-endian publisher -> novo listener, the bytes without their order"
LEG_TITLE_longtalk="novo talker, Strings of 1,000 to 20,000 characters -> rclpy listener"
LEG_TITLE_longreply="ros2 service call -> novo server, a reply of 4,000 characters"
LEG_TITLE_longcall="novo client, a request of 4,000 characters -> rclpy server"

run_leg() {
    local leg=$1 tr=$2
    local title_var="LEG_TITLE_$leg"
    local started=$SECONDS attempt dir
    for attempt in $(seq 1 "$ATTEMPTS"); do
        dir="$WORK/$leg-$tr-$attempt"
        mkdir -p "$dir"
        REASON=""
        if "leg_$leg" "$dir" "$tr"; then
            local note=""
            [ "$attempt" -gt 1 ] && note=", attempt $attempt"
            pass "${!title_var} ($tr, $((SECONDS - started)) s$note)"
            [ -n "${AGENT_PID:-}" ] && stop "$AGENT_PID"
            return 0
        fi
        [ -n "${AGENT_PID:-}" ] && stop "$AGENT_PID"
        echo "    attempt $attempt of $ATTEMPTS: $REASON" >&2
    done
    fail "${!title_var} ($tr)" "$REASON"
    local f
    for f in "$dir/agent.log" "$dir/node.log"; do
        [ -e "$f" ] && { echo "    --- $(basename "$f"), last lines:"; tail -n 12 "$f" | sed 's/^/    /'; }
    done
}

echo "interop: agent $AGENT, ROS setup $ROS_SETUP, transports: $TRANSPORTS"
build_programs || exit 1
suite_started=$SECONDS
for tr in $TRANSPORTS; do
    echo "$tr"
    for leg in $LEGS; do
        run_leg "$leg" "$tr"
    done
done

echo "$PASS passed, $FAIL failed ($((SECONDS - suite_started)) s)"
[ "$FAIL" -eq 0 ]
