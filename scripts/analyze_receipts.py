#!/usr/bin/env python3
"""Analyze fixed-fixture cross-process callback evidence; never labels it visible latency."""
import hashlib
import json
import math
import argparse
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", nargs="?")
parser.add_argument("--m1", action="store_true")
parser.add_argument("--triples", type=int, default=1)
args = parser.parse_args()
if args.triples < 1:
    parser.error("--triples must be positive")
directory = Path(args.directory).expanduser() if args.directory else Path.home() / "Library/Logs" / ("ClipFlow" if args.m1 else "ClipFlowM0")
probe = json.loads((directory / ("diagnostics.json" if args.m1 else "probe.json")).read_text())
target_directory = Path.home() / "Library/Logs/ClipFlowM0" if args.m1 else directory
target = json.loads((target_directory / "target-events.json").read_text())
requests = probe.get("events", [])
receipts = [event for event in target.get("events", []) if event["kind"] == "insertText.completed"]
used = set()
latencies = []
matched_slots = []
for request in requests:
    if request.get("state") != "posted-unconfirmed" or request.get("slot") not in (1, 2, 3):
        continue
    expected = hashlib.sha256({1: b"C", 2: b"B", 3: b"A"}[request["slot"]]).hexdigest()
    for index, receipt in enumerate(receipts):
        if index in used or receipt.get("targetPID") != request.get("targetPID"):
            continue
        timestamp = request.get("hotkeyReceivedAtNs", request.get("receivedAtNs"))
        if timestamp is None:
            continue
        delta = receipt["timestampNs"] - timestamp
        if 0 <= delta <= 5_000_000_000 and receipt.get("incomingSHA256") == expected:
            used.add(index)
            latencies.append(delta / 1_000_000)
            matched_slots.append(request["slot"])
            break

def percentile(values, percent):
    return sorted(values)[max(0, math.ceil(len(values) * percent) - 1)] if values else None

print(json.dumps({
    "measurement": "hotkey callback to independent AppKit insertText callback, with diagnostic logging",
    "screen_visible_latency_measured": False,
    "hotkey_callbacks": len(requests),
    "matched_fixture_receipts": len(latencies),
    "matched_slots": matched_slots,
    "callback_latency_ms_p50": percentile(latencies, 0.50),
    "callback_latency_ms_p95": percentile(latencies, 0.95),
    "target_exactly_CBA": target.get("isCBA"),
    "requested_triples": args.triples,
    "requested_fixture_and_order_match": target.get("contentSHA256") == hashlib.sha256(b"CBA" * args.triples).hexdigest()
        and matched_slots == [1, 2, 3] * args.triples,
    "physical_option_hold_verified": False,
    "triple_success_rate": None,
    "note": "A CBA match is one receiver state, not a 30-trial success rate or universal compatibility result."
}, ensure_ascii=False, indent=2))
