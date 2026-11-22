#!/usr/bin/env python3
"""tests/interop/serve_long.py -- an rclpy GetParameters server that counts a name.

    python3 -I tests/interop/serve_long.py --service /long_request \
        --out names.txt --ready ready --timeout 120

Serves rcl_interfaces/srv/GetParameters. The reply holds one integer
parameter value, the number of characters in the first name of the request,
and --out gets one line for every request served: the length and the first
and last 24 characters of the first name. The file named by --ready is
created once the service exists. The server exits after --timeout seconds or
when it is stopped.

Run it after sourcing the ROS 2 setup file. `-I` ignores PYTHONPATH, so the
script adds the entries of PYTHONPATH itself.
"""
import argparse
import os
import sys
import time

sys.path[:0] = [p for p in os.environ.get("PYTHONPATH", "").split(":") if p]

import rclpy  # noqa: E402
from rcl_interfaces.msg import ParameterType, ParameterValue  # noqa: E402
from rcl_interfaces.srv import GetParameters  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--service", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ready", required=True)
    ap.add_argument("--timeout", type=float, required=True)
    args = ap.parse_args()

    rclpy.init()
    node = rclpy.create_node("interop_long_server")
    out = open(args.out, "w", buffering=1)

    def on_request(request, response):
        name = request.names[0] if request.names else ""
        out.write("%d %s %s\n" % (len(name), name[:24], name[-24:]))
        value = ParameterValue()
        value.type = ParameterType.PARAMETER_INTEGER
        value.integer_value = len(name)
        response.values = [value]
        return response

    node.create_service(GetParameters, args.service, on_request)
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
