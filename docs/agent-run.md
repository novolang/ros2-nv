# Running a node against a micro-ROS agent

A node built on this package is not a ROS 2 participant. It talks to an
*agent*, a program on another machine that is the DDS participant on its
behalf, and the agent has to be running before the node starts. This page
is the steps for that: which agent to start for each way the node can
reach it, what `ros2 topic echo` should print, what each failure looks
like in this package's return codes, and a run that was made against a
real agent.

The agent is either `MicroXRCEAgent`, eProsima's Micro XRCE-DDS Agent, or
`micro-ros-agent`, the same agent with micro-ROS's message types built
in. The commands below work with either; the name is the only difference.

## Which program, which agent

| The node reaches the agent by | Program | Start the agent with |
| --- | --- | --- |
| TCP, from a PC | `examples/host_talker.nv` | `MicroXRCEAgent tcp4 --port 2018` |
| A serial line, from a board | `examples/dk_talker.nv` | `MicroXRCEAgent serial --dev /dev/ttyACM<n> -b 115200` |
| A serial line, from a PC | `examples/uart_stdio.nv` | `MicroXRCEAgent serial --dev <the PC end of the line> -b 115200` |
| UDP | none | `MicroXRCEAgent udp4 --port 8888` |

**The UDP agent cannot be reached from this package.** A datagram comes
back from the standard library as a NUL-terminated string, so it is cut at
its first zero byte, and an XRCE message has a zero in its second byte.
The command is listed because it is the agent most boards on a network
use, and so that nobody starts it expecting this package to answer.

The examples use TCP port 2018 for the agent. `rosagent.ROS_AGENT_DEFAULT_PORT`
is 8888, which is the UDP agent's port, so a program that connects to a TCP
agent names the port.

## The steps

1. Source the ROS 2 setup file, so that `ros2` and the message types are
   on the path: `source /opt/ros/<distribution>/setup.bash`.
2. Start the agent from the table above, with `-v 6` the first time. At
   that level the agent logs every entity it creates.
3. Start the program.
   - Host: `novo run examples/host_talker.nv`. It takes the agent's host
     and port as arguments, `novo run examples/host_talker.nv 192.168.1.20
     2018`, and prints one line for each thing it did.
   - Board: build with the console on the UART and flash:

     ```
     novo build --target=nrf54lm20-dk --hci-uart=physical examples/dk_talker.nv
     probe-rs run --chip nRF54LM20A dk_talker.elf
     ```

     Without `--hci-uart=physical` the console is RTT, `hal.uart` has no
     wire behind it, and the agent hears nothing. The image prints
     nothing: the wire carries frames, and a log line on it would be read
     by the agent as bytes of a frame.
4. In another terminal, with the same setup file sourced and the same
   `ROS_DOMAIN_ID` (0 unless you set it):

   ```
   ros2 topic echo /novo_counter std_msgs/msg/Int32
   ```

   The type is named on the command line because `ros2 topic echo` looks
   the type up on the graph, and for the first second after the writer is
   created the graph does not know it yet.

## What `ros2 topic echo` shows

One value every second, counting up from 0:

```
data: 0
---
data: 1
---
data: 2
---
```

`ros2 topic list` shows `/novo_counter`. `ros2 topic info -v
/novo_counter` shows one publisher, with the node name
`_CREATED_BY_BARE_DDS_APP_` (the agent's writer has no ROS node behind
it, so ROS 2 shows its placeholder), the type `std_msgs/msg/Int32`, and
the QoS reliable and transient-local. A subscription with the default
profile, which `ros2 topic echo` uses, is compatible with that offer.

If the first value printed is not 0, a sample went out before the
subscription had discovered the writer. A best-effort stream does not send
a sample again, and the examples wait one second after creating the writer
for that reason.

## The names that make a ROS 2 participant see it

A micro-ROS node's entities are made by the agent in DDS, and a ROS 2
node finds a topic by its DDS name and type. Three things have to match
what ROS 2's own middleware layer writes, and none of them is checked by
the agent:

| In the ROS 2 graph | In the XML the node sends | Why |
| --- | --- | --- |
| the topic `/novo_counter` | `<name>rt/novo_counter</name>` | ROS 2 maps a topic to a DDS topic with the prefix `rt`. Without it the topic exists in DDS and not in ROS 2. `rosname.dds_topic_name` computes it. |
| the type `std_msgs/msg/Int32` | `<dataType>std_msgs::msg::dds_::Int32_</dataType>` | ROS 2's DDS type name for a message. A different spelling creates a topic of another type that nothing subscribes to. |
| the domain `ROS_DOMAIN_ID` | the participant's parent number, as the domain id | The participant is created in that DDS domain. The examples use 0. |

The four requests, in this order, with the object ids the examples use:
a participant (id `0x11`, parent: the domain id), a topic (`0x12`, parent
`0x11`), a publisher (`0x13`, parent `0x11`) and a data writer (`0x15`,
parent `0x13`). An object id is twelve bits of number and four of kind,
which `xrcewire.object_id(1, xrcewire.XRCE_KIND_DATAWRITER)` computes. The
participant, topic and data writer carry an XML description; the
publisher's is empty.

**The sample is the number alone.** The agent puts the four-byte CDR
representation header (`00 01 00 00`) in front of the sample before it
hands it to DDS. A sample that began with its own header would arrive as
`256`, the header read as the number. For a `std_msgs/msg/Int32` the four
bytes are the integer, least significant byte first.

## What each failure looks like

The host functions in `rostransport` and the device functions in `rosuart`
answer the same codes, in a `RosOutcome` whose `code` is a `rosret` code
and whose `status` is the agent's own number when it answered.

| What is wrong | What the program sees |
| --- | --- |
| No agent is listening on the port | `rosagent.connect` answers `None`; `host_talker` prints `no agent at <host>:<port>`. |
| The agent is up and the node is on the wrong serial device or at the wrong baud rate | `open_session` or `rosuart.open` answers a session whose state is closed. Nothing logs on the agent's side, because it ignores frames it cannot read. |
| The board's transmitter never takes a byte (hardware flow control, with the other end not asserting CTS) | `rosuart.send` answers false after 100000 offers of one byte; `create` answers `ROS_RET_AGENT_UNREACHABLE`. |
| An entity is created before its parent | The agent answers status `0x84`, unknown reference; the outcome's `code` is `ROS_RET_ERROR`, its `status` is `0x84`. Observed: a topic created with no participant. |
| An XML description the agent cannot read | Status `0x80`, DDS error; `ROS_RET_ERROR`. Observed: the text `not xml` as a participant. |
| The agent does not answer a create in time | `ROS_RET_TIMEOUT`, and `status` is -1. A late answer for an earlier request is not taken for this one. |
| A create before the session is open | `ROS_RET_NOT_INIT` |
| A description longer than the 512-byte message buffer | `ROS_RET_INVALID_ARGUMENT` |
| The agent is restarted while the node runs | Nothing: every `write_sample` and `publish_i32` answers `ROS_RET_OK`, because the bytes went out. The heartbeat is what notices: `rostransport.heartbeat` (host) and `rosuart.heartbeat` (device) ping the agent, and when no answer has come for `ROS_SESSION_TIMEOUT_MS` the session's state becomes `ROS_SESSION_LOST`. `dk_talker` then opens a session again; the new agent holds none of the old entities, so it creates them again. `host_talker` does not call the heartbeat. |
| The names are wrong (no `rt/` prefix, a mistyped type, another domain) | Nothing, anywhere: every create answers `ROS_RET_OK`, and `ros2 topic echo` prints nothing. This is the one failure the node cannot see; check the table above. |

## A run against a real agent, 2026-11-10

Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy on one machine, novo 0.24.0.
The agent was started with its libraries on `LD_LIBRARY_PATH` and verbose
level 6. This run was made from the PC; the board was not involved.

### Over TCP

```
MicroXRCEAgent tcp4 --port 2018 -v 6
ros2 topic echo /novo_counter std_msgs/msg/Int32
novo run examples/host_talker.nv
```

The program printed:

```
session: established
participant: code 0, agent status 0 (ok)
topic: code 0, agent status 0 (ok)
publisher: code 0, agent status 0 (ok)
datawriter: code 0, agent status 0 (ok)
published 0: code 0
...
published 9: code 0
```

The agent's log, from the session to the data writer, and the end of the
session:

```
create_client | create                 | client_key: 0xAABBCCDD, session_id: 0x81
establish_session | session established | client_key: 0xAABBCCDD, address: 127.0.0.1:32928
create_participant | participant created | client_key: 0xAABBCCDD, participant_id: 0x001(1)
create_topic | topic created | client_key: 0xAABBCCDD, topic_id: 0x001(2), participant_id: 0x001(1)
create_publisher | publisher created | client_key: 0xAABBCCDD, publisher_id: 0x001(3), participant_id: 0x001(1)
create_datawriter | datawriter created | client_key: 0xAABBCCDD, datawriter_id: 0x001(5), publisher_id: 0x001(3)
delete_client | delete | client_key: 0xAABBCCDD
destroy_session | session closed | client_key: 0xAABBCCDD, address: 127.0.0.1:32928
```

`ros2 topic echo` printed `data: 0` to `data: 9`, each followed by `---`.
`ros2 topic list` showed `/novo_counter`, and `ros2 topic info -v`
showed one publisher and one subscription, the type `std_msgs/msg/Int32`,
and both ends reliable and transient-local.

### Over a serial line, with the device code

`examples/uart_stdio.nv` is `dk_talker.nv` with a host `main`. On a host,
`hal.uart` is standard input and output, so `ConsoleUart`, the framing and
the requests all run; what is not run is the board's two register accesses.
The line was a pair of connected pseudoterminals:

```
socat pty,raw,echo=0,link=ttyAGENT pty,raw,echo=0,link=ttyBOARD
MicroXRCEAgent serial --dev ttyAGENT -b 115200 -v 6
ros2 topic echo /novo_counter std_msgs/msg/Int32
novo build examples/uart_stdio.nv -o uart_stdio
./uart_stdio <>ttyBOARD >&0
```

The program printed `published 0 to 9, silence 0 ms` on its error output;
the silence of 0 says the agent answered the last of its pings. The agent's
log, with its address 1 being the frame address of the node:

```
create_client | create                 | client_key: 0xAABBCCDD, session_id: 0x81
establish_session | session established | client_key: 0xAABBCCDD, address: 1
create_participant | participant created | client_key: 0xAABBCCDD, participant_id: 0x001(1)
create_topic | topic created | client_key: 0xAABBCCDD, topic_id: 0x001(2), participant_id: 0x001(1)
create_publisher | publisher created | client_key: 0xAABBCCDD, publisher_id: 0x001(3), participant_id: 0x001(1)
create_datawriter | datawriter created | client_key: 0xAABBCCDD, datawriter_id: 0x001(5), publisher_id: 0x001(3)
```

`ros2 topic echo` printed `data: 0` to `data: 9`.

What the real agent taught the package, which the recorded-frame tests of
0.1.0 had accepted:

- `open_session` had sent the four bytes of the client key and taken any
  reply for a session. It now sends CREATE_CLIENT and reads the agent's
  STATUS_AGENT.
- A request id is two bytes, high byte first, and the agent echoes the
  bytes it was sent. The first version of the new code wrote it low byte
  first and never recognised an answer.
- The agent's `pseudoterminal` transport did not answer the frames sent to
  its pseudoterminal; the `serial` transport on a pty pair did, with the
  same bytes. The run above uses the pair.

## The board

This part is prepared and has not been run: the two nRF54LM20 DKs were in
use for other work on the day of the run above.

What the run needs:

1. A DK, flashed with the image from step 3 above. The image is 22,840
   bytes of flash, of which the program is 8,956, and 2,712 bytes of
   static RAM.
2. The PC end: the DK's first virtual COM port, which the J-Link presents
   as a `/dev/ttyACM<n>`; `ls -l /dev/serial/by-id/` names it, ending in
   `-if00`.
3. The agent on that device: `MicroXRCEAgent serial --dev /dev/ttyACM<n>
   -b 115200`.
4. `ros2 topic echo /novo_counter std_msgs/msg/Int32`.

Three things to look at if nothing arrives, in the order they are likely:

- **Hardware flow control.** The board's table says UARTE30 runs with
  RTS/CTS on P0.06 to P0.09. If the J-Link holds CTS deasserted, the
  transmitter takes no byte, `send` answers false and the node never
  opens a session. The agent's serial port setup is the PC's decision;
  `stty -F /dev/ttyACM<n> -a` shows whether `crtscts` is on. The fix is on
  the PC or in the DK's Board Configurator, not in this package.
- **The console.** An image built without `--hci-uart=physical` writes to
  RTT. `probe-rs`'s output will show nothing either way, since the image
  prints nothing.
- **A second reader of the port.** ModemManager, or a terminal program, on
  the same device reads the frames and the agent hears fewer of them.
