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
| UDP, from a PC | `examples/host_talker.nv`, `examples/host_listener.nv`, with `udp` as the last argument | `MicroXRCEAgent udp4 --port 2018` |
| A serial line, from a board | `examples/dk_talker.nv`, `examples/dk_sensor_node.nv` | `MicroXRCEAgent serial --dev /dev/ttyACM<n> -b 115200` |
| A serial line, from a PC | `examples/uart_stdio.nv`, `examples/uart_stdio_listener.nv` | `MicroXRCEAgent serial --dev <the PC end of the line> -b 115200` |

The examples use port 2018 for either agent, TCP or UDP.
`rosagent.ROS_AGENT_DEFAULT_PORT` is 8888, which is the UDP agent's own
default, so a program that does not name the port gets that one. The
transport is the program's choice, `rosagent.connect` or
`rosagent.connect_udp`, and the agent has to be started for the same one: an
agent started with `tcp4` does not read a datagram and one started with
`udp4` does not accept a connection.

## The steps

1. Source the ROS 2 setup file, so that `ros2` and the message types are
   on the path: `source /opt/ros/<distribution>/setup.bash`.
2. Start the agent from the table above, with `-v 6` the first time. At
   that level the agent logs every entity it creates.
3. Start the program.
   - Host: `novo run examples/host_talker.nv`. It takes the agent's host
     and port as arguments, `novo run examples/host_talker.nv 192.168.1.20
     2018`, and prints one line for each thing it did. A fourth argument,
     `udp`, reaches an agent started with `udp4`: `novo run
     examples/host_talker.nv 192.168.1.20 2018 best_effort udp`.
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
| No agent is listening on a UDP port | `rosagent.connect_udp` answers a link, because UDP has no connection to refuse. `open_session` answers a session whose state is closed once its timeout has passed, and nothing logs anywhere. Observed: `host_talker 127.0.0.1 2999 best_effort udp` with nothing on the port printed `session: closed` after two seconds. |
| A datagram arrives from an address that is not the agent's | `ros_recv` drops it and answers nothing. |
| A sample is longer than one message and was asked for on the best-effort stream | Nothing arrives. The agent cannot cut a message on a best-effort stream, logs `serialization warning: Trying to serialize 1012 in 512 MTU stream` and sends nothing. Ask for the samples on the reliable stream and take them with `poll_long`. Observed. |
| A sample is longer than the reassembly allows | `poll_long` answers `ROS_RET_BAD_ALLOC` once, on the call that took the first piece, acknowledges and drops the rest of the pieces, and takes the next sample as usual. Observed with a text of 2,100 characters against the 2,040-byte limit. |
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

## A run over UDP, with long samples, 2026-11-19

Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy on one machine, novo 0.26.0, agent
verbose level 6, the node on `127.0.0.1`. The agent was started with its
libraries on `LD_LIBRARY_PATH`. The board was not involved. The programs were
built with `novo build examples/host_talker.nv` and `novo build
examples/host_listener.nv`. Every `ros2` command ran under `bash -c 'source
/opt/ros/jazzy/setup.bash && ...'`.

### (a) The talker over UDP

```
MicroXRCEAgent udp4 --port 2058 -v 6
ros2 topic echo /novo_counter std_msgs/msg/Int32
./host_talker 127.0.0.1 2058 best_effort udp
```

The program printed what it prints over TCP:

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

`ros2 topic echo` printed `data: 0` to `data: 9`, each followed by `---`. The
agent's log shows the datagrams it read, one message to each, with no length
in front: the CREATE_CLIENT is 24 bytes, and the session is established
for the address of the node's socket.

```
recv_message | [==>> UDP <<==] | client_key: 0x00000000, len: 24
0000: 80 00 00 00 00 01 10 00 58 52 43 45 01 00 01 0F AA BB CC DD 81 00 00 02
establish_session | session established | client_key: 0xAABBCCDD, address: 127.0.0.1:47836
send_message | [** <<UDP>> **] | client_key: 0xAABBCCDD, len: 19
0000: 81 00 00 00 04 01 0B 00 00 00 58 52 43 45 01 00 01 0F 00
create_datawriter | datawriter created | client_key: 0xAABBCCDD, datawriter_id: 0x001(5), publisher_id: 0x001(3)
recv_message | [==>> UDP <<==] | client_key: 0xAABBCCDD, len: 16
0000: 81 01 04 00 07 01 08 00 00 05 00 15 00 00 00 00
write | [** <<DDS>> **] | client_key: 0x00000001, len: 4
0000: 00 00 00 00
```

The STATUS_AGENT the agent sent back has zero bytes at offsets 1 to 3 and 7
to 9, and the node read it whole: a datagram of 19 bytes, which is what
`net.udp_recv_from` answers since novo 0.10.0 and what it did not before.

On the reliable stream, `./host_talker 127.0.0.1 2058 reliable udp` printed
`after a second: 0 unacknowledged` after each of its ten samples, so the
agent's ACKNACKs arrived as datagrams and were read. The agent's log has the
ten WRITE_DATA messages on stream `0x80`, sequence 0 to 9, each followed by
its ACKNACK, and each written to DDS. `ros2 topic echo` printed `data: 0` to
`data: 9`; see the last list of this section for the two runs on a freshly
started agent that printed `data: 2` first.

### (b) The listener over UDP

```
./host_listener 127.0.0.1 2058 best_effort 14 int32 udp
ros2 topic pub --once /novo_cmd std_msgs/msg/Int32 "{data: 7}"
```

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

### (c) A sample of a thousand characters

A `std_msgs/msg/String` of 1,000 characters (`0123456789abcdef` repeated) is
1,008 bytes of CDR: the length 1,001, the characters, the closing zero and
three bytes of padding. The listener asks for it on the reliable stream:

```
./host_listener 127.0.0.1 2058 reliable 14 string udp
ros2 topic pub --once -w 1 /novo_text std_msgs/msg/String "{data: '<1,000 characters>'}"
```

```
session: established
participant: code 0, agent status 0 (ok)
topic: code 0, agent status 0 (ok)
subscriber: code 0, agent status 0 (ok)
datareader: code 0, agent status 0 (ok)
request: code 0
sample 0: text of 1000 characters, 1008 bytes, begins "0123456789abcdef01234567", ends "0123456789abcdef01234567"
received 1 sample(s)
```

The same command with `tcp` and the TCP agent, started with `MicroXRCEAgent
tcp4 --port 2038 -v 6`, printed the same sample line.

The agent cut the DATA into three messages, each a FRAGMENT (submessage id 13,
`0D`) on stream `0x80`, and the node acknowledged each as it came. The
messages are 512, 512 and 16 bytes. The first carries the DATA's own header
(`09 01 F4 03`, length 1,012), the request and reader ids (`00 05 00 16`)
and the sample; the flags of the first two are `01`, and the last has bit 1
set:

```
recv  81 01 04 00 08 01 10 00 00 05 00 16 80 00 00 01 FF FF 00 00 00 00 00 00
send  81 80 00 00 0D 01 F8 01 09 01 F4 03 00 05 00 16 E9 03 00 00 30 31 32 33 34 35 36 37 38 39 61 62 ...  (512 bytes)
recv  81 00 00 00 0A 01 05 00 01 00 00 00 80
send  81 80 01 00 0D 01 F8 01 63 64 65 66 30 31 32 33 34 35 36 37 38 39 61 62 ...  (512 bytes)
recv  81 00 00 00 0A 01 05 00 02 00 00 00 80
send  81 80 02 00 0D 03 08 00 34 35 36 37 00 00 00 00                               (16 bytes)
recv  81 00 00 00 0A 01 05 00 03 00 00 00 80
```

The READ_DATA is the first line (stream `0x80`, `... 80 00 00 01 FF FF ...`).
Each piece is 504 bytes of the serialised DATA, and 504 + 504 + 8 is the 1,016
bytes of a 4-byte header, a 4-byte pair of ids and the 1,008-byte sample. The
last ACKNACK, first number not received 3, says every piece is in. The
hand-built pieces in `tests/rosfrag_tests.nv` reproduce these messages byte for
byte, and the last one is used as recorded.

### (d) A sample too long for the reassembly, then one that fits

The same listener, with the reassembly at its 2,040-byte limit, then
`ros2 topic pub` with a text of 2,100 characters and one of 700:

```
a sample longer than 2040 bytes was dropped
sample 0: text of 700 characters, 708 bytes, begins "0123456789abcdef01234567", ends "456789abcdef0123456789ab"
received 1 sample(s)
```

The long sample was dropped once, with the call that took its first piece
answering `ROS_RET_BAD_ALLOC`, its other pieces were acknowledged and
dropped, and the sample that followed it was joined from its own first piece.

### (e) A long sample on the best-effort stream

```
./host_listener 127.0.0.1 2058 best_effort 12 string udp
ros2 topic pub --once -w 1 /novo_text std_msgs/msg/String "{data: '<1,000 characters>'}"
```

The listener printed `received 0 sample(s)`. The agent's log has the reason:

```
push_submessage | serialization warning | Trying to serialize 1012 in 512 MTU stream
```

### (f) A long sample over a serial line, with the device code

`examples/uart_stdio_listener.nv` takes `string` as its third argument and
polls with `rosuart.poll_long`, the device function, over `ConsoleUart` and the
serial framing. The line was a pair of connected pseudoterminals, as in the
run of the subscription:

```
socat pty,raw,echo=0,link=ttyAGENT pty,raw,echo=0,link=ttyBOARD
MicroXRCEAgent serial --dev ttyAGENT -b 115200 -v 6
novo build examples/uart_stdio_listener.nv -o uart_stdio_listener
./uart_stdio_listener reliable 20 string <>ttyBOARD >&0 2> listener.out
ros2 topic pub --once -w 1 /novo_text std_msgs/msg/String "{data: '<1,000 characters>'}"
```

`listener.out` held:

```
sample 0: text of 1000 characters, 1008 bytes, first 48 last 55
received 1 sample(s), silence 480 ms
```

The first and last characters are 48 and 55, which are `0` and `7`, the
first and last of the text. The agent's log has the same three messages as
over UDP, 512, 512 and 16 bytes, on stream `0x80`, with `0D 01 F8 01`, `0D 01 F8 01` and
`0D 03 08 00` as their FRAGMENT headers. The buffers in this program are all
on its stack: the message, the frame, the de-framer, the history and the
2,056-byte reassembly buffer.

### What this run taught the package

- A FRAGMENT's payload is a slice of the whole submessage, header included.
  The first piece does not start with the sample: it starts with the DATA's
  own header, and the sample is eight bytes in. The agent's source says so
  (`ReliableOutputStream::push_submessage` serialises the header and then
  cuts), and the log above shows it: `09 01 F4 03` after the FRAGMENT's own
  header.
- The agent cuts at the MTU the node announced in its CREATE_CLIENT, 512, less
  the eight bytes of the message and submessage headers, so the node's
  announcement is also the limit on what it can be sent in one message.
- A best-effort stream cannot carry a sample longer than one message. This is
  the agent's, not the node's, and nothing on the node's side can say so.
- `ros2 topic echo` missed the first two samples in two runs of the reliable
  talker over UDP, each the first session of a freshly started agent, and
  printed `data: 2` first. The cause is not in this package: the reader did not
  exist yet, and the agent's writer keeps one sample for a reader that arrives
  late. The next section has the runs and the log lines.

## The first samples and a reader that is not there yet, 2026-11-20

Micro XRCE-DDS Agent 2.4.3 and ROS 2 Jazzy on one machine, novo 0.26.0, agent
verbose level 6, UDP on port 8888, a freshly started agent for every run and
`examples/host_talker.nv` as built for the runs above (reliable stream, ten
samples a second apart). The question was whether the first samples are lost
by the session or by DDS. The board was not involved.

Every run started `ros2 topic echo /novo_counter std_msgs/msg/Int32` and
counted the samples it printed before the first one it did not miss. The
machine was idle (load average 2) or loaded with 64 busy loops on its 32
cores. The samples the echo missed:

| Case | Machine | Runs | Runs with a miss | Samples missed |
| --- | --- | --- | --- | --- |
| echo started first, 0 s or 4 s before the talker | idle | 14 | 0 | 0 |
| echo started right after the talker's first sample | idle | 11 | 0 | 0 |
| echo started first, 0 s before the talker | loaded | 10 | 6 | 2, 2, 2, 2, 2, 3 (the other four: 0) |
| echo started right after the talker's first sample | loaded | 6 | 6 | 1 or 2 |

### What the agent's log shows about the session

In every run, with and without a miss, the order on the wire is the one the
session intends. The agent's log has the STATUS for the CREATE of the data
writer (`81 01 03 00 05 01 06 00 00 04 00 15 00 00`, result `00 00`, status
0) sent, and then, a second later, the WRITE_DATA on stream `0x80`
(`81 80 00 00 07 01 08 00 ...`, sequence 0), `write | [** <<DDS>> **] | len: 4`
with the four bytes of the number, and the ACKNACK (`... 0A 01 05 00 01 00 00
00 80`). A WRITE_DATA never reached the agent before the status of the data
writer, the stream's first sequence number was 0, and each sample was written
to DDS and acknowledged. The log is the same in a run that lost samples at the
echo and in a run that lost none.

### What the ROS 2 side does

The agent's writer, as `ros2 topic info -v /novo_counter` shows it, is
`RELIABLE` and `TRANSIENT_LOCAL`; the command reports its history depth as
`UNKNOWN`, and the replay below behaves as a depth of one. Two facts follow,
each seen in a run:

- A reader that matches after a sample was written receives only the newest
  sample the writer holds. Started 2.5 s after the first sample with
  `--qos-reliability reliable --qos-durability transient_local`, the echo
  printed `data: 3` first, with samples 0 to 2 gone; with
  `--qos-history keep_all --qos-depth 50` and 3.5 s it printed `data: 4`
  first. Samples 0 to 3 had been written and the writer held only the newest
  when the reader arrived. With `--qos-durability volatile` it
  printed the sample written after it matched, `data: 4`, and nothing before.
- `ros2 topic echo` chooses its own QoS when it creates the subscription, from
  the publishers it can see at that moment (`ros2topic/verb/echo.py`,
  `choose_qos`). With none it takes volatile; with the agent's writer it takes
  transient local. Which of the two it took is the race of the command line
  with the writer, and the command prints neither.

A subscription is ready after the command has started Python, loaded the
message package and discovered the agent's participant. On the idle machine
that took less than a second after the writer existed: with the talker
writing every 100 ms from the moment the writer was created, five fresh
agents delivered the first sample 0.202 s later (`data: 2`) every time. The
talker's second before its first sample covers that. On the loaded machine the
same start took 3.8 s in two runs measured (from the command's start to its
first sample), and the echo printed `data: 2`, delivered 0.77 s after the agent
wrote it, which is the replay of the one retained sample at the match. The
talker had written samples 0 and 1 to a writer with no reader, and the writer
held only the newest sample when the reader arrived.

### What the package can and cannot know

The agent does not report that a reader has matched. Its log at level 6 has
no line for it, and the agent's default middleware (`-m dds`, Fast DDS) creates
the data writer with no listener (`FastDDSDataWriter::create_by_xml` in
`middleware/fastdds/FastDDSEntities.cpp`), so there is no callback that could
tell it. Only the Fast RTPS middleware (`-m rtps`, `middleware/fast`) has an
`onPublicationMatched`, and it writes a trace line in the agent's log, not a
message to the client. This run did not use it. `STATUS_OK_MATCHED` (0x01)
is the answer to a CREATE that found an entity with the same description
already there, and says nothing about readers. The `GET_INFO` answer for a data
writer (`DATAWRITER_ActivityInfo`) carries a stream sequence number and a
sample sequence number and no count of readers, and nothing under the agent's
`src/cpp` builds an activity info. The XRCE-DDS 1.0 text is not on this machine;
the types above are the agent's own, generated from the specification's IDL.

So the protocol gives a node no way to ask whether a reader is there. What a
node can do is wait an interval it chose, which is what the examples do and
which a loaded machine overruns, or write its first sample again in a later
cycle. The package does neither for the caller. Sizing the writer's history
through the XML of `XRCE_KIND_DATAWRITER` was not tried.

## A node on the nRF52840-DK, 2026-11-20

`examples/dk_sensor_node.nv` on an nRF52840-DK (J-Link 683644473, its
virtual COM port `/dev/serial/by-id/usb-SEGGER_J-Link_000683644473-if00`,
UARTE0 on P0.06 and P0.08, 115200 baud, hardware flow control on), against
a Micro XRCE-DDS Agent 2.4.3 in serial mode and ROS 2 Jazzy on the PC, novo
0.26.0, probe-rs for the flash. The node publishes the chip's die
temperature on `/dk/temperature` as a `std_msgs/msg/Int32` in hundredths of
a degree Celsius once a second, and takes `/dk/led` as a `std_msgs/msg/Int32`
from 0 to 4: 0 switches the four LEDs off, 1 to 4 switch that LED on and the
others off, and any other number changes nothing. The temperature is read
from the TEMP peripheral with `hw.mem_read32` and `hw.mem_write32`, because
the board's HAL has no binding for it.

The commands, from the package's directory:

```
novo build --target=nrf52840-dk --hci-uart=physical examples/dk_sensor_node.nv
probe-rs download --chip nRF52840_xxAA --probe 1366:1024:000683644473 dk_sensor_node.elf
probe-rs reset --chip nRF52840_xxAA --probe 1366:1024:000683644473
MicroXRCEAgent serial --dev /dev/serial/by-id/usb-SEGGER_J-Link_000683644473-if00 -b 115200 -v 6
source /opt/ros/jazzy/setup.bash
ros2 topic echo /dk/temperature std_msgs/msg/Int32
ros2 topic pub --once /dk/led std_msgs/msg/Int32 "{data: 2}"
```

The agent was run from a build in the home directory with its libraries on
`LD_LIBRARY_PATH`. `--hci-uart=physical` is the flag the build needs; without it the console is
RTT and the agent hears nothing. The image is 24,712 bytes of flash, of which
the program is 15,778, and 2,712 bytes of static RAM. The J-Link's
mass-storage component on this board is off (`MSDDisable`), which a J-Link
needs for serial writes longer than 64 bytes to pass.

### The echo

The node had run for eight seconds with no agent when the agent was started,
and `ros2 topic echo` was started six seconds after that. It ran for 75
seconds under `timeout`, and a shell loop put the time of arrival in front
of each line. 76 samples arrived:

```
06:51:42.014 data: 2350
06:51:42.253 data: 2350
06:51:43.180 data: 2350
06:51:44.188 data: 2375
06:51:45.188 data: 2400
...
06:52:54.585 data: 2400
06:52:55.511 data: 2400
```

The first sample is the one the agent's writer retained for a late reader
(see the section on the first samples above); from the second on, the gap
between two samples was at least 0.926 s and at most 1.009 s, so no sample
was missing. The values were 23.25 C once, 23.50 C 15 times, 23.75 C 21
times, 24.00 C 34 times and 24.25 C five times. The TEMP peripheral's step is
0.25 C, so no other value can appear.

### The LEDs

The LEDs are P0.13 to P0.16, active low, and the board has no way to show
them to the PC, so the output register of GPIO P0 was read back through
probe-rs after each command, `probe-rs read b32 --chip nRF52840_xxAA
--probe 1366:1024:000683644473 0x50000504 1`. A cleared bit is a lit LED.
Each command was sent with `ros2 topic pub --once /dk/led std_msgs/msg/Int32
"{data: N}"` and the register read a second later:

| Before | Command | Register | Bits 13 to 16 | LEDs lit |
| --- | --- | --- | --- | --- |
| all off | `data: 2` | `0x0001a000` | 1 0 1 1 (bit 14 clear) | LED2 |
| all off | `data: 1` | `0x0001c000` | 0 1 1 1 (bit 13 clear) | LED1 |
| LED2 | `data: 4` | `0x0000e000` | 1 1 1 0 (bit 16 clear) | LED4 |
| LED4 | `data: 7` | `0x0000e000` | 1 1 1 0 | LED4, unchanged |
| LED4 | `data: 3` | `0x00016000` | 1 1 0 1 (bit 15 clear) | LED3 |
| LED3 | `data: 0` | `0x0001e000` | 1 1 1 1 | none |

The row for `data: 1` is from a second run. In the first run the `ros2
topic pub --once` that sent it was not seen by the agent (the agent's log
has five reads of the data reader for six commands), and the register stayed
at the value of the command before. It was sent again with `-w 1`, which
waits for the matching subscription, and LED1 lit. No frame for the first
command reached the agent, so the node was not asked.

### What the first runs taught the package

The first runs were not clean, and the cause was in the package.

With the node running and the agent started afterwards, the agent's log had
a `session re-established` for every second and the entities were created,
and then created again four seconds later, over and over. The node was
running the example's bring-up, which creates seven entities and answers a
closed session when one of them did not get its status. Counters kept in
RAM during a run and read back with probe-rs showed that `receive` returned
a whole frame every time, none late and none damaged, and that the status
`create` read was the one for a request three places earlier: the node
asked for request 4 and read the status of request 1. The three extra
answers were the agent's replies to the open requests the node had sent
while the agent was not there: the port held them, and the agent sent a
STATUS_AGENT for each when it opened the port. `open` and `create` took the
first frame they saw, so the answers they read stayed three behind for as
long as the node ran.

`rosuart.open` and `rosuart.create` now read past a frame that is not the
answer, up to `ROS_UART_STALE_FRAMES`, 8. With that, the same arrangement
(node started eight seconds before the agent) created the participant, both
topics, the publisher, the writer, the subscriber and the reader in 111
milliseconds, from the first frame the agent saw to the last status, with no second attempt,
and the 76 samples above followed.

The receiver was suspected first, because the nRF52 UARTE has a six-byte
FIFO and `receive` pauses a millisecond between polls, which is 11 bytes at
115200 baud. The counters did not show it: no call of `receive` ended with
a damaged frame, and the UARTE's `ERRORSRC` register, which holds the
overrun, read 0. The package's `receive` is unchanged.

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
