# Changelog

All notable changes to ros2-nv are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

## 0.1.6 — 2026-11-20

A node writes a sample longer than one message, and takes a long service
request or reply: `write_sample_long`, `send_request_long`, `send_reply_long`,
`take_request_long` and `take_reply_long`, in `rostransport` over a pipe and in
`rosuart` over a UART with no heap. Run against a Micro XRCE-DDS Agent 2.4.3 and
ROS 2 Jazzy on a PC, over a pseudoterminal pair and on an nRF52840-DK. Nothing
published changed its signature, and a short sample is written byte for byte as
it was.

### Added

- **`xrcewire` and `xrcefrag`: the pieces of a write.** `begin_fragment` and
  `finish_fragment` build the message of one FRAGMENT on the reliable stream, the
  last piece flagged; `put_write_front` and `put_reply_front` write the front of
  the WRITE_DATA it cuts, whose submessage header carries the length of the whole
  and which is the first bytes of the first piece, as the eProsima client sends
  one. `xrcefrag.piece_begin` starts a piece, `piece_room` says how many bytes it
  takes, `copy_head` puts the first bytes of a joined sample in a message so that
  `request_of` and `response_of` read it, and `XRCE_PIECE_BYTES` (504) and
  `XRCE_LONG_MAX_SAMPLE` (2,048) are the constants.
- **`rostransport` and `rosuart`: `write_sample_long`, `send_request_long` and
  `send_reply_long`.** A sample that fits one message is written as
  `write_sample_reliable`, `send_request` and `send_reply` write it. A longer one
  goes out as pieces of up to 504 bytes, each with a sequence number of its own and
  a slot of the history, so the HEARTBEAT and the ACKNACK cover every piece. The
  history is not grown: a call writes as many pieces as the four slots hold,
  2,016 bytes with the front, and answers `at`, how many bytes of the sample are
  out, and `done`; the caller polls and calls again with the same `at`. A call that
  finds the history full writes nothing and answers `ROS_RET_BAD_ALLOC`. A sample
  longer than 2,048 bytes answers `ROS_RET_INVALID_ARGUMENT`. The device forms
  take the sample in a `Vec[u8; 2048]`, 2,056 bytes the caller owns.
- **`take_request_long` and `take_reply_long`** are `take_request` and `take_reply`
  over `poll_long`: they take the buffer the pieces are joined in and the
  reassembly state, and answer a request or a reply of up to 2,040 bytes whole.
  `take_request` and `take_reply` are unchanged.
- **Examples.** `examples/host_long_talker.nv` publishes a `std_msgs/String` of
  1,000, 2,000 and 2,040 characters; `examples/host_long_server.nv` serves
  `/long_reply` (a Trigger whose reply is a text of up to 2,000 characters) and
  `/long_request` (a GetParameters whose request is as long as the caller sends);
  `examples/uart_stdio_long.nv` is the device's talker run on a PC over a
  pseudoterminal pair; and `examples/dk_long_talker.nv` is the same talker on an
  nRF52840-DK, at 28,516 bytes of flash and 2,712 bytes of static RAM.
- **Tests.** `tests/roslong_tests.nv`, 15 tests, holds the pieces to the bytes the
  agent accepted for a text of a thousand characters and drives all five calls
  of both sessions, with a sample of three, four and five pieces, a window that
  fills, a pipe and a transmitter that take nothing, a place outside the sample, a
  sample that fits one message, and a request and a reply joined from the agent's
  pieces. `tests/embedded_probe.nv` runs 135 checks, six more, and passes under
  QEMU. Merged line coverage of `src/` is 1,782 of 1,787 lines; the five are the
  `// cov: skip` lines that were there.
- **`docs/agent-run.md`** records the runs: the host talker over TCP and UDP, the
  device's talker over a pseudoterminal pair, the two services, and the
  nRF52840-DK, each with the text `ros2 topic echo` or `ros2 service call`
  printed and the agent's log.
- **The interoperability suite.** `tests/interop/run.sh` runs a node of this
  package and a ROS 2 Jazzy node against each other through a Micro XRCE-DDS
  Agent, over TCP and over UDP: `host_talker` heard by an rclpy subscription,
  an rclpy publisher heard by `host_listener` (integers and a String of 1,000
  characters), `ros2 service call` answered by `host_server`, and `host_client`
  answered by an rclpy server. `tests/interop/build_agent.sh` builds the agent;
  `.github/workflows/interop.yml` runs the suite and `.github/workflows/check.yml`
  builds, tests and audits the package, on every push.

### Changed

- The README's rules 15, 22, 32 and 33, the section on a microcontroller, and the
  list of what the package leaves out describe writing a long sample; the
  bullets for sending a long sample and for a long request or reply are replaced
  by the limit of 2,048 bytes, two long samples at once, and a service call that
  waits for its pieces by itself.
- The flash of `examples/dk_sensor_node.nv` went from 29,392 to 29,476 bytes, the
  drop code of the two new result types; its static RAM stayed at 2,712 bytes.
- The minimum `novo` is 0.26.0, which has `Vec.to_list()`.  The sources and
  the tests copy a message buffer into a list with it, where a push loop
  stood in before.  Thirteen files are in the form `novo fmt` prints.

## 0.1.5 — 2026-11-20

Services: a node calls a service and serves one, with the requester and the
replier of Micro XRCE-DDS, in `rostransport` over a pipe and in `rosuart` over
a UART with no heap. Run against a Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy
on a PC and on an nRF52840-DK. Nothing published changed its signature; the
DDS names `rosname.dds_request_name` and `dds_reply_name` answer changed
(Fixed, below).

### Added

- **`xrcewire`: the requester and the replier.** `XRCE_KIND_REQUESTER` (7) and
  `XRCE_KIND_REPLIER` (8), `create_requester` and `create_replier`, which are
  `create_entity` with the kind fixed; `begin_write_reply`, which writes a
  reply's front, the replier's id and the 24-byte sample identity of the
  request it answers; `XrceIdentity`, that identity as six numbers a server
  holds between a request and its reply; `request_of` and `response_of`, which
  read a request, with its identity, or a reply, with the request id of its
  call, out of a sample `read_sample` or a poll found; `put_sample_i64`,
  `i64_at` and `identity_at`; `object_kind`. A request is a WRITE_DATA on the
  requester and a reply at a client a DATA with the call's request id in front;
  `xrcewire`'s header lays the four forms out beside the client's and the
  agent's sources.
- **`rostransport` and `rosuart`: `create_requester`, `create_replier`,
  `send_request`, `take_reply`, `take_request` and `send_reply`.** Requests
  and replies go out on the reliable stream and stay in the history until the
  agent acknowledges them; `send_request` answers the request id the reply
  quotes. `take_reply` and `take_request` are `poll` with the sample read as a
  client or a server reads it, and answer `ROS_RET_CLIENT_TAKE_FAILED` or
  `ROS_RET_SERVICE_TAKE_FAILED`, with the entity's id, for a sample that is
  another entity's, so that a node that subscribes and serves reads one pipe.
  The host forms take and answer `Bytes`; the device forms take a
  `Vec[u8; 512]` for the payload and leave the request in the caller's message
  buffer. Payloads stay opaque bytes, as for topics.
- **Examples.** `examples/host_server.nv` serves `/add_two_ints` and
  `examples/host_client.nv` calls it; `examples/uart_stdio_server.nv` is the
  device's server run on a PC over a pseudoterminal pair; and
  `examples/dk_sensor_node.nv` serves `/dk/add_two_ints` beside its topics,
  at 29,392 bytes of flash and 2,712 bytes of static RAM.
- **Tests.** `tests/rosservice_tests.nv`, 11 tests, holds the messages to the
  bytes the agent sent and accepted in two runs of `/add_two_ints` and drives
  all four calls of both sessions, with a full window, a pipe that takes
  nothing, a payload that does not fit, a session never opened, a refused
  request and a sample of another entity. `tests/embedded_probe.nv` runs 129
  checks, eight more, and passes under QEMU. Merged line coverage of `src/` is
  1,613 of 1,618 lines; the five are the `// cov: skip` lines that were there.
- **`docs/agent-run.md`** records the four runs: `ros2 service call` against
  the novo-lang server over TCP (`sum=5`), the novo-lang client against
  `ros2 run demo_nodes_py add_two_ints_server` (`sum=42`), the device server
  over a pseudoterminal pair (`sum=5` and `sum=999999999993`) and the
  nRF52840-DK (`sum=5`, `42` and `999999999993`), with the frames and the
  agent's log.

### Fixed

- **`rosname.dds_request_name` and `dds_reply_name` answered a name that is not
  a topic.** `/add_two_ints` gave `rq/add_two_ints` and `rr/add_two_ints`; the
  topics a service travels on are `rq/add_two_intsRequest` and
  `rr/add_two_intsReply`, so a program that built its XML from the old answer
  named topics no ROS 2 node uses and no call matched. They append `Request` and `Reply`; `ROS_DDS_REQUEST_SUFFIX`
  and `ROS_DDS_REPLY_SUFFIX` are new. `effective_length` is unchanged.
- **`examples/dk_sensor_node.nv` makes its reliable stream and history anew
  after each bring-up.** The agent numbers a new session from 0, and a stream
  that carried on from the old numbers would have refused everything. The node
  used the best-effort stream only until now, so it had not shown.

## 0.1.4 — 2026-11-20

A node on the nRF52840-DK, and a fix for a session that did not set up when
the agent started after the node. No signature or type changed.

### Added

- **`examples/dk_sensor_node.nv`**, a node on an nRF52840-DK that publishes
  the chip's die temperature on `/dk/temperature` once a second as a
  `std_msgs/msg/Int32` in hundredths of a degree Celsius, and takes
  `/dk/led`, a `std_msgs/msg/Int32` from 0 to 4, to switch the four LEDs
  (0 all off, 1 to 4 that LED on). It is a second example and not a change
  to `dk_talker.nv`, because it creates seven entities, takes a
  subscription and reads a peripheral, where `dk_talker.nv` is the shortest
  node there is and is written for a different board. The board's HAL has
  no binding for the TEMP peripheral, so the program reads it with
  `hw.mem_read32` and `hw.mem_write32`; the sample is an Int32 because
  `rosuart` publishes and reads that type and no package function writes a
  Float32. It built with novo 0.26.0 for `--target=nrf52840-dk
  --hci-uart=physical` at 24,712 bytes of flash and 2,712 bytes of static
  RAM, and ran against a Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy;
  `docs/agent-run.md` has the commands, the 76 samples that `ros2 topic echo`
  printed in 74 seconds and the registers read back after each LED command.

### Fixed

- **`open_session`, `create_entity` and their `rosuart` forms read past a
  message that is not the answer they wait for.** Each took the first message
  that arrived, and a `create` that found the status of another request ended
  with `ROS_RET_TIMEOUT` and left the right status on the link for the next
  request. A node that starts before its agent sends an open request each
  second; a serial port holds them, and the agent answers all of them in a
  burst when it opens the port. On the nRF52840-DK, started eight seconds
  before the agent, the node read three of those answers in place of the
  statuses of its first three creates, every create after them took the
  status of the request three before it. Every create ended with
  `ROS_RET_TIMEOUT` although the agent had created all seven entities, the
  example's bring-up answered a closed session, and the node opened another
  a second later and did the same again, for as long as it ran. Both
  `rosuart.open` and `rosuart.create` and the host's
  `rostransport.open_session` and `rostransport.create_entity` now read and
  drop up to `rostransport.ROS_STALE_FRAMES`, 8, messages that are not the
  answer, and end with the codes they ended with before when none of them
  is. The first bring-up of the same board then created all seven entities at
  once. `rosclient_tests` has the cases for both sides: a stale status, an
  INFO and a status ahead of the answer, seven messages ahead and eight, and
  a refusal behind a stale one; the host cases replay the backlog through a
  pipe that hands one message to each receive. The host case was not
  reproduced against an agent: a TCP connection is refused until the agent
  listens, and a UDP datagram sent before the agent binds its port is
  dropped, so a host node's open requests are not held for the agent the way
  a serial port holds them. A host node meets the same defect when the agent
  answers an open request later than the node waited for it. Over UDP,
  `examples/host_talker.nv` still created its four entities and published ten
  samples against an agent 2.4.3 after the change.

### Changed

- **The first samples of a freshly started agent.** The 0.1.3 notes recorded
  that `ros2 topic echo` missed samples 0 and 1 of the first reliable session
  and that the cause was not run down. It has been run down: the session
  sends the WRITE_DATA after the agent's STATUS for the data writer, the
  stream's first sequence number is 0 and each sample is written to DDS and
  acknowledged, in the runs that lost samples as in those that did not. The
  loss is on the ROS 2 side. The agent's writer is `TRANSIENT_LOCAL` and
  keeps the newest sample for a late reader, and on a machine with every core
  busy `ros2 topic echo` took about 3.8 s to subscribe, so it received the
  third sample and none before it. On an idle machine 25 runs lost nothing.
  The README names what a first sample needs, `docs/agent-run.md` has the
  runs, and the agent's side of the matched-reader question is recorded
  there: the protocol gives a node no signal for it, so the package offers no
  call that waits for a reader.
- **`examples/host_talker.nv`**: the comment on the second's wait no longer
  says it is long enough for the writer to find a subscriber.

## 0.1.3 — 2026-11-19

A node can reach an agent over UDP, and can take a sample longer than one
message. Additive: every signature and type of 0.1.2 is unchanged, `poll` and
`rosuart.poll` behave as they did, and a node that does not call the new
functions builds and behaves as it did. Both were run against a Micro XRCE-DDS
Agent 2.4.3 and ROS 2 Jazzy on 2026-11-19; `docs/agent-run.md` has the
commands and the agent's log.

### Added

- **A UDP link.** `rosagent.connect_udp(host, port)` opens a socket and
  answers a `RosUdpLink`, a second type beside `RosAgentLink`, because a
  datagram is one message and needs no length in front of it and no buffer.
  It implements `RosTransport[net]`, so every function of `rostransport`
  takes it. `connect_udp_with_mtu` and `disconnect_udp` complete it, and
  `ROS_UDP_MTU`, 512, is its default message size. The link sends to the
  agent's address and drops a datagram from any other. The `[net]` row stays
  on `rosagent` alone. This is possible because `net.udp_recv_from` answers
  the length the kernel reported since novo 0.10.0; the 0.1.0 to 0.1.2
  comments that said it cut a datagram at its first zero byte were out of
  date, and the header of `rosagent` now says what is true.
- **Long samples.** A sample that does not fit in one message is sent by the
  agent as FRAGMENT submessages on the reliable stream. The new module
  **`xrcefrag`** joins them with no allocation in a `Vec[u8; 2048]` the
  caller owns, with a limit the caller sets (`reassembly(n)`, at most
  `XRCE_REASSEMBLY_MAX_SAMPLE`, 2,040 bytes). A sample over the limit is
  dropped with all its pieces and reported once. `xrcewire.read_fragment`
  reads the submessage, `xrcestream.delivers` says whether a message is one
  the session acts on, and `rostransport.poll_long` (host, over any
  `RosTransport`, answering a `RosLongTaken`) and `rosuart.poll_long` (device,
  no heap, answering a `RosLongPoll`) take the next message and hand back the
  whole sample. A sample that came in one message is taken the same way and
  held to the same limit, so a caller reads one buffer whichever way the
  agent sent it. `ROS_RET_BAD_ALLOC` is the code for a sample dropped as too
  long; the other codes are those of `poll`.
- **`examples/host_listener.nv`** takes a message type, `int32` or `string`,
  and a transport, `tcp` or `udp`, and polls with `poll_long`;
  **`examples/host_talker.nv`** takes `udp` as a fourth argument;
  **`examples/uart_stdio_listener.nv`** takes `string` and polls with
  `rosuart.poll_long`.
- **Tests.** `tests/rosudp_tests.nv` drives the link over loopback sockets,
  zero bytes included. `tests/rosfrag_tests.nv` holds the reader and the
  joining to the three messages the agent sent for a text of a thousand
  characters, in order, repeated, out of order and lost, at the limit and one
  byte over it, as pieces that are not one DATA, and through both polls.
  `tests/embedded_probe.nv` runs 121 checks, eight more, and passes under
  QEMU.
- **`docs/agent-run.md`** records the runs: the talker and the listener over
  UDP, a text of 1,000 characters joined from three messages over UDP, over
  TCP and, with the device code, over a serial line, one of 2,100 characters
  dropped and the next one taken, a long sample on the best-effort stream
  that the agent refuses, and what each looks like in the agent's log.

### Changed

- **The UDP row of the agent table** in `docs/agent-run.md` and the "What is
  not included" list of the README no longer say UDP cannot be reached. What
  is still not reached is named there: CAN FD, sending a long sample, and a
  UDP link on a device.
- **`rostransport.poll` and `rosuart.poll`** build the ACKNACK and the
  retransmissions in a private function now shared with the new polls. What
  goes on the pipe and what they answer is unchanged, and the suites that
  held them to it pass as they were.
- **`xrcestream.receive`** asks `xrcestream.delivers` whether a message is
  delivered, where it computed the answer inline. Nothing changed.

This release requires novo 0.23.0 or later.

## 0.1.2 — 2026-11-19

A node can subscribe, and can write and read on a reliable stream. Additive:
every signature and type of 0.1.1 is unchanged, the best-effort stream is
still the default, and a node that does not call the new functions builds
and behaves as it did. Both were run against a Micro XRCE-DDS Agent 2.4.3
and ROS 2 Jazzy on 2026-11-19; `docs/agent-run.md` has the commands and the
agent's log.

### Added

- **Subscriptions.** `xrcewire.read_data` builds the READ_DATA that asks
  the agent for samples (one, a number, `XRCE_SAMPLES_UNLIMITED`, or 0 to
  stop) on the best-effort or the reliable stream; `XRCE_KIND_SUBSCRIBER`
  and `XRCE_KIND_DATAREADER` create the entities through the existing
  `create_entity`. `xrcewire.read_sample`, `copy_sample` and `sample_i32`
  read the agent's DATA. `rostransport.request_data` and `rostransport.poll`
  (host, over any `RosTransport`) and `rosuart.request_data` and
  `rosuart.poll` (device, no heap) ask for samples and take the next
  message; a sample comes back as a `RosMessage` on the host and as a
  position in the caller's message buffer on a device.
  `rostransport.keepalive` and `rosuart.keepalive` are the send-only half
  of `heartbeat`, for a program that polls, and `rosexec.ready_from_take`
  turns a take's code into a handle's bit in the ready set.
- **The reliable stream**, stream `0x80`, in both directions. The new
  module **`xrcestream`** holds it as arithmetic over integers with no
  allocation: a `RelStream` of five integers, sequence numbers that wrap at
  sixteen bits, a history of four messages in a `Vec[u8; 2056]`, the input
  side that delivers in order and asks for the rest, the output side that
  frees what an ACKNACK acknowledges, and `receive`, which says what a
  received message asks of the session. `xrcewire.heartbeat` and
  `xrcewire.acknack` build the two submessages and `read_heartbeat` and
  `read_acknack` read them. `rostransport.write_sample_reliable`,
  `rosuart.publish_i32_reliable` and `reliable_tick` on both write a sample
  that stays in the history until the agent acknowledges it, announce it
  with a HEARTBEAT when the stream has been quiet for 100 ms, and send it
  again when `poll` reads an ACKNACK that names it. The README says what a
  reliable stream costs on a device: 2,104 bytes of RAM.
- **`examples/host_listener.nv`** subscribes to `/novo_cmd` over TCP, on
  either stream; **`examples/uart_stdio_listener.nv`** is the device's
  subscription run on a PC; **`examples/host_talker.nv`** takes `reliable`
  as a third argument and writes its counter on the reliable stream.
- **Tests.** `tests/xrcestream_tests.nv` and `tests/rossub_tests.nv`, with
  frames the agent sent and accepted, the state machine's loss, duplicate,
  out-of-order, HEARTBEAT and ACKNACK cases, a sender and a receiver run
  against each other over a lossy link, and the subscription paths over a
  recording pipe and a fake UART. `tests/embedded_probe.nv` runs 113 checks,
  twelve more, and passes under QEMU.
- **`docs/agent-run.md`** records the runs: a subscription over TCP and
  over a pseudoterminal pair on both streams, the talker on the reliable
  stream read by `ros2 topic echo`, and three samples written while the
  link was down, sent again and received.

### Fixed

- **`rosagent`'s receive with a timeout of 0 waited for a byte.** A socket
  with no receive timeout set held the caller until the agent sent
  something, so a poll was not one. It now asks whether the socket is
  readable first, and answers nothing at once if it is not. Once the first
  byte of a message is in, the rest is waited for at least
  `ROS_TCP_FRAME_MS`, 1000, whatever the timeout was.

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
