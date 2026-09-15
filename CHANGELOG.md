# Changelog

All notable changes to ros2-nv are recorded here. The format is
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
package follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
with the pre-1.0 rule that a breaking change bumps the MINOR number.

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
