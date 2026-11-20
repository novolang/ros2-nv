#!/usr/bin/env python3
"""tests/interop/listen.py -- an rclpy subscription that writes what it hears to a file.

    python3 -I tests/interop/listen.py --topic /novo_counter --type int32 \
        --out heard.txt --ready ready --count 10 --timeout 60

Creates a node and a subscription with the default QoS (reliable, volatile,
depth 10), creates the file named by --ready once the subscription exists, and
appends one line to --out for every message: the integer, or the string. It
exits 0 after --count messages and 1 when --timeout seconds pass first.

The file named by --ready is what a caller waits for before it starts the
publisher on the other side, so no message is sent into a graph that has no
subscription yet.

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
    ap.add_argument("--out", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--timeout", type=float, required=True)
    args = ap.parse_args()

    rclpy.init()
    node = rclpy.create_node("interop_listener")
    heard = []
    out = open(args.out, "w", buffering=1)

    def on_message(msg):
        heard.append(msg.data)
        out.write("%s\n" % msg.data)

    node.create_subscription(TYPES[args.type], args.topic, on_message, 10)
    open(args.ready, "w").close()

    deadline = time.monotonic() + args.timeout
    while len(heard) < args.count and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
    out.close()
    node.destroy_node()
    rclpy.shutdown()
    return 0 if len(heard) >= args.count else 1


if __name__ == "__main__":
    sys.exit(main())
