#!/usr/bin/env bash
# tests/interop/build_agent.sh -- build eProsima's Micro XRCE-DDS Agent from source.
#
# The agent is in neither Ubuntu's nor the ROS 2 apt repository for Jazzy, so
# the interop workflow builds it with this script and caches the result. The
# superbuild fetches Fast CDR, Fast DDS and spdlog at the versions the agent's
# release pins, and installs everything under one prefix:
#
#   bash tests/interop/build_agent.sh <prefix> [version]
#
# leaves <prefix>/bin/MicroXRCEAgent and <prefix>/lib/*.so. The version is a
# tag of https://github.com/eProsima/Micro-XRCE-DDS-Agent, v2.4.3 by default,
# the release the run pages in docs/agent-run.md were made with.
#
# It needs a C++ compiler, cmake, git and libtinyxml2-dev, and builds with
# the machine's ROS 2 environment not sourced: Fast DDS would otherwise find
# ROS 2's own copy before the one the superbuild builds.

set -eu

prefix=${1:?usage: build_agent.sh <prefix> [version]}
version=${2:-v2.4.3}
jobs=${JOBS:-$(nproc)}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone --quiet --depth 1 --branch "$version" \
    https://github.com/eProsima/Micro-XRCE-DDS-Agent.git "$work/src"

cmake -S "$work/src" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$prefix" \
    -DUAGENT_SUPERBUILD=ON \
    -DUAGENT_BUILD_EXECUTABLE=ON \
    -DUAGENT_BUILD_TESTS=OFF \
    -DUAGENT_SECURITY_PROFILE=OFF

cmake --build "$work/build" --parallel "$jobs"
cmake --install "$work/build"

test -x "$prefix/bin/MicroXRCEAgent"
echo "agent: $prefix/bin/MicroXRCEAgent ($version)"
