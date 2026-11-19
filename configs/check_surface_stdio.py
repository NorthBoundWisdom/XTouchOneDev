#!/usr/bin/env python3
"""Run the published MCP entry point in an isolated subprocess."""
import argparse
import json
import select
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT / "build/swiftpm/debug/xtouch-one-surface"


def check(options, allow_write, hardware=False):
    with subprocess.Popen([BINARY, *options], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True) as server:
        sequence = 0

        def send(method, params, *, notification=False):
            nonlocal sequence
            request = {"jsonrpc": "2.0", "method": method, "params": params}
            if not notification:
                sequence += 1
                request["id"] = sequence
            server.stdin.write(json.dumps(request) + "\n")
            server.stdin.flush()
            if notification:
                return None
            if not select.select([server.stdout], [], [], 5)[0]:
                server.kill()
                raise RuntimeError(f"No response to {method}")
            answer = json.loads(server.stdout.readline())
            assert answer["id"] == sequence and "error" not in answer, answer
            return answer["result"]

        def call(name, arguments):
            return send("tools/call", {"name": name, "arguments": arguments})

        try:
            protocol = send("initialize", {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "xtouch-one-check", "version": "1"},
            })
            assert protocol["protocolVersion"] == "2025-11-25", protocol
            send("notifications/initialized", {}, notification=True)
            tools = {tool["name"] for tool in send("tools/list", {})["tools"]}
            assert "surface_control_input" in tools, tools
            if not hardware:
                assert "surface_capabilities" in tools, tools
                modules = call("surface_capabilities", {})["structuredContent"]["instances"]
                assert any(module["manifest"]["source"] == "simulation" for module in modules), modules
            discovery = call("surface_control_discover", {})["structuredContent"]
            assert discovery["source"] == ("hardware" if hardware else "simulation"), discovery
            identity = discovery["expected"]
            if hardware:
                snapshot = call("surface_control_snapshot", {"instance_id": identity["instance_id"]})["structuredContent"]
                assert snapshot["link"]["state"] == "disconnected", snapshot
            request = {"expected": identity, "expected_input_sequence": "0", "control_id": "encoder.turn",
                       "encoding": "scalar", "value": 58}
            changed = call("surface_control_input", request)
            if allow_write:
                event = changed["structuredContent"]
                assert event["mapped_value"] == 58 and event["writer_id"] == "simulation.stdio", event
                stale = call("surface_control_input", request)
                assert stale["isError"], stale
                motors = call("surface_control_feedback", {
                    "expected": identity, "control_id": "fader", "kind": "value", "value": 127,
                })
                assert motors["isError"], motors
                reset = call("surface_control_reset", {"expected": identity, "expected_sequence": "1"})
                assert reset["isError"], reset
            else:
                assert changed["isError"], changed
                assert json.loads(changed["content"][0]["text"])["code"] == "permission_denied", changed
        except BaseException:
            server.kill()
            raise
        finally:
            server.stdin.close()
        assert server.wait(timeout=5) == 0, server.stderr.read()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coremidi", action="store_true", help="Also exercise a hardware service with an absent source ID.")
    arguments = parser.parse_args()
    check(["--robot-sim"], allow_write=False)
    check(["--write", "--chassis-sim"], allow_write=True)
    if arguments.coremidi:
        monitor = BINARY.with_name("xtouch-one-monitor")
        endpoints = json.loads(subprocess.check_output([monitor, "list", "--json"], text=True, timeout=8))
        occupied = {source["uniqueID"] for source in endpoints["sources"]}
        absent = next(identifier for identifier in range(-2**31, -2**31 + len(occupied) + 1) if identifier not in occupied)
        check(["--hardware-input", str(absent)], allow_write=False, hardware=True)
    print("Surface MCP stdio checks passed.")
