# ros2-nv

[ROS 2](https://docs.ros.org/) is a set of libraries for building robot
software: programs called *nodes* publish and subscribe on named
*topics*, and call each other through named *services*. On a
microcontroller the client library is
[rclc](https://github.com/ros2/rclc), and a node built on it reaches the
rest of the system through [micro-ROS](https://micro.ros.org/). This
package brings rclc's node model to novo-lang.

## What it is

A node on a workstation talks directly to every other node, over a
middleware called DDS. A node on a microcontroller does not: it talks to
an *agent*, which is a program on another machine, and the agent is the
DDS participant on its behalf. The protocol between them is Micro
XRCE-DDS, and everything a microcontroller node does follows from it.
The node's topics do not exist until the agent has created them. An
agent that restarts loses every topic and publisher the node made, and
the node is not told. A node whose agent is not running publishes into
nothing.

This package is the decisions a node makes on its own side of that
link. Which return codes mean something is wrong. Whether a name will be
accepted. Whether a publisher and a subscription will connect. How many
publishers the firmware was built to hold. Which of the node's callbacks
to run next. All of it is arithmetic over integers, and all of it runs
on a part with sixty-four kilobytes of memory and no heap allocator.

**Three of ROS 2's failures are silent, and this package exists mostly
for them.** A publisher and a subscription whose quality-of-service
settings do not match are both created successfully, both report
healthy, and never connect; nothing is logged anywhere. Two endpoints on
one topic carrying different message types do the same. A message larger
than the transport's buffer is dropped below the layer that could report
it, so the publish call succeeds and nothing arrives. On a workstation
each of these costs an afternoon with `ros2 topic info --verbose`. On a
microcontroller there is no `ros2` and there is often no console.

So `rosqos.compatible`, `rosgraph.can_connect` and
`rostransport.message_fits` are pure functions a node calls at startup,
before it creates anything, with the answer printed once.

**Quality of service is a negotiation with a direction.** A publisher
*offers* settings and a subscription *requests* them, and a match needs
the offer to be at least as strong as the request. A reliable publisher
satisfies a subscription that asked for best effort; a best-effort
publisher does not satisfy one that asked for reliable. That single rule
is the most common reason a ROS 2 program receives nothing, because
every camera and laser scanner publishes best effort and every
subscription written without thinking about it requests reliable.

**Nothing here serialises a message.** A ROS 2 message on the wire is
Common Data Representation, which has its own alignment rules and its
own specification. This package carries a payload as bytes it does not
read, together with the four-byte header that says which byte order
those bytes are in.

**Nothing here reads a clock.** Every timeout, every heartbeat interval
and every timer period is a number of milliseconds the caller measures
and passes in. That makes a node's timing replayable from a log, and it
is what lets the same timer run against simulated time with no second
implementation.

## Install

```
novo pkg add ros2-nv
```

## Example

Every call in the example is a pure function, so the program runs
anywhere: the names, the pool and the endpoint pair are all decided
before anything is created.

```novo
use rosexec
use rosgraph
use rosname
use rosqos
use rosret

fn main() [io]
    // Check the names before anything is created with them.  A node
    // created with a name that breaks a rule does not start, and what
    // comes back is a code from three layers down.
    if rosname.check_node_name("temperature_sensor") != rosname.ROS_NAME_OK
        println("bad node name")
        return
    if rosname.check_topic_name("/sensors/temperature") != rosname.ROS_NAME_OK
        println("bad topic name")
        return

    // Check that the firmware was built to hold what this node wants.
    // A stock micro-ROS build allows one publisher and one
    // subscription, and the second of either fails at run time.
    let pool = rosgraph.default_pool()
    if not rosgraph.pool_admits(pool, 1, 1, 0, 0)
        println(rosgraph.entity_name(rosgraph.first_shortfall(pool, 1, 1, 0, 0)))
        return

    // Check that this publisher will reach that subscription.  A
    // mismatch here connects nothing and reports nothing.
    let t = rosname.type_id("sensor_msgs/msg/Temperature")
    let publisher = rosgraph.endpoint(rosgraph.ROS_ENTITY_PUBLISHER, 0, t,
                                      rosqos.sensor_data_profile())
    let subscription = rosgraph.endpoint(rosgraph.ROS_ENTITY_SUBSCRIPTION, 0, t,
                                         rosqos.default_profile())
    let verdict = rosgraph.can_connect(publisher, subscription)
    if verdict != rosret.ROS_RET_OK
        println(rosret.ros_ret_name(verdict))
        println(rosqos.compat_advice(rosgraph.connect_qos(publisher, subscription)))

    // One spin of the executor.  The middleware says which handles are
    // ready, as a bit each; this program dispatches them itself.
    var ex = rosexec.spin_begin(rosexec.add_handle(rosexec.executor(2)))
    let ready = 0x1
    var going = true
    while going
        let step = rosexec.spin_step(ex, ready)
        if step.dispatch
            // The caller's own dispatch goes here, with whatever
            // effects its callbacks need and no others.
            println("handle ${step.index} is ready")
            ex = rosexec.spin_advance(ex)
        else
            going = false
```

Build and test with `novo pkg build` and `novo test tests`.

## What the package contains

| Module | Contents |
| --- | --- |
| `rosret` | rcl's return codes, and the two questions to ask about one: whether the call did anything, and whether anything is wrong. They are not the same question. |
| `rosname` | The rules a node name, a namespace, a topic name and a service name have to obey; expanding a relative or private name; and the DDS names ROS 2 maps them to. |
| `rosqos` | The eight quality-of-service settings, the six named profiles ROS 2 ships, and whether a publisher's offer satisfies a subscription's request. |
| `rosgraph` | How many of each thing a firmware was built to hold, how many have been created, and whether two endpoints will connect. |
| `rosexec` | The executor as a step a caller drives, the two dispatch semantics, the three trigger policies, and periodic timers counted in the caller's own milliseconds. |
| `rosmsg` | A serialised message as bytes this package does not read, the four-byte header that says which byte order they are in, and whether the whole thing fits the transport. |
| `rostransport` | The session with the agent, the two stream kinds, `RosTransport`, the byte pipe a program implements over its own link, and the functions that open a session, create entities, write samples, ask for samples and take them over one, a sample longer than one message included (`poll_long`). |
| `xrcewire` | The Micro XRCE-DDS messages a client sends and the replies it reads, built in a buffer the caller owns: the requests that create entities, write and read samples, the HEARTBEAT and ACKNACK of a reliable stream, and the FRAGMENT a long sample is cut into. |
| `xrcestream` | One reliable stream as arithmetic over integers: sequence numbers that wrap, the history of messages kept for retransmission, what a received message asks of the session, and when a HEARTBEAT is due. It allocates nothing. |
| `xrcefrag` | A sample longer than one message, joined from the pieces the agent sends it in, in a buffer the caller owns, with a limit the caller sets. It allocates nothing. |
| `xrceframe` | The framing of a serial link to an agent: begin flag, addresses, length, byte stuffing and CRC-16, as a framer and a de-framer that allocate nothing. |
| `rosuart` | The session over a UART, for a device: the same requests as `rostransport`, including subscriptions, the reliable stream and long samples, with no heap, over `XrceUart`, the trait a board's UART implements. |
| `rosparam` | The three parameter types a microcontroller node can have, the seven it cannot, and the rule that a parameter keeps the type it was declared with. |
| `rosagent` | A byte pipe to a micro-ROS agent over TCP or UDP. The only module in the package that opens anything. |

## How to choose an entry point

**A program checking itself at startup calls the pure functions.**
`rosname.check_topic_name`, `rosgraph.pool_admits`,
`rosgraph.can_connect` and `rosmsg.fits_mtu` take values and return
values. That is the whole of what this package can do before a node
exists, and it is most of what it is for.

**A program with a link to an agent calls `rostransport`.** Its
functions take a `RosTransport` and cost whatever that implementation
costs. A program on a development machine gets one from
`rosagent.connect`, which reaches an agent over TCP, or from
`rosagent.connect_udp`, which reaches one over UDP. `examples/host_talker.nv`
is a program that publishes a counter through either, on the best-effort
stream or, given `reliable`, on the reliable one, and `udp` as the fourth
argument chooses the datagram link. `examples/host_listener.nv` subscribes:
it creates a data reader, asks for samples and prints each one `poll_long`
takes, a text of a thousand bytes included.

**A program on a device calls `rosuart`.** Its functions take an
`XrceUart`, which `rosuart.console_uart` supplies from the board's
`hal.uart`, and allocate nothing; `examples/dk_talker.nv` is the same
counter on an nRF54LM20 DK, and `examples/uart_stdio_listener.nv` is the
device's subscription run on a PC, with `string` as its third argument for a
sample longer than one message, which `rosuart.poll_long` joins. `docs/agent-run.md` has the steps to run
each against an agent.

**A program on a device calls the modules that build for it.** See
"Running on a microcontroller".

## The rules a user needs

1. **`RCL_RET_SUBSCRIPTION_TAKE_FAILED` is not an error.** A wait set
   reports that a subscription has data, the take that follows finds
   none, and the code comes back. It happens routinely. The same is true
   of the client and service take codes and of `RCL_RET_TIMEOUT`. Use
   `rosret.ros_ret_is_error`, not `ret != ROS_RET_OK`.
2. **A publisher offers and a subscription requests, and the relation
   is not symmetric.** `rosqos.compatible(offered, requested)` gives a
   different answer with its arguments swapped.
3. **Reliable satisfies a request for best effort; best effort does not
   satisfy a request for reliable.** Transient-local durability
   satisfies a request for volatile; volatile does not satisfy a request
   for transient-local. Manual-by-topic liveliness satisfies a request
   for automatic; automatic does not satisfy a request for manual.
4. **A publisher's deadline must be no longer than the subscription's.**
   So must its liveliness lease. An infinite duration is spelled zero,
   which a comparison on the numbers gets backwards.
5. **History, depth and lifespan cannot prevent a connection.** Two
   endpoints with depths of 1 and 100 connect and drop messages, which
   is a different problem with a different fix.
6. **A stock micro-ROS build allows one node, one publisher, one
   subscription, one service and one client, and keeps four messages.**
   Creating a second of anything fails at run time with a code that says
   an allocation failed. `rosgraph.default_pool` is those numbers.
7. **A depth larger than the build's history is quietly reduced.** A
   subscription asking to keep ten against a firmware built to hold four
   keeps four, so a burst of six arrives as four.
8. **An executor's handle count is fixed when it is created, and
   publishers are not handles.** Count subscriptions, timers, services,
   clients and guard conditions; `rosexec.handles_required` is the
   arithmetic.
9. **Handles are dispatched in the order they were added, and that
   order is the schedule.** A node whose control callback was registered
   before the subscription it consumes runs one cycle behind for the
   life of the program.
10. **Under `ROS_INVOKE_ALWAYS` a callback runs with no message.** The
    step says so in `has_message`; a callback that reads its buffer
    without checking reads either nothing or the previous message.
11. **A node name is one token with no slash in it.** A namespace begins
    with a slash. A topic name may not end with one, may not contain two
    in a row, and may have no token beginning with a digit.
12. **A topic whose name has a token beginning with an underscore is
    hidden** from `ros2 topic list`.
13. **The name on the wire is not the name in the program.** A topic
    `/chatter` is the DDS topic `rt/chatter`, a service's requests are
    `rq/…` and its replies `rr/…`, and the 255-character limit applies
    to those.
14. **A type name has three parts.** `std_msgs/msg/String`, not
    `std_msgs/String`; the two-part spelling is ROS 1's and is refused.
15. **A message larger than the transport's buffer is dropped below the
    layer that could report it.** The default buffer is 512 bytes,
    shared by every message, and the four-byte encapsulation header and
    the session framing both come out of it. That is the node's own
    writes; a sample the agent sends longer than that arrives in pieces
    (rule 25).
16. **rclc carries three of ROS 2's ten parameter types**: boolean,
    integer and double. A node moved from a workstation loses its string
    parameters.
17. **A parameter keeps the type it was declared with.** A set of a
    different type is refused, not coerced — so an integer parameter set
    from a launch file that wrote `1.0` keeps its default, silently.
18. **Only the heartbeat notices that the agent went away.** Until
    `rostransport.session_is_stale` answers true, every write succeeds
    locally and arrives nowhere.
19. **A subscription is two requests and then a loop.** Create a
    subscriber and a data reader, ask the agent for samples with
    `request_data`, and call `poll`. The agent reads from DDS and sends a
    DATA for each sample; it sends nothing for a request it accepts, and a
    STATUS for one it refuses, which `poll` answers as `ROS_RET_ERROR`
    with the number.
20. **A sample arrives without its four-byte header.** The agent takes it
    off, so the payload is the CDR body alone and the message is built as
    little-endian CDR. For a `std_msgs/msg/Int32` the payload is the four
    bytes of the number.
21. **A reliable write needs `poll` and `reliable_tick`.** The sample stays
    in the history until the agent acknowledges it. The acknowledgement is
    read by `poll`, which also sends again what the agent says it did not
    get, and `reliable_tick` announces the unacknowledged messages when the
    stream has been quiet for 100 ms. A node that writes on the reliable
    stream and calls neither has a reliable stream that never repeats
    anything, and a history that fills after four writes.
22. **A full history refuses the write.** `ROS_RET_BAD_ALLOC` from
    `write_sample_reliable` or `publish_i32_reliable` means four messages
    are unacknowledged and nothing was written. It is not an allocation
    failure.
23. **`poll` takes one message.** Call it until it answers
    `ROS_RET_SUBSCRIPTION_TAKE_FAILED`, which says nothing more is waiting
    and is not an error. A `rosexec` handle is ready when its take answered
    `ROS_RET_OK`; `rosexec.ready_from_take` is that bit.
24. **Feed the silence counter the time that passed.** `keepalive` and
    `reliable_tick` take milliseconds the caller measured. A poll that
    returned at once because a frame was waiting did not wait the timeout,
    and counting it as if it had pings the agent on every turn.
25. **A sample longer than one message needs the reliable stream and
    `poll_long`.** The agent cuts a sample that does not fit in a 512-byte
    message into FRAGMENT submessages, one to a message, and only a
    reliable stream can carry them: a best-effort stream drops a DATA that
    does not fit. Ask for the samples on `xrcewire.XRCE_STREAM_RELIABLE` and
    take them with `poll_long`, which joins the pieces in a buffer the
    caller owns. `poll` reads each piece, acknowledges it and drops it, so
    a long sample never reaches it.
26. **The reassembly buffer has a limit, and a sample over it is dropped
    with `ROS_RET_BAD_ALLOC`.** `xrcefrag.reassembly(n)` takes samples of at
    most `n` bytes, up to `XRCE_REASSEMBLY_MAX_SAMPLE`, 2,040. The call that
    meets the first piece of a longer sample answers the code once, the
    rest of its pieces are acknowledged and dropped, and the next sample
    is joined from its own first piece. A sample that came in one message
    is held to the same limit.
27. **A UDP link has no connection.** `rosagent.connect_udp` answers a link
    when the socket is made and the host resolves, whether or not an agent
    listens. A node with no agent finds out when `open_session` answers a
    session that is closed. The link sends to the agent's address and drops
    a datagram from any other.

## Reaching an agent over TCP or UDP

An agent listens on the transports it is started with, and a program names
the one it wants. The agent's own ports are chosen on its command line; 8888
is the default of its UDP transport and what `rosagent.ROS_AGENT_DEFAULT_PORT`
says.

```
MicroXRCEAgent tcp4 --port 2018
MicroXRCEAgent udp4 --port 8888
```

`rosagent.connect(host, port)` opens a TCP connection and answers a
`RosAgentLink`, or nothing when no agent is listening. A stream has no
message boundaries, so the link puts the two-byte length Micro XRCE-DDS
uses in front of each message it sends and reads one back whole.
`rosagent.connect_udp(host, port)` opens a socket and answers a
`RosUdpLink`. A datagram is one message, so nothing goes in front of it and
the link holds no buffer. Both implement `RosTransport[net]`, so every
function of `rostransport` takes either, and a program written over the
trait does not change when the transport does:

```
fn run<T: RosTransport[e]>(link: T) [e, io]
    let s = rostransport.open_session(link, rostransport.session(0xAABBCCDD, 512), 2000)
    ...
```

The UDP link is bound by what UDP is. It is not connected, so
`connect_udp` cannot tell that no agent is listening: it answers a link
whenever it can make a socket and resolve the host, and the first
`open_session` that gets no answer is what says so. It sends to the agent's
address and drops a datagram from any other. It carries 512 bytes a message,
`rosagent.ROS_UDP_MTU`, which is what the session announces to the agent, so
the agent sends no datagram longer than that; a long sample arrives in
pieces, as it does over TCP. A datagram is not retransmitted, so a lost one
is lost unless the stream it was on is reliable, which is the reliable
stream's job and not the link's.

Both were run against a Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy;
`docs/agent-run.md` has the commands and the agent's log.

## Running on a microcontroller

Nine modules build for a microcontroller with no heap allocator:
`rosret`, `rosqos`, `rosgraph` and `rosexec`, which a node consults before
it touches the wire, and `xrceframe`, `xrcewire`, `xrcestream`, `xrcefrag`
and `rosuart`, which are the wire. `tests/embedded_probe.nv` is a firmware
program that runs a hundred and twenty-one checks over them and is compiled
for a Cortex-M as part of
this package's checks, so the claim is built rather than asserted. The
program runs under QEMU and prints `PASS`.

The wire is a node's session with an agent over a UART. `xrceframe` frames
a message the way the eProsima client does: a begin flag, two addresses, a
length, byte stuffing and a CRC-16. `xrcewire` builds the messages that
open a session, create a participant, a topic, a publisher and a data
writer, and write a sample, and reads the agent's status. `rosuart` sends
them through `XrceUart`, a trait of three functions (put a byte, get a
byte, wait a millisecond) that `rosuart.console_uart` implements over
`hal.uart`. The buffers are `Vec` values the caller holds: a 512-byte
message, a 1037-byte frame and a de-framer of 584 bytes. The pure functions
of `rostransport`, which are the session's counters, build for a device
too.

**What a reliable stream costs on a device.** The stream is a `RelStream`
of five integers, 40 bytes, and a history, `Vec[u8; 2056]`, which is 2,064
bytes: four slots of 514, a message's length in two bytes and a message of
up to 512. Together 2,104 bytes of RAM, held by the caller, on top of the
message, frame and de-framer buffers every node here already has (520,
1,048 and 584 bytes). `rosuart.poll` builds its replies in a 520-byte
message on the stack, so that the sample it took is still in the caller's
message buffer when it returns. A node that keeps to the best-effort stream
pays none of this, and its code is unchanged from 0.1.1. The history holds
`xrcestream.XRCE_HISTORY` messages, 4, the number a stock micro-ROS build
keeps; a write finds the window full when that many are unacknowledged and
answers `ROS_RET_BAD_ALLOC`. A smaller history is a different constant and
a rebuild, because the buffer's size is part of its type.

**What a long sample costs on a device.** A node that wants samples longer
than 512 bytes passes `rosuart.poll_long` a reassembly buffer,
`Vec[u8; 2048]`, which is 2,056 bytes, and a `FragState` of 16. The
buffer holds the DATA submessage as the agent sent it, eight bytes of
header and ids in front of the sample, so the largest sample is
`xrcefrag.XRCE_REASSEMBLY_MAX_SAMPLE`, 2,040 bytes, and the caller's limit
(`xrcefrag.reassembly(n)`) can be lower. The buffer's size is part of its
type, as the history's is, so a different one is a different constant and a
rebuild. The samples must be asked for on the reliable stream, which costs
the 2,104 bytes above. A node that never asks for a long sample pays none of
this. `rosuart.poll_long` builds its replies in the same 520-byte scratch
message `poll` does, and leaves the sample in the caller's buffer, from its
first byte, until the next call.

**What a long sample is.** The agent writes what DDS delivers as one DATA
submessage. If the message that would carry it is longer than the 512 bytes
the node announced when it opened the session, the agent serialises the
DATA, header included, cuts it into pieces of 504 bytes, and sends each as
a FRAGMENT submessage in a message of its own on the reliable stream, the
last with bit 1 of its flags set. A `std_msgs/msg/String` of a thousand
characters is three messages of 512, 512 and 16 bytes. The reliable stream
delivers them in order, so `xrcefrag.push` appends each piece and, at the
last, checks that what it holds is one DATA and hands back the sample.

`examples/dk_talker.nv` is a node on an nRF54LM20 DK that publishes
a counter on `/novo_counter` once a second. It is 22,840 bytes of flash and
2,712 bytes of static RAM, and it ran against a real agent on a PC with the
board's two register accesses replaced by standard input and output
(`examples/uart_stdio.nv`); the run is recorded in `docs/agent-run.md`.

The other five are excluded, each for a stated reason.

`rosname` expands a relative name against a namespace, which
concatenates strings, and concatenation allocates. Its checking
functions could be called on a device; its expansion could not, and
splitting one module into two for that would leave a reader deciding
which half a function belongs to. A node in firmware holds its names as
literals and has nothing to expand.

`rosmsg` holds a payload, and a payload is a heap value.
`rostransport`'s functions that take a `RosTransport` move a `Bytes`, which
is a heap value too, and `Bytes` is not admitted at the embedded tier. A
firmware node keeps its payload in a buffer it owns, and `rosuart` moves
that buffer instead.

`rosagent` opens a TCP or UDP socket, which is the one thing in this package
that performs anything at all. The manifest names it in `host_modules`,
so a device build leaves it out.

The registry measures the tiers per module, and its page for this package
lists every module except `rosagent` at the embedded and rt tiers. Its tier
check admits a module that allocates, such as `rosname`, `rosmsg` and
`rostransport`, because a device program has a heap of fixed size. The
claim in this section is narrower: it covers the nine modules the probe
builds and the session counters of `rostransport`. The system, wasm and app
tiers cover all fourteen modules.

## What is not included

- **A serialiser.** Common Data Representation is its own subject with
  its own specification, and the ROS 2 plan for novo-lang gives it its
  own package. A second implementation here would be a second original,
  and the day the two disagreed about a padding byte, a recording
  written by one would be unreadable by the other. `rosmsg` is the
  seam: it holds the bytes, the header that says which byte order they
  are in, and the type identity, and it reads none of the payload.
- **Generated message types.** ROS 2 message definitions are `.msg`
  files, and turning one into a structure is a build-time generator
  rather than a library. Until there is one, a program writes its own
  structure and serialises it itself.
- **Bindings to rcl.** Every other ROS 2 client library is a wrapper
  over the C library `rcl`, and this one is not: the node model is
  written in novo-lang, so a program that takes it does not take a C
  toolchain with it. The consequence is that this package cannot talk
  to a DDS network directly — it talks to a micro-ROS agent, which is
  what a microcontroller does anyway.
- **CAN FD, and UDP on a device.** A micro-ROS agent listens on four links.
  This package reaches three from a PC or a device: TCP and UDP, through
  `rosagent`, and a serial line, through `rosuart` on a device. The
  agent's CAN FD transport is not reached. `rosagent` is a host module,
  because it opens a socket through the standard library, so a device that
  reaches an agent over UDP brings its own link over its own network stack;
  `rosuart` is the device's transport and takes a UART.
- **A serial port for a PC.** There is no serial port in the standard
  library, with no baud rate, parity or inter-character timeout. A device
  has `hal.uart`; a PC reaches the same code through standard input and
  output, which is how `examples/uart_stdio.nv` runs it.
- **More than one reliable stream, and reliable creation.** There is one
  reliable stream each way, the stream with id `0x80`, and a message about
  any other is ignored. The requests that create an entity go out on the
  best-effort stream, as before, and wait for their status; only samples
  and the requests for samples use the reliable one.
- **A buffer for messages that arrive out of order.** The reliable input
  side delivers a message that arrives in order and drops one that comes
  after a gap, so the agent sends the gap and what followed it again. That
  costs retransmissions and no RAM. A node on a link that loses often and
  carries large samples would want the buffer.
- **Sending a long sample.** A sample the agent sends in pieces is joined,
  and a sample the node writes is not cut: `write_sample`,
  `write_sample_reliable` and `publish_i32` build a message of at most 512
  bytes, and a sample that does not fit answers `ROS_RET_INVALID_ARGUMENT`.
  Writing FRAGMENT submessages needs the reliable output stream to number
  and keep each piece, and the history holds four messages of 514 bytes.
- **A long sample on the best-effort stream.** The agent sends no pieces on
  a best-effort stream and drops a DATA that does not fit one message, so
  there is nothing to join; the samples are asked for on the reliable
  stream.
- **A reassembly buffer of another size.** The buffer is a `Vec[u8; 2048]`,
  so a sample longer than 2,040 bytes is dropped whatever limit the caller
  names, and a node that wants more changes a constant and rebuilds. The
  buffer is also the only one: pieces of two samples are not joined at once,
  which the agent does not interleave on one stream.
- **A sample that lost a piece to the agent's HEARTBEAT.** An agent that
  gives up on messages it no longer holds moves the input side past them,
  and a sample whose pieces fell on both sides of that is dropped as a
  malformed one (`xrcefrag.FRAG_BAD`), together with the sample whose first
  piece followed it, which was joined into the same buffer. A link that
  loses messages the agent has already forgotten is the case.
- **Samples in a format other than DATA.** `read_data` asks for the DATA
  format, the sample's bytes as they are, and a DATA in any other format
  is not found. A sample reaches the node without its encapsulation
  header, which the agent takes off, so the byte order of a big-endian
  publisher is lost; `poll` builds the message as little-endian CDR.
- **A device listener for a board.** The subscription runs against a real
  agent over TCP, and over a pseudoterminal pair with the device's own code
  in `examples/uart_stdio_listener.nv`, a long sample included; it has not
  been put on a board.
- **Actions.** ROS 2's third communication pattern, with goals,
  feedback and results, is built on five topics and two services. It is
  a package of its own and rclc treats it that way.
- **Managed nodes.** The configure, activate, deactivate and cleanup
  lifecycle is a separate rcl library.
- **Discovery.** A micro-ROS node does not discover anything: it is
  told its agent's address, and the agent discovers on its behalf.
- **Executor priorities.** rclc gets them by running more than one
  executor, and so does a program using this package.

## Related packages

- **can-nv** and **modbus-nv** are the other two ways a novo-lang
  program reaches a robot's hardware. CAN is the bus inside a vehicle
  and Modbus is the protocol on an industrial sensor; ROS 2 is the layer
  above both, and a gateway node would use one of them and this one.
- **crc-nv** has the polynomial the serial framing uses, 0x8005 reflected,
  as `crc16_modbus`. That function starts from 0xFFFF, and the framing
  starts from 0, which gives a different checksum (CRC-16/ARC, whose check
  value over `123456789` is 0xBB3D). It is also a host function that builds
  a table in a list, and a device program cannot call it. `xrceframe`
  therefore computes the checksum itself, in a loop of eight steps a
  byte, and holds it to the catalogue's check value in its tests.
  **cobs-nv** is not used: the framing stuffs two byte values, which
  is not COBS.
- **The language's fixed-capacity collections**, `Vec[T; N]` and its
  family (SPEC section 14.8), hold a bounded table without an allocator.
  Nothing in this package is a collection — a pool, an executor and a
  session are each a handful of integers — but a firmware holding a table
  of subscriptions keeps it in one.

## Tests

The suite is thirteen files under `tests/`. What they assert comes from
ROS 2's own behaviour rather than from an implementation: the return
code numbering rcl publishes, the six quality-of-service profiles ROS 2
ships and the requested-versus-offered rules the DDS specification
states, the entity maxima a stock micro-ROS build is configured with,
and the name rules `rmw_validate_topic_name` applies.

`tests/rostransport_tests.nv` implements `RosTransport` over a table of
recorded bytes, at no effect at all, which is the demonstration that a
program's link can be one that touches nothing.

`tests/ros2_edge_tests.nv` covers the inputs a node's own cases do not
reach: every return code through its name table, every way a name, a
profile or a session can be refused, and the TCP link driven over a
loopback listener the file opens itself. That listener is why this file
is the one that declares `[net]`, and it is what exercises `rosagent`
rather than only naming it.

`tests/xrce_tests.nv` holds the serial framing to vectors worked out by
hand, a round trip over generated payloads and the cases a line produces:
a flag inside a payload, a wrong CRC, an escape at the end of a buffer and
a frame cut in two. `tests/rosclient_tests.nv` holds the messages to the
bytes a real Micro XRCE-DDS Agent accepted, and drives the session over a
scripted pipe and a fake UART.

`tests/xrcestream_tests.nv` holds the subscription and reliable-stream
messages to the bytes the agent sent and accepted on 2026-11-19, and the
stream's state machine to its cases: sequence numbers that wrap, a message
lost, repeated and out of order, a HEARTBEAT that finds a lost last
message, and an ACKNACK that names what to send again. Its last test runs a
sender and a receiver against each other over a link that loses messages.
`tests/rossub_tests.nv` drives `poll`, `request_data`,
`write_sample_reliable`, `reliable_tick` and `keepalive` over a pipe that
records what it is handed, and the same functions of `rosuart` over a fake
UART.

`tests/rosudp_tests.nv` drives the UDP link over loopback sockets: a
datagram with zero bytes in it goes out and comes back with its length,
nothing is put in front of it, a datagram from a stranger is dropped, and a
session opens over it. `tests/rosfrag_tests.nv` holds the FRAGMENT reader
and the joining to the bytes the agent sent for a text of a thousand
characters, with pieces in order, repeated, out of order and lost, a sample
exactly as long as the limit and one byte longer, pieces that are not one
DATA, and `poll_long` of both sessions over a pipe that records and a fake
UART.

`tests/embedded_probe.nv` is the microcontroller program described
above.

## Licence

Apache-2.0.  See `LICENSE`.
