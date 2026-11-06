#!/usr/bin/env python3
"""Real SIGKILL acceptance for the M1 store, using disposable known fixtures only.

Compiles a separate CLI in ~/Library/Caches/ClipFlowCrashCheck. The test root is
an exclusive TemporaryDirectory, removed afterwards; no .app, user history,
permissions, or general pasteboard is accessed. Run explicitly with Python 3.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get("CLIPFLOW_CRASH_TEST_CACHE", Path.home() / "Library/Caches/ClipFlowCrashCheck"))
BINARY = CACHE / "ClipFlowStoreCrashcheck"


def emit(**fields: object) -> None:
    print(json.dumps(fields, sort_keys=True), flush=True)


def compile_fixture() -> None:
    CACHE.mkdir(parents=True, exist_ok=True)
    command = [
        "xcrun", "swiftc", "-swift-version", "5", "-parse-as-library", "-O",
        "-I", str(ROOT / "Sources/CSQLite"),
        str(ROOT / "Sources/ClipFlowCore/PasteboardSnapshot.swift"),
        str(ROOT / "Sources/ClipFlowCore/HistoryStore.swift"),
        str(ROOT / "Sources/ClipFlowCore/ContentDescriptor.swift"),
        str(ROOT / "scripts/store_crashcheck.swift"),
        "-o", str(BINARY),
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=120)
    if result.returncode:
        # Compiler diagnostics refer only to these test sources, never history.
        sys.stderr.write(result.stderr)
        raise RuntimeError("fixture_compile_failed")


def kill_at_ready(mode: str, directory: Path) -> int:
    child = subprocess.Popen(
        [str(BINARY), mode, str(directory)],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1,
    )
    try:
        assert child.stdout is not None
        deadline = time.monotonic() + 30
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("fixture_ready_timeout")
            readable, _, _ = select.select([child.stdout], [], [], remaining)
            if not readable:
                raise RuntimeError("fixture_ready_timeout")
            line = child.stdout.readline()
            if not line:
                raise RuntimeError("fixture_exited_before_ready")
            event = json.loads(line)
            if event.get("event") != "ready" or event.get("mode") != mode:
                raise RuntimeError("fixture_bad_ready_event")
            if event.get("recordCount") != 3:
                raise RuntimeError("fixture_bad_ready_count")
            break
        # Popen.kill sends SIGKILL on macOS. No graceful stop or simulated error.
        child.kill()
        child.communicate(timeout=10)
        if child.returncode != -signal.SIGKILL:
            raise RuntimeError("fixture_was_not_sigkilled")
        return child.returncode
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=10)


def check(directory: Path, orphan_count: int) -> dict[str, object]:
    result = subprocess.run(
        [str(BINARY), "check", str(directory), str(orphan_count)],
        capture_output=True, text=True, timeout=30,
    )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    if result.returncode or len(lines) != 1:
        # JSON emitted by the child contains only known fixture result labels.
        for line in lines:
            try:
                event = json.loads(line)
                if event.get("event") == "failed":
                    emit(stage="child_check", result="failed", reason=event.get("reason", "unknown"))
            except ValueError:
                pass
        raise RuntimeError("fixture_check_failed")
    event = json.loads(lines[0])
    if event.get("event") != "checked" or event.get("result") != "passed":
        raise RuntimeError("fixture_bad_check_result")
    return event


def main() -> int:
    try:
        compile_fixture()
        with tempfile.TemporaryDirectory(prefix="ClipFlowCrashFixture-") as disposable:
            directory = Path(disposable)
            committed_exit = kill_at_ready("committed", directory)
            committed = check(directory, 0)
            emit(stage="after_committed_sigkill", childExitCode=committed_exit, **committed)
            uncommitted_exit = kill_at_ready("uncommitted", directory)
            interrupted = check(directory, 1)
            emit(stage="after_precommit_sigkill", childExitCode=uncommitted_exit, **interrupted)
            again = check(directory, 1)
            emit(stage="reopen_again", **again)
        emit(result="passed", realSIGKILLCount=2, reopenCheckCount=3)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        # The reason is a fixed test-stage label, not subprocess environment/data.
        reason = str(error) if isinstance(error, RuntimeError) else type(error).__name__
        emit(result="failed", reason=reason)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
