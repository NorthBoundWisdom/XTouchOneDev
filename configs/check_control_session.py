#!/usr/bin/env python3
"""Exercise the JSON CLI without attaching to any MIDI endpoint."""

import argparse
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MONITOR = ROOT / "build/swiftpm/debug/xtouch-one-monitor"


def run_requests(options, requests):
    incoming = "\n".join(json.dumps(request) if isinstance(request, dict) else request for request in requests)
    result = subprocess.run([MONITOR, "session", *options], input=incoming, text=True, capture_output=True, timeout=10, check=True)
    if result.stderr:
        raise AssertionError(result.stderr)
    return [json.loads(line) for line in result.stdout.splitlines()]


def simulated_session():
    replies = run_requests(
        ["--source", "simulation", "--mode", "CChgRel", "--channel", "2"],
        [
            {"id": "start", "op": "status"},
            {"id": "unknown", "op": "recall", "args": ["64"]},
            {"id": "button", "op": "act", "args": ["button", "23", "true"]},
            {"id": "foot", "op": "act", "args": ["foot", "true"]},
            {"id": "touch", "op": "act", "args": ["touch", "true"]},
            {"id": "touched", "op": "recall", "args": ["64"]},
            {"id": "fader", "op": "act", "args": ["fader", "72"]},
            {"id": "release", "op": "act", "args": ["touch", "false"]},
            {"id": "recall", "op": "recall", "args": ["64"]},
            {"id": "display", "op": "display", "args": ["led", "23", "on"]},
            {"id": "same", "op": "display", "args": ["led", "23", "on"]},
            {"id": "invalid", "op": "display", "args": ["segments", "000000000000000000000000", "00", "20"]},
            "x" * 8193,
            "bad JSON",
            {"id": "events", "op": "events", "after": 0},
            {"id": "end", "op": "status"},
        ],
    )
    assert len(replies) == 16, replies
    indexed = {reply["id"]: reply for reply in replies if "id" in reply}
    assert indexed["start"]["result"]["source"] == "simulation", indexed["start"]
    assert indexed["unknown"]["error"] == {"code": "recallRefused", "message": "contactUnknown"}
    assert indexed["touched"]["error"] == {"code": "recallRefused", "message": "touched"}
    assert indexed["recall"]["ok"], indexed["recall"]
    assert indexed["display"]["result"]["state"] == "queued" and indexed["same"]["result"]["state"] == "alreadyAccepted"
    assert indexed["invalid"]["error"]["code"] == "invalidArguments", indexed["invalid"]
    assert all(r["error"]["code"] == "invalidRequest" for r in replies if "id" not in r)
    events = indexed["events"]["result"]["entries"]
    assert [e["bytes"] for e in events if e["kind"] == "input"] == [
        [0xB1, 23, 127], [0xB1, 64, 127], [0x91, 110, 127], [0xB1, 70, 72], [0x91, 110, 0],
    ], events
    assert [e["bytes"] for e in events if e.get("outcome") == "accepted"] == [[0xB1, 70, 64], [0xB1, 23, 127]], events
    assert indexed["end"]["result"]["faderPosition"] == 64, indexed["end"]


def hardware_session_without_endpoints():
    listed = json.loads(subprocess.check_output([MONITOR, "list", "--json"], text=True, timeout=10))
    used = {source["uniqueID"] for source in listed["sources"]}
    missing_id = next(i for i in range(-2**31, -2**31 + len(used) + 1) if i not in used)
    replies = run_requests(
        ["--source", "hardware", "--mode", "MidiRel", "--channel", "1", "--input", str(missing_id)],
        [
            {"id": "status", "op": "status"},
            {"id": "act", "op": "act", "args": ["button", "23", "true"]},
            {"id": "recall", "op": "recall", "args": ["64"]},
            {"id": "display", "op": "display", "args": ["led", "23", "on"]},
            {"id": "events", "op": "events"},
            {"id": "quit", "op": "quit"},
        ],
    )
    state, act, recall, display, events, quit_reply = replies
    assert state["result"]["source"] == "hardware" and not state["result"]["connected"], state
    assert not state["result"]["displayWrite"] and "faderPosition" not in state["result"], state
    assert act["error"]["code"] == recall["error"]["code"] == "simulationOnly", replies
    assert display["error"]["code"] == "displayUnavailable", display
    assert events["result"]["entries"] == [] and quit_reply["ok"], replies


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coremidi", action="store_true", help="Also test the hardware command guards without binding an endpoint.")
    arguments = parser.parse_args()
    simulated_session()
    if arguments.coremidi:
        hardware_session_without_endpoints()
    print("Control session JSON checks passed.")
