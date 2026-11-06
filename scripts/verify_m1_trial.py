#!/usr/bin/env python3
"""Correlate M1 fixture trials without reading clipboard payloads or operating the UI.

Before baseline, clear the Target input and prepare the history fixture. Keep that
Target session open throughout the trial. Examples:
  python3 scripts/verify_m1_trial.py baseline triple30
  python3 scripts/verify_m1_trial.py verify triple30 --slots 1,2,3 --expected CBA --repeat 30
  python3 scripts/verify_m1_trial.py baseline triple30 --import-existing

The import option uses the already frozen <tag>-before-{diagnostics,target,store}.json
files in output/m1, so a trial already in progress is never silently re-baselined.
--expected is one Unicode code point per slot. For multi-character slot values use
--expected-parts-json '["hello","中文","🙂"]'; each value must fit one <=20-UTF16
insertion. This strict verifier does not infer payloads from history manifests.

A pass means complete matching log evidence and unchanged SQLite metadata. It does
not prove a physical Option hold, a visible frame latency, or other-app compatibility.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[1]
OUTPUT = PROJECT / "output" / "m1"
SENDER_PATH = Path.home() / "Library/Logs/ClipFlow/diagnostics.json"
TARGET_PATH = Path.home() / "Library/Logs/ClipFlowM0/target-events.json"
DATABASE_PATH = Path.home() / "Library/Application Support/ClipFlow/history.sqlite3"
EMPTY_SHA = hashlib.sha256(b"").hexdigest()
SENDER_RETENTION = 100


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def sha_bytes(value):
    return hashlib.sha256(value).hexdigest()


def canonical_sha(value):
    return sha_bytes(json.dumps(value, ensure_ascii=False, sort_keys=True,
                               separators=(",", ":"), allow_nan=False).encode("utf-8"))


def utf16_length(value):
    return len(value.encode("utf-16-le")) // 2


def read_json(path):
    raw = path.read_bytes()
    return json.loads(raw), raw


def atomic_bytes(path, value):
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=OUTPUT, prefix=".clipflow-trial-", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(value)
        stream.flush()
        os.fchmod(stream.fileno(), 0o600)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_json(path, value):
    atomic_bytes(path, (json.dumps(value, ensure_ascii=False, sort_keys=True,
                                  indent=2, allow_nan=False) + "\n").encode("utf-8"))


def metadata_rows():
    # mode=ro includes committed WAL data; immutable=1 would incorrectly skip it.
    connection = sqlite3.connect(DATABASE_PATH.as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        rows = connection.execute(
            "SELECT id,fingerprint,copied_at,sort_index FROM history ORDER BY sort_index DESC,id ASC"
        ).fetchall()
        return [list(row) for row in rows]
    finally:
        connection.close()


def validate_rows(rows):
    if not isinstance(rows, list) or any(not isinstance(row, list) or len(row) != 4 for row in rows):
        raise ValueError("store metadata must be rows of [id,fingerprint,copied_at,sort_index]")
    for record_id, fingerprint, copied_at, sort_index in rows:
        if not isinstance(record_id, str) or not isinstance(fingerprint, str):
            raise ValueError("invalid history metadata identifiers")
        if not isinstance(copied_at, (float, int)) or not math.isfinite(copied_at):
            raise ValueError("invalid copied_at metadata")
        if not isinstance(sort_index, int):
            raise ValueError("invalid sort_index metadata")
    return rows


def received_at(event):
    value = event.get("receivedAtNs", event.get("hotkeyReceivedAtNs"))
    if not isinstance(value, int) or value < 0:
        raise ValueError("sender event lacks an integer receivedAtNs")
    return value


def sender_events(report):
    events = report.get("events")
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise ValueError("sender events are missing or malformed")
    times = [received_at(event) for event in events]
    if any(later <= earlier for earlier, later in zip(times, times[1:])):
        raise ValueError("sender receivedAtNs are not strictly increasing")
    return events


def target_events(report):
    events = report.get("events")
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise ValueError("target events are missing or malformed")
    times = [event.get("timestampNs") for event in events]
    if any(not isinstance(value, int) or value < 0 for value in times):
        raise ValueError("target event lacks an integer timestampNs")
    if any(later <= earlier for earlier, later in zip(times, times[1:])):
        raise ValueError("target timestamps are not strictly increasing")
    return events


def artifact_info(path, raw):
    return {"path": str(path), "sha256": sha_bytes(raw), "bytes": len(raw)}


def freeze(raw, path):
    if path.exists():
        raise ValueError("refusing to overwrite evidence: " + str(path))
    atomic_bytes(path, raw)
    return artifact_info(path, raw)


def baseline(args):
    destination = OUTPUT / (args.tag + "-baseline.json")
    if destination.exists():
        raise ValueError("baseline already exists; use a new tag instead of overwriting it")
    if args.import_existing:
        sender, sender_raw = read_json(OUTPUT / (args.tag + "-before-diagnostics.json"))
        target, target_raw = read_json(OUTPUT / (args.tag + "-before-target.json"))
        rows, _ = read_json(OUTPUT / (args.tag + "-before-store.json"))
        origin = "imported frozen pre-trial files; no live baseline read"
    else:
        sender, sender_raw = read_json(SENDER_PATH)
        target, target_raw = read_json(TARGET_PATH)
        rows = metadata_rows()
        origin = "live pre-trial capture"
    validate_rows(rows)
    if sender.get("stage") != "M1-text-only":
        raise ValueError("baseline sender is not the production M1 stage")
    sent = sender_events(sender)
    received = target_events(target)
    if not target.get("session") or not isinstance(target.get("targetPID"), int):
        raise ValueError("target session/PID is missing")
    if target.get("contentUTF16Length") != 0 or target.get("contentSHA256") != EMPTY_SHA:
        raise ValueError("Target must be cleared before baseline; do not clear it after baseline")
    sources = {
        "sender": freeze(sender_raw, OUTPUT / (args.tag + "-baseline-sender.json")),
        "target": freeze(target_raw, OUTPUT / (args.tag + "-baseline-target.json")),
    }
    result = {
        "schema_version": 1, "kind": "M1-trial-baseline", "tag": args.tag,
        "captured_at_utc": utc_now(), "origin": origin,
        "sender_stage": sender.get("stage"), "sender_event_count": len(sent),
        "sender_last_received_at_ns": received_at(sent[-1]) if sent else 0,
        "sender_last_event_sha256": canonical_sha(sent[-1]) if sent else None,
        "sender_saved_copies_this_run": sender.get("savedCopiesThisRun"),
        "target_session": target["session"], "target_pid": target["targetPID"],
        "target_event_count": len(received),
        "target_last_event_ns": received[-1]["timestampNs"] if received else 0,
        "target_event_prefix_sha256": canonical_sha(received),
        "target_initially_empty": True,
        "history_metadata_columns": ["id", "fingerprint", "copied_at", "sort_index"],
        "history_metadata_rows": rows, "history_metadata_sha256": canonical_sha(rows),
        "database": str(DATABASE_PATH), "sources": sources,
        "note": "Do not restart/reset Target or copy new content before verification.",
    }
    write_json(destination, result)
    print(json.dumps({"status": "baseline-saved", "artifact": str(destination),
                      "sender_cursor_ns": result["sender_last_received_at_ns"],
                      "target_session": result["target_session"],
                      "history_records": len(rows)}, ensure_ascii=False, indent=2))
    return 0


def percentile(values, quantile):
    return sorted(values)[max(0, math.ceil(len(values) * quantile) - 1)] if values else None


def evaluate(before, sender, target, rows, slots, parts, repeats):
    errors, pending = [], []
    sent = sender_events(sender)
    received = target_events(target)
    expected_slots = slots * repeats
    expected_parts = parts * repeats
    expected_text = "".join(expected_parts)
    if sender.get("stage") != "M1-text-only":
        errors.append("sender stage changed or is not M1")
    if target.get("session") != before["target_session"] or target.get("targetPID") != before["target_pid"]:
        errors.append("Target was reset/restarted or its session/PID changed after baseline")
    prefix_count = before["target_event_count"]
    if canonical_sha(received[:prefix_count]) != before["target_event_prefix_sha256"]:
        errors.append("Target baseline event prefix was removed or changed")
    baseline_ns = before["sender_last_received_at_ns"]
    if baseline_ns:
        anchors = [event for event in sent if received_at(event) == baseline_ns]
        if not anchors or canonical_sha(anchors[0]) != before["sender_last_event_sha256"]:
            errors.append("sender baseline anchor is missing: restart or 100-event retention overflow; cannot pass")
    elif len(sent) >= SENDER_RETENTION:
        errors.append("sender buffer is full without an anchor; possible event truncation cannot be ruled out")
    new_sender = [event for event in sent if received_at(event) > baseline_ns]
    new_target = [event for event in received if event["timestampNs"] > before["target_last_event_ns"]]
    receipts = [event for event in new_target if event.get("kind") == "insertText.completed"]
    for label, actual in [("sender", len(new_sender)), ("insertText receipts", len(receipts))]:
        if actual < len(expected_slots):
            pending.append(f"insufficient {label}: {actual}/{len(expected_slots)}; no pass inferred")
        elif actual > len(expected_slots):
            errors.append(f"extra {label}: {actual}/{len(expected_slots)}; no last-N filtering allowed")
    actual_slots = [event.get("slot") for event in new_sender]
    if actual_slots != expected_slots[:len(actual_slots)]:
        errors.append("sender slot sequence differs from the requested full sequence")
    if any(event.get("state") != "posted-unconfirmed" for event in new_sender):
        errors.append("one or more sender events failed or are not posted-unconfirmed")
    if any(event.get("targetPID") != target.get("targetPID") for event in new_sender):
        errors.append("sender targetPID differs from the independent Target PID")
    unchanged = rows == before["history_metadata_rows"]
    if not unchanged:
        errors.append("T04 history metadata changed: id/fingerprint/copied_at/sort_index must match exactly")
    final_matches = target.get("contentSHA256") == sha_bytes(expected_text.encode("utf-8")) and \
        target.get("contentUTF16Length") == utf16_length(expected_text)
    if not final_matches:
        (pending if len(receipts) < len(expected_parts) else errors).append("Target final length/SHA256 does not equal the complete fixture")
    matched, latencies, prefix = [], [], ""
    for index, (request, receipt, part) in enumerate(zip(new_sender, receipts, expected_parts)):
        prefix += part
        expected_hash = sha_bytes(part.encode("utf-8"))
        delta_ns = receipt["timestampNs"] - received_at(request)
        reasons = []
        if receipt.get("incomingSHA256") != expected_hash or receipt.get("incomingUTF16Length") != utf16_length(part):
            reasons.append("incoming fixture hash/length mismatch")
        if receipt.get("targetPID") != target.get("targetPID"):
            reasons.append("receipt targetPID mismatch")
        if receipt.get("frontmostPID") != target.get("targetPID") or receipt.get("isAppActive") is not True:
            reasons.append("Target was not observed as focused at receipt")
        if delta_ns < 0:
            reasons.append("receipt timestamp predates sender callback")
        if receipt.get("contentSHA256") != sha_bytes(prefix.encode("utf-8")) or receipt.get("contentUTF16Length") != utf16_length(prefix):
            reasons.append("Target cumulative content prefix differs")
        request_matches = request.get("slot") == expected_slots[index] and request.get("state") == "posted-unconfirmed" and request.get("targetPID") == target.get("targetPID")
        ok = not reasons and request_matches
        if reasons:
            errors.append(f"receipt {index + 1}: " + "; ".join(reasons))
        if ok:
            latencies.append(delta_ns / 1_000_000)
        matched.append({"ordinal": index + 1, "slot": request.get("slot"), "matched": ok,
                        "sender_received_at_ns": received_at(request), "receipt_at_ns": receipt["timestampNs"],
                        "incoming_sha256": receipt.get("incomingSHA256"),
                        "callback_latency_ms": delta_ns / 1_000_000 if delta_ns >= 0 else None})
    successful_sequences = sum(
        len(matched[start:start + len(slots)]) == len(slots) and
        all(item["matched"] for item in matched[start:start + len(slots)])
        for start in range(0, len(expected_slots), len(slots))
    )
    return {
        "status": "mismatch" if errors else "pending" if pending else "pass",
        "errors": errors, "pending_reasons": pending,
        "sender_new_event_count": len(new_sender), "target_new_insert_receipt_count": len(receipts),
        "expected_event_count": len(expected_slots), "actual_slots": actual_slots,
        "expected_slots": expected_slots, "repeat_count": repeats,
        "expected_fixture_sha256": sha_bytes(expected_text.encode("utf-8")),
        "expected_fixture_utf16_length": utf16_length(expected_text),
        "target_final_fixture_match": final_matches, "target_pid": target.get("targetPID"),
        "target_session": target.get("session"), "history_metadata_strictly_unchanged_T04": unchanged,
        "history_before_sha256": before["history_metadata_sha256"], "history_after_sha256": canonical_sha(rows),
        "matched_receipts": sum(item["matched"] for item in matched), "receipt_matches": matched,
        "callback_latency_ms_p50": percentile(latencies, 0.50),
        "callback_latency_ms_p95": percentile(latencies, 0.95),
        "measurement": "hotkey callback to independent AppKit insertText.completed callback, including diagnostic overhead",
        "screen_visible_latency_measured": False,
        "physical_option_hold_verified_by_tool": False,
        "successful_consecutive_sequences": successful_sequences,
        "consecutive_sequence_receipt_success_rate": successful_sequences / repeats,
        "notes": ["Physical modifier hold requires separate user attestation.",
                  "Repeated sequences share one Target session; these are not independent cross-app trials.",
                  "M1 diagnostics expose no sender process/run ID; Target session, event cursor and retention checks bound this correlation.",
                  "No history manifests, blobs, clipboard contents, UI, or permission settings were accessed."],
    }


def verify(args):
    before, _ = read_json(OUTPUT / (args.tag + "-baseline.json"))
    if before.get("kind") != "M1-trial-baseline" or before.get("tag") != args.tag:
        raise ValueError("baseline kind/tag is invalid")
    slots = [int(value) for value in args.slots.split(",")]
    if not slots or any(value < 1 or value > 12 for value in slots):
        raise ValueError("--slots must be comma-separated slot numbers 1 through 12")
    if args.repeat < 1 or len(slots) * args.repeat > SENDER_RETENTION:
        raise ValueError("request 1..100 events; split longer trials into separately baselined tags")
    parts = json.loads(args.expected_parts_json) if args.expected_parts_json is not None else list(args.expected)
    if not isinstance(parts, list) or len(parts) != len(slots) or any(not isinstance(part, str) or not part or utf16_length(part) > 20 for part in parts):
        raise ValueError("fixture must supply one nonempty <=20-UTF16 insertion per base slot; use --expected-parts-json for multi-character slots")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    prefix = OUTPUT / (args.tag + "-check-" + stamp)
    sources = {}
    try:
        sender, sender_raw = read_json(SENDER_PATH)
        sources["sender"] = freeze(sender_raw, Path(str(prefix) + "-sender.json"))
        target, target_raw = read_json(TARGET_PATH)
        sources["target"] = freeze(target_raw, Path(str(prefix) + "-target.json"))
        rows = validate_rows(metadata_rows())
        write_json(Path(str(prefix) + "-store.json"), rows)
        result = evaluate(before, sender, target, rows, slots, parts, args.repeat)
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
        result = {"status": "pending", "errors": [], "pending_reasons": [type(error).__name__ + ": " + str(error)]}
    result.update({"schema_version": 1, "kind": "M1-trial-verification", "tag": args.tag,
                   "verified_at_utc": utc_now(), "sources": sources,
                   "baseline_artifact": str(OUTPUT / (args.tag + "-baseline.json"))})
    destination = Path(str(prefix) + "-result.json")
    write_json(destination, result)
    summary = {key: result[key] for key in ["status", "sender_new_event_count", "target_new_insert_receipt_count",
                                          "matched_receipts", "history_metadata_strictly_unchanged_T04",
                                          "callback_latency_ms_p50", "callback_latency_ms_p95",
                                          "errors", "pending_reasons"] if key in result}
    summary["artifact"] = str(destination)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if result["status"] == "pass" else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    prepare = commands.add_parser("baseline", help="capture a pre-trial baseline; refuses overwrite")
    prepare.add_argument("tag")
    prepare.add_argument("--import-existing", action="store_true", help="import the frozen <tag>-before-{diagnostics,target,store}.json files")
    check = commands.add_parser("verify", help="verify exactly the full requested sequence after baseline")
    check.add_argument("tag")
    check.add_argument("--slots", required=True)
    fixture = check.add_mutually_exclusive_group(required=True)
    fixture.add_argument("--expected")
    fixture.add_argument("--expected-parts-json")
    repeat = check.add_mutually_exclusive_group()
    repeat.add_argument("--repeat", type=int, default=1)
    repeat.add_argument("--repeat30", dest="repeat", action="store_const", const=30)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,79}", args.tag):
        parser.error("tag must contain 1..80 ASCII letters, digits, dot, underscore or dash and begin with a letter/digit")
    try:
        return baseline(args) if args.command == "baseline" else verify(args)
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
        print(json.dumps({"status": "pending", "error": type(error).__name__ + ": " + str(error)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
