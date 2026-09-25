# ros2-nv

[ROS 2](https://docs.ros.org/) is a set of libraries for building robot
software: programs called *nodes* publish and subscribe on named
*topics*, and call each other through named *services*. On a
microcontroller the client library is
[rclc](https://github.com/ros2/rclc), and a node built on it reaches the
rest of the system through [micro-ROS](https://micro.ros.org/). This
package brings rclc's node model to novo-lang.

**Status: NOT IMPLEMENTED — interface only.**  Every function is
declared with its full signature, but every body is a `todo()` that
panics when called.  The package is published so its design can be
reviewed and depended on before it is implemented.  Version 0.1.0 will
be the first working release.

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

Build and test with `novo pkg build` and `novo test tests`. Today
`novo test` fails on purpose: every test reaches a `not implemented`
panic.

## What the package contains

| Module | Contents |
| --- | --- |
| `rosret` | rcl's return codes, and the two questions to ask about one: whether the call did anything, and whether anything is wrong. They are not the same question. |
| `rosname` | The rules a node name, a namespace, a topic name and a service name have to obey; expanding a relative or private name; and the DDS names ROS 2 maps them to. |
| `rosqos` | The eight quality-of-service settings, the six named profiles ROS 2 ships, and whether a publisher's offer satisfies a subscription's request. |
| `rosgraph` | How many of each thing a firmware was built to hold, how many have been created, and whether two endpoints will connect. |
| `rosexec` | The executor as a step a caller drives, the two dispatch semantics, the three trigger policies, and periodic timers counted in the caller's own milliseconds. |
| `rosmsg` | A serialised message as bytes this package does not read, the four-byte header that says which byte order they are in, and whether the whole thing fits the transport. |
| `rostransport` | The session with the agent, the two stream kinds, and `RosTransport`, the byte pipe a program implements over its own link. |
| `rosparam` | The three parameter types a microcontroller node can have, the seven it cannot, and the rule that a parameter keeps the type it was declared with. |
| `rosagent` | A byte pipe to a micro-ROS agent over TCP. The only module in the package that opens anything. |

## How to choose an entry point

**A program checking itself at startup calls the pure functions.**
`rosname.check_topic_name`, `rosgraph.pool_admits`,
`rosgraph.can_connect` and `rosmsg.fits_mtu` take values and return
values. That is the whole of what this package can do before a node
exists, and it is most of what it is for.

**A program with a link to an agent calls `rostransport`.** Its
functions take a `RosTransport` and cost whatever that implementation
costs. A program on a development machine gets one from
`rosagent.connect`; a program on a device writes one over its own serial
port.

**A program on a device calls the four modules that build for it.** See
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
    the session framing both come out of it.
16. **rclc carries three of ROS 2's ten parameter types**: boolean,
    integer and double. A node moved from a workstation loses its string
    parameters.
17. **A parameter keeps the type it was declared with.** A set of a
    different type is refused, not coerced — so an integer parameter set
    from a launch file that wrote `1.0` keeps its default, silently.
18. **Only the heartbeat notices that the agent went away.** Until
    `rostransport.session_is_stale` answers true, every write succeeds
    locally and arrives nowhere.

## Running on a microcontroller

Four modules build for a microcontroller with no heap allocator:
`rosret`, `rosqos`, `rosgraph` and `rosexec`. `tests/embedded_probe.nv`
is a firmware program that calls eighty-one of their functions and is
compiled for a Cortex-M as part of this package's checks, so the claim
is built rather than asserted. Those four are also the four a node
consults before it touches the wire, which is why they are worth having
even where the wire never works.

The other five are excluded, each for a stated reason.

`rosname` expands a relative name against a namespace, which
concatenates strings, and concatenation allocates. Its checking
functions could be called on a device; its expansion could not, and
splitting one module into two for that would leave a reader deciding
which half a function belongs to. A node in firmware holds its names as
literals and has nothing to expand.

`rosmsg` holds a payload, and a payload is a heap value.
`rostransport`'s session holds one too. A firmware node keeps its
payload in a buffer it owns and hands this package a length.

`rosagent` opens a TCP socket, which is the one thing in this package
that performs anything at all.

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
- **UDP and serial transports.** A micro-ROS agent listens on four
  links and this package reaches one of them. A UDP datagram comes back
  from the standard library as a NUL-terminated string, so it is
  truncated at its first zero byte, and a Micro XRCE-DDS message has a
  zero in its second byte. There is no serial port in the standard
  library at all — no baud rate, no parity, no inter-character timeout.
  A device brings its own `RosTransport` over its own UART.
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
- **cobs-nv** and **crc-nv** are what a serial `RosTransport` would be
  built from: Micro XRCE-DDS frames a serial link with a begin flag, an
  escape byte and a checksum.
- **heapless-nv** holds the bookkeeping for a bounded collection while
  the caller holds the storage. Nothing in this package is a collection
  — a pool, an executor and a session are each a handful of integers —
  but a program holding a table of subscriptions would want one.

## Tests

The suite is six files under `tests/`, written against the signatures
and red until the bodies land. What they assert comes from ROS 2's own
behaviour rather than from an implementation: the return code numbering
rcl publishes, the six quality-of-service profiles ROS 2 ships and the
requested-versus-offered rules the DDS specification states, the entity
maxima a stock micro-ROS build is configured with, and the name rules
`rmw_validate_topic_name` applies.

`tests/rostransport_tests.nv` implements `RosTransport` over a table of
recorded bytes, at no effect at all, which is both the shape a full test
suite will take and the demonstration that a program's link can be one
that touches nothing.

`tests/embedded_probe.nv` is the microcontroller program described
above.

## Implementation status

| Item | Implemented |
| --- | --- |
| `rosret` — the return codes and the four that are not failures | no |
| `rosname` — the name rules, expansion and the DDS mapping | no |
| `rosqos` — the profiles and the compatibility rules | no |
| `rosgraph` — the entity pool and endpoint matching | no |
| `rosexec` — the executor step machine and timers | no |
| `rosmsg` — the envelope and the transport ceiling | no |
| `rostransport` — the session and the byte pipe | no |
| `rosparam` — the three parameter types and their rules | no |
| `rosagent` — the TCP link to an agent | no |

## Licence

Apache-2.0.  See `LICENSE`.
