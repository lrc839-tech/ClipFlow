#!/usr/bin/env python3
"""Verify a real reboot without changing ClipFlow, permissions, or clipboard data.

After the remaining copy/paste trials, run:
  python3 scripts/verify_reboot.py baseline
Then manually restart macOS, reopen the same ClipFlow.app, and run:
  python3 scripts/verify_reboot.py verify

The baseline refuses overwrite. --baseline-file permits an isolated dry run;
it must not be used to replace the final baseline after restarting. SQLite is
opened mode=ro (including committed WAL), blobs are streamed for length/SHA256,
and only IDs, timestamps, sizes, hashes, and readiness metadata are emitted.
No general pasteboard, UI automation, TCC data, or permission setting is used.

Exit codes: 0 baseline saved or reboot checks passed; 1 pending/unmet checks;
2 malformed evidence, unavailable inputs, or an operational error. App restart,
SIGKILL, and same-boot dry runs can never count as a reboot pass.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import plistlib
import re
import sqlite3
import stat
import subprocess
import sys
import tempfile
import uuid


PROJECT = Path(__file__).resolve().parents[1]
DEFAULT_BASELINE = PROJECT / "output/m1/reboot-baseline.json"
DEFAULT_DATABASE = Path.home() / "Library/Application Support/ClipFlow/history.sqlite3"
DEFAULT_APP = Path.home() / "Applications/ClipFlow.app"
DEFAULT_DIAGNOSTICS = Path.home() / "Library/Logs/ClipFlow/diagnostics.json"
HASH_PATTERN = re.compile(r"[0-9a-f]{64}\Z")
MAX_SNAPSHOT_BYTES = 64 * 1024 * 1024
METADATA_COLUMNS = ["id", "fingerprint", "copied_at", "sort_index"]


class EvidenceError(Exception):
    """Only fixed diagnostic labels, never file contents or arbitrary SQL text."""


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, _message):
        print(json.dumps({"status": "error", "reason": "invalid_arguments"}))
        self.exit(2)


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def canonical_sha(value):
    encoded = json.dumps(value, sort_keys=True, ensure_ascii=False,
                         separators=(",", ":"), allow_nan=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def run_readonly(command):
    completed = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if completed.returncode:
        raise EvidenceError("readonly_system_command_failed")
    return completed.stdout, completed.stderr


def boot_identity():
    output, _ = run_readonly(["/usr/sbin/sysctl", "-n", "kern.bootsessionuuid"])
    try:
        boot_uuid = str(uuid.UUID(output.strip())).upper()
    except ValueError:
        raise EvidenceError("invalid_boot_session_uuid") from None
    output, _ = run_readonly(["/usr/sbin/sysctl", "-n", "kern.boottime"])
    seconds = re.search(r"\bsec\s*=\s*(\d+)", output)
    microseconds = re.search(r"\busec\s*=\s*(\d+)", output)
    if not seconds or not microseconds:
        raise EvidenceError("invalid_boot_time")
    return {"session_uuid": boot_uuid,
            "started_at_epoch": int(seconds[1]) + int(microseconds[1]) / 1_000_000}


def file_sha(path):
    """O_NOFOLLOW and fstat bind validation to the opened regular file."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise EvidenceError("not_a_regular_file")
        hasher = hashlib.sha256()
        length = 0
        while chunk := stream.read(1024 * 1024):
            hasher.update(chunk)
            length += len(chunk)
        after = os.fstat(stream.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != \
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns) or length != after.st_size:
            raise EvidenceError("file_changed_during_hash")
        return hasher.hexdigest(), length


def app_identity(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    executable = info.get("CFBundleExecutable")
    if info.get("CFBundleIdentifier") != "local.lrc.clipflow" or \
            not isinstance(executable, str) or not executable or \
            Path(executable).name != executable or executable in (".", ".."):
        raise EvidenceError("not_the_production_clipflow_bundle")
    binary = app / "Contents/MacOS" / executable
    digest, length = file_sha(binary)
    run_readonly(["/usr/bin/codesign", "--verify", "--strict", str(app)])
    output, errors = run_readonly(["/usr/bin/codesign", "-dvvv", str(app)])
    match = re.search(r"^CDHash=([0-9a-fA-F]{40})\s*$", output + "\n" + errors, re.MULTILINE)
    if not match:
        raise EvidenceError("codesign_cdhash_unavailable")
    if file_sha(binary) != (digest, length):
        raise EvidenceError("app_changed_during_identity_check")
    return {"bundle_path": str(app), "binary_path": str(binary),
            "bundle_identifier": info["CFBundleIdentifier"],
            "binary_sha256": digest, "binary_bytes": length,
            "cdhash": match[1].lower()}


def history_snapshot(database):
    # Do not use immutable=1: it would ignore committed records still in WAL.
    connection = sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=3)
    try:
        connection.execute("PRAGMA query_only=ON")
        connection.execute("BEGIN")
        data = connection.execute(
            "SELECT id,fingerprint,copied_at,sort_index,manifest "
            "FROM history ORDER BY sort_index DESC,id ASC"
        ).fetchall()
    finally:
        connection.close()
    metadata, references = [], []
    seen_ids, seen_sorts, lengths = set(), set(), {}
    reference_count = 0
    for record_id, fingerprint, copied_at, sort_index, encoded_manifest in data:
        if not isinstance(record_id, str):
            raise EvidenceError("invalid_history_record_id")
        try:
            uuid.UUID(record_id)
        except ValueError:
            raise EvidenceError("invalid_history_record_id") from None
        if record_id in seen_ids or not isinstance(fingerprint, str) or \
                HASH_PATTERN.fullmatch(fingerprint) is None or \
                type(copied_at) not in (float, int) or not math.isfinite(copied_at) or \
                type(sort_index) is not int or sort_index <= 0 or sort_index in seen_sorts:
            raise EvidenceError("invalid_history_metadata")
        seen_ids.add(record_id)
        seen_sorts.add(sort_index)
        metadata.append([record_id, fingerprint, copied_at, sort_index])
        if not isinstance(encoded_manifest, str):
            raise EvidenceError("invalid_manifest")
        try:
            manifest = json.loads(encoded_manifest)
        except (ValueError, TypeError):
            raise EvidenceError("invalid_manifest") from None
        if not isinstance(manifest, dict) or manifest.get("version") != 1 or \
                not isinstance(manifest.get("items"), list) or not manifest["items"]:
            raise EvidenceError("invalid_manifest")
        saved_items, total = [], 0
        for item in manifest["items"]:
            if not isinstance(item, dict) or not isinstance(item.get("representations"), list) or \
                    not item["representations"]:
                raise EvidenceError("invalid_manifest_item")
            saved_references, seen_types = [], set()
            for reference in item["representations"]:
                if not isinstance(reference, dict):
                    raise EvidenceError("invalid_blob_reference")
                digest, length, representation_type = \
                    reference.get("hash"), reference.get("length"), reference.get("type")
                if not isinstance(digest, str) or HASH_PATTERN.fullmatch(digest) is None or \
                        type(length) is not int or length < 0 or \
                        not isinstance(representation_type, str) or not representation_type or \
                        representation_type in seen_types:
                    raise EvidenceError("invalid_blob_reference")
                seen_types.add(representation_type)
                total += length
                if total > MAX_SNAPSHOT_BYTES or (digest in lengths and lengths[digest] != length):
                    raise EvidenceError("inconsistent_blob_reference_length")
                lengths[digest] = length
                reference_count += 1
                saved_references.append({"hash": digest, "length": length})
            saved_items.append(saved_references)
        # Only a digest of descriptor structure is emitted; no UTI/source/preview text.
        references.append({"record_id": record_id, "manifest_sha256": canonical_sha(manifest),
                           "items": saved_items})
    return {"metadata_columns": METADATA_COLUMNS, "metadata_rows": metadata,
            "metadata_sha256": canonical_sha(metadata), "record_count": len(metadata),
            "references": references, "references_sha256": canonical_sha(references),
            "reference_count": reference_count, "unique_blob_count": len(lengths)}, lengths


def verify_blobs(directory, lengths):
    attributes = directory.lstat()
    if not stat.S_ISDIR(attributes.st_mode) or stat.S_ISLNK(attributes.st_mode):
        raise EvidenceError("invalid_blob_directory")
    checked, issues = 0, []
    for digest, expected_length in sorted(lengths.items()):
        # digest was validated as exactly 64 lowercase hexadecimal characters.
        path = directory / digest
        try:
            attributes = path.lstat()
            if stat.S_ISLNK(attributes.st_mode) or not stat.S_ISREG(attributes.st_mode):
                issues.append({"hash": digest, "reason": "blob_not_regular_or_is_symlink"})
                continue
            if attributes.st_size != expected_length:
                issues.append({"hash": digest, "reason": "blob_length_mismatch"})
                continue
            actual_hash, actual_length = file_sha(path)
            if actual_hash != digest or actual_length != expected_length:
                issues.append({"hash": digest, "reason": "blob_hash_or_length_mismatch"})
                continue
            checked += 1
        except FileNotFoundError:
            issues.append({"hash": digest, "reason": "missing_blob"})
        except EvidenceError as error:
            issues.append({"hash": digest, "reason": str(error)})
    return {"all_referenced_blobs_valid": not issues,
            "checked_unique_blob_count": checked, "issues": issues}


def readiness(diagnostics, binary, boot):
    raw = diagnostics.read_bytes()
    try:
        report = json.loads(raw)
    except ValueError:
        raise EvidenceError("invalid_m1_diagnostics") from None
    if not isinstance(report, dict):
        raise EvidenceError("invalid_m1_diagnostics")
    hotkeys = report.get("hotkeys")
    slots = [row.get("slot") for row in hotkeys if isinstance(row, dict)] \
        if isinstance(hotkeys, list) else []
    registered = isinstance(hotkeys, list) and len(hotkeys) == 12 and \
        len(slots) == 12 and all(type(slot) is int for slot in slots) and \
        sorted(slots) == list(range(1, 13)) and \
        all(type(row.get("status")) is int and row["status"] == 0 for row in hotkeys)
    fresh = False
    try:
        updated = datetime.fromisoformat(report["updatedAt"].replace("Z", "+00:00"))
        if updated.tzinfo is not None:
            fresh = boot["started_at_epoch"] <= updated.timestamp() <= \
                datetime.now(timezone.utc).timestamp() + 10
    except (KeyError, TypeError, ValueError, AttributeError):
        pass
    output, _ = run_readonly(["/bin/ps", "-axo", "pid=,comm="])
    pids = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[0].isdigit() and fields[1] == str(binary):
            pids.append(int(fields[0]))
    return {"production_stage": report.get("stage") == "M1-text-only",
            "ready": report.get("ready") is True, "hotkeys_12_registered": registered,
            "accessibility_trusted": report.get("accessibilityTrusted") is True,
            "post_event_allowed": report.get("postEventAllowed") is True,
            "diagnostics_updated_during_current_boot": fresh,
            "running_app_pids": pids, "app_running": bool(pids),
            "diagnostics_sha256": hashlib.sha256(raw).hexdigest()}


def collect(args):
    boot = boot_identity()
    history, lengths = history_snapshot(args.database)
    blobs = verify_blobs(args.database.parent / "blobs", lengths)
    app = app_identity(args.app)
    state = readiness(args.diagnostics, Path(app["binary_path"]), boot)
    # A live copy during blob scanning invalidates this measurement; never silently
    # compare references from one SQLite revision to metadata from another.
    after_history, _ = history_snapshot(args.database)
    if after_history != history:
        raise EvidenceError("history_changed_during_verification")
    after_boot = boot_identity()
    if after_boot != boot:
        raise EvidenceError("boot_changed_during_verification")
    return {"schema_version": 1, "captured_at_utc": utc_now(),
            "database_path": str(args.database), "diagnostics_path": str(args.diagnostics),
            "boot": boot, "app": app, "history": history,
            "blob_validation": blobs, "m1_readiness": state}


def write_baseline(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".clipflow-reboot-", delete=False) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), 0o600)
            stream.write((json.dumps(value, sort_keys=True, ensure_ascii=False,
                                     indent=2, allow_nan=False) + "\n").encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
        # Atomic no-overwrite publication, including races with another baseline run.
        os.link(temporary, path)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def baseline(args):
    if args.baseline_file.exists():
        raise EvidenceError("baseline_exists_refusing_overwrite")
    snapshot = collect(args)
    if not snapshot["blob_validation"]["all_referenced_blobs_valid"]:
        print(json.dumps({"status": "pending", "reason": "baseline_blob_validation_failed",
                          "blob_validation": snapshot["blob_validation"]}, sort_keys=True))
        return 1
    snapshot["kind"] = "M1-reboot-baseline"
    write_baseline(args.baseline_file, snapshot)
    print(json.dumps({"status": "baseline-saved", "artifact": str(args.baseline_file),
                      "boot_session_uuid": snapshot["boot"]["session_uuid"],
                      "history_record_count": snapshot["history"]["record_count"],
                      "reference_count": snapshot["history"]["reference_count"],
                      "unique_blob_count": snapshot["history"]["unique_blob_count"],
                      "app_binary_sha256": snapshot["app"]["binary_sha256"],
                      "app_cdhash": snapshot["app"]["cdhash"],
                      "reboot_verified": False}, sort_keys=True))
    return 0


def evaluate(before, current):
    if not isinstance(before, dict) or before.get("schema_version") != 1 or \
            before.get("kind") != "M1-reboot-baseline":
        raise EvidenceError("invalid_reboot_baseline")
    # Validate the baseline's own summaries before treating it as frozen evidence.
    history = before["history"]
    if history["metadata_sha256"] != canonical_sha(history["metadata_rows"]) or \
            history["references_sha256"] != canonical_sha(history["references"]):
        raise EvidenceError("baseline_summary_hash_mismatch")
    before_boot_uuid = uuid.UUID(before["boot"]["session_uuid"])
    current_boot_uuid = uuid.UUID(current["boot"]["session_uuid"])
    if not before["blob_validation"]["all_referenced_blobs_valid"]:
        raise EvidenceError("baseline_did_not_validate_blobs")
    state = current["m1_readiness"]
    checks = {
        "boot_session_uuid_changed": before_boot_uuid != current_boot_uuid,
        "database_path_unchanged": before["database_path"] == current["database_path"],
        "app_bundle_and_binary_paths_unchanged":
            before["app"]["bundle_path"] == current["app"]["bundle_path"] and
            before["app"]["binary_path"] == current["app"]["binary_path"],
        "app_binary_sha256_unchanged": before["app"]["binary_sha256"] == current["app"]["binary_sha256"],
        "app_cdhash_unchanged": before["app"]["cdhash"] == current["app"]["cdhash"],
        "history_uuid_order_and_metadata_unchanged": history["metadata_rows"] == current["history"]["metadata_rows"],
        "history_reference_descriptors_unchanged": history["references"] == current["history"]["references"],
        "all_referenced_blobs_valid": current["blob_validation"]["all_referenced_blobs_valid"],
        **{name: state[name] for name in ["production_stage", "ready", "hotkeys_12_registered",
                                         "accessibility_trusted", "post_event_allowed",
                                         "diagnostics_updated_during_current_boot", "app_running"]},
    }
    pending = [name for name, passed in checks.items() if not passed]
    return {"status": "pending" if pending else "pass", "checks": checks,
            "pending_reasons": pending, "reboot_verified": not pending,
            "boot_session_uuid_before": before["boot"]["session_uuid"],
            "boot_session_uuid_now": current["boot"]["session_uuid"],
            "history_record_count": current["history"]["record_count"],
            "reference_count": current["history"]["reference_count"],
            "blob_validation": current["blob_validation"],
            "app_binary_sha256": current["app"]["binary_sha256"],
            "app_cdhash": current["app"]["cdhash"],
            "running_app_pids": state["running_app_pids"],
            "limits": ["Checks recorded readiness, not physical shortcut use after reboot.",
                       "No screen-visible latency or cross-app paste completion is measured.",
                       "App diagnostics have no process/run ID; current-boot timestamp and a running binary are checked."]}


def verify(args):
    try:
        before = json.loads(args.baseline_file.read_bytes())
    except FileNotFoundError:
        print(json.dumps({"status": "pending", "reason": "baseline_missing",
                          "baseline_artifact": str(args.baseline_file), "reboot_verified": False}))
        return 1
    result = evaluate(before, collect(args))
    result.update({"schema_version": 1, "kind": "M1-reboot-verification",
                   "verified_at_utc": utc_now(), "baseline_artifact": str(args.baseline_file)})
    print(json.dumps(result, sort_keys=True, ensure_ascii=False, indent=2, allow_nan=False))
    return 0 if result["status"] == "pass" else 1


def main():
    parser = JSONArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["baseline", "verify"])
    parser.add_argument("--baseline-file", type=Path, default=DEFAULT_BASELINE)
    parser.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    parser.add_argument("--app", type=Path, default=DEFAULT_APP)
    parser.add_argument("--diagnostics", type=Path, default=DEFAULT_DIAGNOSTICS)
    args = parser.parse_args()
    for name in ["baseline_file", "database", "app", "diagnostics"]:
        # abspath normalizes user input without silently resolving a blob symlink.
        setattr(args, name, Path(os.path.abspath(getattr(args, name).expanduser())))
    try:
        return baseline(args) if args.command == "baseline" else verify(args)
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError, AttributeError, IndexError,
            plistlib.InvalidFileException, subprocess.SubprocessError, EvidenceError) as error:
        reason = str(error) if isinstance(error, EvidenceError) else type(error).__name__
        print(json.dumps({"status": "error", "reason": reason, "reboot_verified": False}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
