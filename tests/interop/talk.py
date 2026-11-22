#!/usr/bin/env python3
"""tests/interop/talk.py -- an rclpy publisher that writes what it sent to a file.

    python3 -I tests/interop/talk.py --topic /novo_cmd --type int32 --start 100 \
        --out sent.txt --ready ready --period 0.2 --timeout 60
    python3 -I tests/interop/talk.py --topic /novo_text --type string --text "..." \
        --out sent.txt --ready ready --period 0.5 --timeout 60

Creates a node and a publisher with the default QoS (reliable, volatile,
depth 10) and creates the file named by --ready once the publisher exists.
It then publishes every --period seconds until --timeout passes or it is
stopped: the integers --start, --start + 1 and so on, or --text every time.
With --big-endian each integer is published as the serialised bytes of a
big-endian CDR message (header 00 00 00 00, the number most significant byte
first) in place of the message the middleware serialises, which is how a
publisher on a big-endian processor sends it. Each message is appended to --out before it is published, so the file holds at
least what any subscriber can have heard.

A message published before a subscription has matched is lost, so a caller
compares what a listener heard with this file and does not expect all of it.

Run it after sourcing the ROS 2 setup file. `-I` ignores PYTHONPATH, so the
script adds the entries of PYTHONPATH itself.
"""
import argparse
import os
import sys
import time

sys.path[:0] = [p for p in os.environ.get("PYTHONPATH", "").split(":") if p]

import rclpy  # noqa: E402
from std_msgs.msg import Int32, String  # noqa: E402

TYPES = {"int32": Int32, "string": String}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--topic", required=True)
    ap.add_argument("--type", choices=sorted(TYPES), required=True)
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--text", default="")
    ap.add_argument("--out", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--period", type=float, default=0.2)
    ap.add_argument("--timeout", type=float, required=True)
    ap.add_argument("--big-endian", action="store_true")
    args = ap.parse_args()

    rclpy.init()
    node = rclpy.create_node("interop_talker")
    pub = node.create_publisher(TYPES[args.type], args.topic, 10)
    out = open(args.out, "w", buffering=1)
    open(args.ready, "w").close()

    n = args.start
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        msg = TYPES[args.type]()
        if args.type == "int32":
            msg.data = n
            n += 1
        else:
            msg.data = args.text
        out.write("%s\n" % msg.data)
        if args.big_endian and args.type == "int32":
            pub.publish(bytes([0, 0, 0, 0]) + (msg.data & 0xFFFFFFFF).to_bytes(4, "big"))
        else:
            pub.publish(msg)
        rclpy.spin_once(node, timeout_sec=args.period)
    out.close()
    node.destroy_node()
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
