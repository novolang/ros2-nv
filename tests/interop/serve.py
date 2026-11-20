#!/usr/bin/env python3
"""tests/interop/serve.py -- an rclpy AddTwoInts server that logs its requests.

    python3 -I tests/interop/serve.py --service /add_two_ints \
        --out requests.txt --ready ready --timeout 120

Serves example_interfaces/srv/AddTwoInts: the reply's sum is a + b. The file
named by --ready is created once the service exists, and --out gets one line,
"a b", for every request served. The server exits after --timeout seconds or
when it is stopped.

Run it after sourcing the ROS 2 setup file, with example_interfaces on the
path. `-I` ignores PYTHONPATH, so the script adds the entries of PYTHONPATH
itself.
"""
import argparse
import os
import sys
import time

sys.path[:0] = [p for p in os.environ.get("PYTHONPATH", "").split(":") if p]

import rclpy  # noqa: E402
from example_interfaces.srv import AddTwoInts  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--service", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--timeout", type=float, required=True)
    args = ap.parse_args()

    rclpy.init()
    node = rclpy.create_node("interop_server")
    out = open(args.out, "w", buffering=1)

    def on_request(request, response):
        out.write("%d %d\n" % (request.a, request.b))
        response.sum = request.a + request.b
        return response

    node.create_service(AddTwoInts, args.service, on_request)
    open(args.ready, "w").close()

    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
    out.close()
    node.destroy_node()
    rclpy.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
