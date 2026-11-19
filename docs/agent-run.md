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
| TCP, from a PC | `examples/host_talker.nv`, `examples/host_listener.nv` | `MicroXRCEAgent tcp4 --port 2018` |
| A serial line, from a board | `examples/dk_talker.nv` | `MicroXRCEAgent serial --dev /dev/ttyACM<n> -b 115200` |
| A serial line, from a PC | `examples/uart_stdio.nv`, `examples/uart_stdio_listener.nv` | `MicroXRCEAgent serial --dev <the PC end of the line> -b 115200` |
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
| A data reader is asked for before it exists, or the id is wrong | The agent answers a STATUS with `0x84`, unknown reference, on the reliable stream; `poll` answers `ROS_RET_ERROR` with `status` `0x84`. |
| A sample is expected and none arrives | `poll` answers `ROS_RET_SUBSCRIPTION_TAKE_FAILED`, which is not an error. Check that the publisher's QoS is compatible with the data reader's, which `rosqos.compatible` answers, and that the topic and type names are the ones in the table above. |
| The reliable stream's history is full | `write_sample_reliable` and `publish_i32_reliable` answer `ROS_RET_BAD_ALLOC` and write nothing, because `XRCE_HISTORY` messages are unacknowledged. Call `poll` so the agent's ACKNACKs are read, and `reliable_tick` so the stream announces itself. |
| A sample written on the reliable stream never arrives although the pipe took it | It arrives once the node hears from the agent: `reliable_tick` announces the unacknowledged messages every 100 ms, the agent answers an ACKNACK naming what it lacks, and `poll` sends those again. A node that writes and never calls `poll` loses what the wire loses. |
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

## A run with subscriptions and the reliable stream, 2026-11-19

Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy on one machine, novo 0.26.0,
agent verbose level 6. The board was not involved. The agent was started
with its libraries on `LD_LIBRARY_PATH`:

```
MicroXRCEAgent tcp4 --port 2038 -v 6
```

In the log excerpts below `recv` is a message the agent received and `send`
one it sent, as its verbose log prints them, with the message's bytes.

### (a) A subscription over TCP

```
novo build examples/host_listener.nv -o host_listener
./host_listener 127.0.0.1 2038 best_effort 12
ros2 topic pub --once /novo_cmd std_msgs/msg/Int32 "{data: 7}"
```

The program printed:

```
session: established
participant: code 0, agent status 0 (ok)
topic: code 0, agent status 0 (ok)
subscriber: code 0, agent status 0 (ok)
datareader: code 0, agent status 0 (ok)
request: code 0
sample 0: data 7, 4 bytes
received 1 sample(s)
```

The agent's log has the subscriber and the data reader created, the
READ_DATA it accepted, the sample it read from DDS, and the DATA it sent:

```
create_subscriber | subscriber created | client_key: 0xAABBCCDD, subscriber_id: 0x001(4), participant_id: 0x001(1)
create_datareader | datareader created | client_key: 0xAABBCCDD, datareader_id: 0x001(6), subscriber_id: 0x001(4)
recv  81 01 04 00 08 01 10 00 00 05 00 16 01 00 00 01 FF FF 00 00 00 00 00 00
read_fn [==>> DDS <<==] len: 4   07 00 00 00
send  81 01 04 00 09 01 08 00 00 05 00 16 07 00 00 00
```

The READ_DATA is `request_data` for every sample (`0xFFFF`) on stream 1, and
the DATA is stream 1, sequence 4, for request 5 and data reader `0x0016`.
The sample is the four bytes of the number, with no encapsulation header: the
agent takes it off on the way. The same on the reliable stream:

```
./host_listener 127.0.0.1 2038 reliable 14
ros2 topic pub --once /novo_cmd std_msgs/msg/Int32 "{data: 11}"
ros2 topic pub --once /novo_cmd std_msgs/msg/Int32 "{data: -3}"
```

```
sample 0: data 11, 4 bytes
sample 1: data -3, 4 bytes
received 2 sample(s)
```

The READ_DATA names stream `0x80` (`... 80 00 00 01 FF FF ...`); the agent
sends each DATA on it with a sequence number (`81 80 00 00 09 01 08 00 00
05 00 16 0B 00 00 00`), and the node answers each with the ACKNACK the agent
accepted (`81 00 00 00 0A 01 05 00 01 00 00 00 80`: first number not
received 1, no message missing, stream `0x80`).

### (a) The same over a serial line, with the device code

`examples/uart_stdio_listener.nv` is the device's subscription (`rosuart`
over `ConsoleUart`) with a host `main`, as `uart_stdio.nv` is the device's
talker. The line was a pair of connected pseudoterminals:

```
socat pty,raw,echo=0,link=ttyAGENT pty,raw,echo=0,link=ttyBOARD
MicroXRCEAgent serial --dev ttyAGENT -b 115200 -v 6
novo build examples/uart_stdio_listener.nv -o uart_stdio_listener
./uart_stdio_listener best_effort 12 <>ttyBOARD >&0 2> listener.out
ros2 topic pub --once /novo_cmd std_msgs/msg/Int32 "{data: 7}"
```

`listener.out` held:

```
sample 0: data 7
received 1 sample(s), silence 516 ms
```

With a fresh pair and agent, `./uart_stdio_listener reliable 14 <>ttyBOARD >&0
2> listener.out` and publishing 11 and -3 gave:

```
sample 0: data 11
sample 1: data -3
received 2 sample(s), silence 522 ms
```

and the agent's log has the DATA on stream `0x80` at sequence 0 and 1 (`81
80 00 00 09 01 08 00 00 05 00 16 0B 00 00 00`, `81 80 01 00 ... FD FF FF
FF`) and the node's ACKNACKs for 1 and 2 after them. The silence of 516 and
522 ms is the time since the last message the agent sent; the node pings
once a poll finds the agent quiet for 100 ms, and a poll on the host takes
about 250 ms.

**Use a fresh pair and a fresh agent for each run.** The agent's answers to
the last pings of a run stay in the pseudoterminal, and the next run's
`open` reads the first frame as the answer to its CREATE_CLIENT. It is an
INFO, not a STATUS_AGENT, so the session stays closed and the program prints
`no session`. This was seen: the second run on a pair the first had used.

### (b) The talker on the reliable stream

```
ros2 topic echo /novo_counter std_msgs/msg/Int32
./host_talker 127.0.0.1 2038 reliable
```

`host_talker` printed, for each of ten samples:

```
published 0: code 0
  after a second: 0 unacknowledged
...
published 9: code 0
  after a second: 0 unacknowledged
```

and `ros2 topic echo` printed `data: 0` to `data: 9`, each followed by `---`.
The agent's log has the node's WRITE_DATA on stream `0x80` and its ACKNACK
for each:

```
recv  81 80 03 00 07 01 08 00 00 08 00 15 03 00 00 00
send  81 00 00 00 0A 01 05 00 04 00 00 00 80
```

(stream `0x80`, sequence 3, request 8, writer `0x0015`, the integer 3; then
the agent's ACKNACK, first number not received 4).

### (c) A sample written while the node cannot be reached

A relay between the node and the agent loses whole messages in both
directions while a file exists. It reads the two-byte length in front of
each message on the stream transport, then the message, and forwards or
drops it, so the framing stays in step:

```python
import os, socket, sys, threading

def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf

def pump(src, dst, flag, name):
    while True:
        head = read_exact(src, 2)
        body = read_exact(src, head[0] + head[1] * 256) if head else None
        if body is None:
            break
        if os.path.exists(flag):
            print(f"{name}: dropped {len(body)} bytes: {body.hex(' ')}", flush=True)
            continue
        dst.sendall(head + body)

listen_port, agent_port, flag = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", listen_port))
server.listen(1)
while True:
    node, _ = server.accept()
    agent = socket.create_connection(("127.0.0.1", agent_port))
    threading.Thread(target=pump, args=(node, agent, flag, "node->agent"), daemon=True).start()
    threading.Thread(target=pump, args=(agent, node, flag, "agent->node"), daemon=True).start()
```

```
python3 lossy_proxy.py 2039 2038 down
ros2 topic echo /novo_counter std_msgs/msg/Int32
./host_talker 127.0.0.1 2039 reliable
touch down        # when the program has printed "published 2"
rm down           # when it has printed "published 5"
```

The link was down while samples 3, 4 and 5 were written. The program
printed:

```
published 2: code 0
  after a second: 0 unacknowledged
published 3: code 0
  after a second: 1 unacknowledged
published 4: code 0
  after a second: 2 unacknowledged
published 5: code 0
  after a second: 0 unacknowledged
published 6: code 0
...
```

`code 0` for each: the pipe took the bytes, and they went nowhere. The relay
dropped the three WRITE_DATA messages and twenty of the node's HEARTBEATs,
ten for `3 to 3` and ten for `3 to 4`, one every 100 ms, as it should have:

```
node->agent: dropped 16 bytes: 81 80 03 00 07 01 08 00 00 08 00 15 03 00 00 00
node->agent: dropped 13 bytes: 81 00 00 00 0b 01 05 00 03 00 03 00 80     (ten of these)
node->agent: dropped 16 bytes: 81 80 04 00 07 01 08 00 00 09 00 15 04 00 00 00
node->agent: dropped 13 bytes: 81 00 00 00 0b 01 05 00 03 00 04 00 80     (ten of these)
node->agent: dropped 16 bytes: 81 80 05 00 07 01 08 00 00 0a 00 15 05 00 00 00
```

When the file was removed, the next HEARTBEAT reached the agent, which
answered with an ACKNACK naming the three messages, and the node sent them
again. The agent's log:

```
recv  81 00 00 00 0B 01 05 00 03 00 05 00 80       HEARTBEAT, first 3, last 5
send  81 00 00 00 0A 01 05 00 03 00 00 07 80       ACKNACK, first 3, bitmap 0x0007: 3, 4 and 5 are missing
recv  81 80 03 00 07 01 08 00 00 08 00 15 03 00 00 00      sent again
send  81 00 00 00 0A 01 05 00 04 00 00 03 80       ACKNACK, first 4, bitmap 0x0003
recv  81 80 04 00 07 01 08 00 00 09 00 15 04 00 00 00
send  81 00 00 00 0A 01 05 00 05 00 00 01 80
recv  81 80 05 00 07 01 08 00 00 0A 00 15 05 00 00 00
send  81 00 00 00 0A 01 05 00 06 00 00 00 80       ACKNACK, first 6: everything is held
```

Messages 4 and 5 arrived twice, because each ACKNACK the node read sent again
everything its bitmap still named, and the agent took the second copy for a
duplicate and acknowledged it again. `ros2 topic echo` printed `data: 0` to
`data: 9` once each, in order.

### What this run taught the package

- The agent's bitmap is 16 bits with the high byte first, and bit `j` is the
  message `first + j`: `00 07` names 3, 4 and 5 when the first is 3. Read
  low byte first it is 0x0700, which names 11, 12 and 13.
- In these runs the agent sent no HEARTBEAT for its own output stream,
  because the node acknowledged every DATA at once, as `poll` does. The
  HEARTBEAT reader is therefore tested on bytes derived from the client's
  serialiser, and the HEARTBEAT the node sends is the recorded one.
- `host_listener` on the host, and the pseudoterminal runs, ping from the
  silence counter, which has to be fed the time that passed and not the
  length of the wait. A poll that returns at once because a frame was
  there, counted as 200 ms, makes a loop that pings on every turn.

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
