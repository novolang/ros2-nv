# Changelog

All notable changes to ros2-nv are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

## 0.1.1 — 2026-11-10

A node can be a micro-ROS node over a UART. Additive: every signature and
type of 0.1.0 is unchanged, and three behaviours that never worked against
a real agent now do, as named below.

### Added

- **`xrceframe`**, the serial framing of Micro XRCE-DDS with no
  allocation. A framer (`encode`) writes begin flag, source and remote
  address, a 16-bit length, the payload and a CRC-16 into a buffer the
  caller owns, stuffing every byte after the flag; a de-framer (`deframer`,
  `push_byte`, `feed`) takes bytes one at a time or in a slice and answers
  whole frames. The layout and the polynomial are the eProsima client's
  (`stream_framing_protocol.c`): 0x7E begins, 0x7D escapes and the next
  byte is exclusive-ored with 0x20, the length counts the payload before
  stuffing, and the CRC is CRC-16/ARC (0x8005 reflected, initial value 0,
  no final exclusive-or) over the payload before stuffing, low byte first.
- **`xrcewire`**, the messages of a client in a `Vec[u8; 512]`:
  CREATE_CLIENT, CREATE (XML) for a participant, topic, publisher and
  data writer, WRITE_DATA, DELETE and a GET_INFO ping, and `read_reply`,
  which finds the agent's STATUS_AGENT, STATUS or INFO in a received
  message.
- **`rosuart`**, the session over a UART for a device, with no heap:
  `open`, `create`, `publish_i32`, `heartbeat`, `send` and `receive`, over
  `XrceUart[e]`, a trait of three functions; `console_uart` implements it
  over `hal.uart`.
- **`rostransport.create_entity` and `rostransport.write_sample`**, the
  host counterparts over any `RosTransport`, with `RosOutcome`, which
  carries the session, a `rosret` code and the agent's status number.
- **`examples/host_talker.nv`**, a talker over the TCP link;
  **`examples/dk_talker.nv`**, the same on an nRF54LM20 DK over its UART;
  **`examples/uart_stdio.nv`**, the device's code run on a PC with standard
  input and output as the UART.
- **`docs/agent-run.md`**, the steps to run a node against an agent, what
  `ros2 topic echo` shows, what each failure looks like in the return
  codes, and a run against a Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy
  recorded on 2026-11-10.
- Two test files, `tests/xrce_tests.nv` and `tests/rosclient_tests.nv`,
  and six more checks in `tests/embedded_probe.nv`, which runs under QEMU.

### Changed

- **`open_session`, `close_session` and `heartbeat` speak XRCE.** They
  sent four bytes of client key and took any reply for an answer, which a
  real agent ignores. `open_session` now sends CREATE_CLIENT and reads the
  STATUS_AGENT, `close_session` sends DELETE, and `heartbeat` sends a
  GET_INFO ping and takes an INFO for the answer. The recorded-frame tests
  that had accepted the old behaviour use a STATUS_AGENT the agent sent.
- **The pure session functions of `rostransport` are embedded tier**:
  `session`, `session_is_ready`, `session_silent`, `session_heard`,
  `session_is_stale`, `session_established`, `session_next_request`,
  `session_wrote`, `session_with_state` (now `pub`), `sequence_is_next`,
  `sequence_is_old`, `session_state_name`, `framing_overhead`,
  `stream_for` and `stream_name`. They are integer arithmetic over a
  `@value`; they were system tier only because they spelled the struct in
  a `system` block.

### Named as decided

**The sample in a WRITE_DATA carries no encapsulation header.** The agent
writes `00 01 00 00` itself before the sample reaches DDS
(`TopicPubSubType::serialize`), so for a `std_msgs/msg/Int32` the bytes are
the four of the number. A sample that began with its own header arrived in
ROS 2 as 256. `rosmsg.encode_envelope`, which writes a header, is not what
a WRITE_DATA carries.

**A request id is two bytes, high byte first.** The agent echoes the bytes
it received, and a reader that compares them as a number must read them the
way they were written. The first version of the new code wrote them low byte
first and no answer ever matched.

**Everything goes on the best-effort stream, with session id 0x81.** The
session id has its top bit set, so the message header has no client key
(the agent finds the client by the link), and CREATE carries the replace
flag so that a node that restarts does not meet its own entities.

**The CRC is written here and not taken from crc-nv.** crc-nv has the
polynomial as `crc16_modbus`, which starts from 0xFFFF where the framing
starts from 0, and it is an app-tier function that builds a list, so a
device program cannot call it. The loop is eight steps a byte, and the
tests hold it to the catalogue's check value for CRC-16/ARC.

**The device functions do not implement `RosTransport`.** The trait moves a
`Bytes`, and the embedded tier admits `len` and the region functions of
`bytes` and nothing that reads or builds one. `rosuart` moves a `Vec`
instead, and `RosOutcome` is the shared answer.

### Named as limited

**Streams are best-effort only.** A reliable stream's numbering, history
and acknowledgements are not written, so a sample lost on the wire is lost.

**`send_message` still sends an envelope and nothing else.** It sends the
four-byte header and the payload without an XRCE message around them, which
no agent reads as a sample. `write_sample` is the function that publishes;
`send_message` is kept as it was so that no signature changes.

**There are no subscriptions.** The requests that create a data reader and
the DATA submessages that carry samples back are not written.

**Seven loops copy a `Vec` into a list one element at a time.** The
standard library has no conversion for the family and a lambda may not
capture a `Vec`, so each loop carries the tag
`workaround(vec-has-no-list-conversion)`, the filing in the novo
repository that names the missing conversion. One loop is in `rostransport`
(`wire_bytes`) and six are in the tests.

**The board run is prepared and not made.** The talker for the nRF54LM20 DK
builds (22,840 bytes of flash, 2,712 bytes of static RAM) and its code ran
against a real agent over a serial line on a PC; the DK itself was not
flashed.

## 0.1.0 — 2026-11-03

### Changed

- **The name tables match on their own constants again.**  Nine
  functions — `rosret.ros_ret_name`, `rosqos.policy_name` and
  `rosqos.compat_advice`, `rosgraph.capacity_of`, `rosgraph.used_of`
  and `rosgraph.entity_name`, `rosexec.semantics_name` and
  `rosexec.trigger_name`, and `rosname.name_error_name` — spelled each
  arm's value as a literal with a `// CONSTANT` comment beside it,
  because a `pub const` named in a `match` pattern was read as a
  binding on novo 0.20.1.  The compiler defect is fixed in novo 0.20.2,
  so every arm names its constant and the comments are gone.  The 0.1.0
  entry below does not name that workaround; this entry is where it is
  recorded.  Nothing else moved: every signature, effect row, arm value
  and doc comment is what 0.1.0 published, and the suites and the merged
  line coverage are unchanged.

This release requires novo 0.23.0 or later.

## 0.1.0 — 2026-10-10

The bodies.  Everything 0.0.3 declared with a `todo()` answers now, and
nothing changed shape to let it: every signature, type and effect row is
the one the interface release published, so a program that compiled
against 0.0.3 compiles against this.  `stability` is `experimental`.

### Added

- All nine modules, implemented behind the signatures 0.0.1 published.
- `tests/ros2_edge_tests.nv` — the inputs a node's own cases do not
  reach.  Every return code and every subsystem through its name table;
  every rule a name, a profile, a policy or a session state can be
  refused by; the clamps and the empty ready set an executor can be
  built with; and the TCP link, driven over a loopback listener the file
  opens itself.  That listener is why this is the one file in the suite
  that declares `[net]`, and why `rosagent` is exercised rather than
  named.
- Three `use` lines the package's own build could not notice.
  `rosgraph` uses `rosqos` and `rosret`, `rosexec` uses `rosgraph` and
  `rosret`, and `rosagent` uses `rostransport`.  A program that imports
  one module and nothing else is what finds a missing one, because
  `novo build --check` over the package loads all nine together.
- One `// cov: skip` marker, in `rosname`, over the empty-string guard
  in `ends_with_byte`.  Both callers refuse an empty name before they
  reach it, so no input selects that line.  Every other line under
  `src/` runs in the suite.

### Named as decided

**The spin walk is over the ready handles, and the cursor counts the
ones already dispatched.**  `spin_step` skips `cursor` ready handles and
answers the next one, and `spin_advance` moves the cursor by one, so no
handle runs twice in one spin and a spin that gives the scheduler its
turn resumes where it stopped.  Registration order is the schedule.  A
trigger that names one handle walks a set holding only that handle: the
policy picks the callback and the walk picks nothing.

**A sequence number is old when its forward distance from the last
accepted one is less than half the space and it is not the next
number.**  XRCE sequence numbers are sixteen bits and wrap, so
`sequence_is_old` asks `(seq - input_seq) mod 65536 < 32768` and then
excludes the next number.  That exclusion is what makes the story true
rather than nearly true: 0 arriving after 65535 is the next message and
not one from an hour ago, and the plain `<` that reads correctly in
every test rejects every message for half the sequence space once the
counter has gone round.

**The representation identifier in the encapsulation header is written
most significant byte first, whatever the payload's byte order is.**
The four-byte header is a representation identifier and two option
bytes.  The identifier travels big-endian even when the numbers behind
it are little-endian, and `rosmsg.encode_envelope` and
`rosmsg.decode_envelope` are the only two places that asymmetry is
spelled.

### Named as limited

**A link to an agent cannot be built without a socket, and its `open`
field cannot be written through `self`.**  `RosAgentLink` is opened by
`rosagent.connect`, or by `link_over` over a socket a caller already
has, and both need `[net]`; there is no socket-free constructor for a
test at a lower row to build one from.  The field records how the link
is opened and is never cleared: `ros_close` closes the socket and
leaves `open` true, so a caller that asks `ros_is_open` afterwards gets
an answer about how the link was made rather than about the socket.
The two guards that read the field are for a link built directly, by
the struct literal, rather than by either constructor.

## 0.0.4 — 2026-10-25

A file that names a sibling module's type, function or constant now has the `use` line for that module (E2033, E2003).  No signature and no behaviour changed.

## 0.0.3 — 2026-10-06

README only.  No signature, type or effect row changed, and every body is
still `todo()`.

- The README's "Running on a microcontroller" section says what the
  registry shows: eight modules at the embedded and rt tiers, every one
  except `rosagent`, and all nine at system, wasm and app.  The
  section's claim, that four modules allocate nothing, is unchanged.
- The README names the language's fixed-capacity collections (SPEC
  section 14.8) for a firmware's table of subscriptions.  It named
  heapless-nv, which is withdrawn.
- The example carries the interface stamp beside it.

## 0.0.2 — 2026-09-25

The README example compiles with novo 0.10.0.  It named a local `pub`,
which is a reserved word.  The two endpoints are now named `publisher`
and `subscription`.  No change to the interface, and every body is
still `todo()`.

## 0.0.1 — 2026-09-15

The **interface**: every signature and every effect row, and no bodies.
`stability = "draft"`, and the release is recorded `implemented = false`.

### Added

- `rosret` — rcl's own return codes, as integers because that is what
  `rcl_ret_t` is and because an enum carrying the offending name would
  be a heap value in an interrupt handler.  `ros_ret_is_error` is the
  load-bearing function: `RCL_RET_SUBSCRIPTION_TAKE_FAILED` is NOT an
  error — a wait set says a subscription has data, the take finds none,
  and the code comes back, routinely — and nor are the client and
  service take codes or `RCL_RET_TIMEOUT`.  Almost every rclc example
  tests `ret != RCL_RET_OK`, so a working node prints failures under
  load and an operator learns to ignore its log.  Two questions, not
  one: whether the call did anything, and whether anything is wrong.
- `rosqos` — the eight settings, the six profiles ROS 2 ships, and
  `compatible`.  THE LOAD-BEARING INTERFACE OF THE PACKAGE: an
  incompatible pair is created successfully, reports healthy and never
  connects, with nothing logged anywhere — and the failure is worse on
  a microcontroller, which has no `ros2 topic echo`.  The relation is
  not symmetric and the function says WHICH policy refused.  Three
  policies do not participate in matching at all, which is where people
  look first.
- `rosgraph` — the entity pool a micro-ROS firmware was built with,
  counted.  The defaults are ONE of everything and four messages of
  history, and the first thing anybody writing a second publisher
  discovers is that the second one does not exist.  `can_connect` folds
  the two silent mismatches into one code: a type disagreement and a
  settings disagreement both connect nothing and report nothing.
  `effective_depth` is the third silent reduction — a profile asking to
  keep ten against a build that holds four keeps four.
- `rosexec` — the executor INVERTED.  rclc stores a function pointer
  per handle and calls it from inside `spin_some`; written that way
  here, every callback would share one effect row, so a node with one
  callback that writes a GPIO would charge every caller of `spin_some`
  with hardware access, and a `@value` could not be a message (E2015).
  `spin_step` answers which handle is ready and the caller dispatches.
  The ready set is a bit per handle in one integer, which caps a single
  executor at 64 handles and makes a spin a value.  Also: publishers
  are not handles, registration order is the schedule, and a late timer
  either catches up or does not — a choice a PID controller cares about.
- `rosname` — the rules `rmw_validate_topic_name` applies, answered in
  the caller's own code rather than as an opaque code from three layers
  down, plus the `rt/` and `rq/` and `rr/` prefixes a DDS tool shows and
  the length budget they eat.
- `rosmsg` — the payload as bytes this package does not read, and the
  four-byte encapsulation header it must: the byte-order flag travels
  with the payload rather than with the type, and a reader that skips it
  is wrong by a factor of sixteen million.  `fits_mtu`, because a
  message over the transport's buffer is dropped BELOW the layer that
  could report it.
- `rostransport` — `RosTransport[e]`, the session, and the mapping from
  a reliability setting to an XRCE stream kind, which is where quality
  of service actually happens between a device and its agent.  The
  heartbeat is the only thing that notices an agent restart; until it
  does, every write succeeds locally and arrives nowhere.  Sequence
  numbers are sixteen bits and WRAP, so `sequence_is_old` is modular
  arithmetic and not a `<`.
- `rosparam` — the three parameter types rclc carries of ROS 2's ten,
  and the rule that a parameter keeps the type it was declared with, so
  an integer parameter set from a launch file that wrote `1.0` keeps its
  default silently.
- `rosagent` — the host module: a TCP link to a micro-ROS agent through
  `std.net`'s byte pair, `[net]` and nothing else.
- `tests/embedded_probe.nv` — eighty-one checks over `rosret`, `rosqos`,
  `rosgraph` and `rosexec`, built for `--target=nrf52-qemu`.
- API tests in six files, red until the bodies land.

### Named as missing

**A CDR package.**  `cdr-nv` is already a row in this project's ROS 2
plan and this package depends on nothing: a second implementation of the
serialisation here would be a second original, and the day the two
disagreed about a padding byte a recording written by one would be
unreadable by the other.

**A binary datagram socket and a serial port.**  A micro-ROS agent
listens on UDP, TCP, a serial line and CAN FD, and this package reaches
one of them.  `net.udp_recv_from` answers a NUL-terminated `Str`, so a
datagram is truncated at its first zero byte and a Micro XRCE-DDS
message has a zero in its second; and there is no serial port in the
standard library at all.  Both rows are already open from other
packages' work — ntp-nv named the first and modbus-nv the second — and
this package is the third to want them.

**A message-definition generator.**  Turning a `.msg` file into a
novo-lang structure is a build-time tool rather than a library, and
until there is one a program writes its own structure and serialises it
itself.

### Named as decided

**The row said "a port of rclc" and the grid says the grid is native,
so this is not a binding.**  The project's ROS 2 plan, written before
the interfaces decision, recommends binding `rcl` by `@ffi`.  A package
that does that is layer `sys`, category `bindings`, named `librcl-sys`,
and sits on the bindings shelf rather than on the grid — and nothing on
the grid may depend on it.  The row for this package is `embedded` and
`host`, so what is staged here is rclc's node model written in
novo-lang.  A `librcl-sys` row on the shelf is still worth having, for a
program on a workstation that wants to be a DDS participant proper; it
is a different package with a different name and this one does not wait
for it.
