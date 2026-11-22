#!/usr/bin/env python3
"""Stand-in for the Claude Code CLI, used by tests. Makes no network calls.

It reproduces the parts of the real CLI that the engine depends on:

* ``--version`` and ``--help`` (the help text lists every flag the engine needs).
* stream-json output with the same event shapes as Claude Code 2.1.330.
* Session semantics, enabled when ``FAKE_CLAUDE_STATE`` names a JSON file:
  ``--session-id X`` fails with "already in use" if X exists;
  ``--resume X`` fails with "No conversation found" if X is unknown.

Behaviour is chosen with ``FAKE_CLAUDE_MODE``:

* ``ok`` (default): structured explanation covering the requested target lines.
* ``sleep``: prints the init event, then sleeps ``FAKE_CLAUDE_SLEEP`` seconds.
* ``not_json``: result text is not JSON and there is no structured output.
* ``bad_range``: one valid section plus one that points past the end of the file.
* ``is_error``: the result reports an API error.
* ``no_result``: exits 1 with stderr only.
* ``echo_argv``: like ``ok`` but writes the argv to ``FAKE_CLAUDE_ARGV_LOG``.
"""

from __future__ import annotations

import json
import os
import re
import sys
import time
import uuid

REQUIRED_HELP_FLAGS = (
    "--print", "--output-format", "--verbose", "--include-partial-messages", "--json-schema",
    "--tools", "--allowedTools", "--disallowedTools", "--permission-mode", "--permission-prompts",
    "--restricted", "--max-budget-usd", "--session-id", "--resume", "--append-system-prompt", "--model",
    "--effort",
)


def _arg_value(argv: list[str], flag: str) -> str | None:
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return None


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def _load_state(path: str | None) -> set[str] | None:
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            return set(json.load(handle))
    except FileNotFoundError:
        return set()


def _save_state(path: str, known: set[str]) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(sorted(known), handle)


def _structured(prompt: str, mode: str) -> dict:
    if "Section refresh:" in prompt:
        return {"explanation": "Giải thích làm mới giả lập cho đoạn này."}
    if "Question from the reader:" in prompt:
        return {"answer": "Đây là câu trả lời giả lập cho câu hỏi."}
    match = re.search(r"Target lines:\s*(\d+)-(\d+)", prompt)
    start, end = (int(match.group(1)), int(match.group(2))) if match else (1, 1)
    sections = [
        {
            "source_start": start,
            "source_end": end,
            "title": "Đoạn giải thích",
            "explanation": "Đây là giải thích giả lập cho các dòng được chọn.",
        }
    ]
    if mode == "bad_range":
        sections.append(
            {"source_start": 9000, "source_end": 9001, "title": "Sai vị trí", "explanation": "lỗi"}
        )
    return {
        "summary": "Tóm tắt giả lập.",
        "sections": sections,
        "dependencies": ["không có"],
        "data_flow": [],
        "notes": ["Đây là đầu ra của fake_claude."],
    }


def main() -> int:
    argv = sys.argv[1:]
    if argv == ["--version"]:
        print("2.1.330 (Claude Code)")
        return 0
    if argv == ["--help"]:
        print("Usage: claude [options]\n\nOptions:\n" + "\n".join(f"  {flag}" for flag in REQUIRED_HELP_FLAGS))
        return 0

    mode = os.environ.get("FAKE_CLAUDE_MODE", "ok")
    state_path = os.environ.get("FAKE_CLAUDE_STATE")
    log_path = os.environ.get("FAKE_CLAUDE_ARGV_LOG")
    if log_path:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(argv) + "\n")

    prompt = sys.stdin.read()
    session_id = _arg_value(argv, "--session-id") or _arg_value(argv, "--resume") or str(uuid.uuid4())
    resuming = "--resume" in argv

    known = _load_state(state_path)
    if known is not None:
        if resuming and session_id not in known:
            sys.stderr.write(f"No conversation found with session ID: {session_id}\n")
            _emit({"type": "result", "subtype": "error_during_execution", "is_error": True,
                   "session_id": session_id, "result": "", "num_turns": 0})
            return 1
        if not resuming and session_id in known:
            sys.stderr.write(f"Error: Session ID {session_id} is already in use.\n")
            return 1
        known.add(session_id)
        _save_state(state_path, known)

    if mode == "no_result":
        sys.stderr.write("boom: simulated failure\n")
        return 1

    _emit({"type": "system", "subtype": "init", "session_id": session_id, "model": "claude-test-model",
           "tools": ["Glob", "Grep", "Read"], "apiKeySource": "none"})

    if mode == "sleep":
        time.sleep(float(os.environ.get("FAKE_CLAUDE_SLEEP", "30")))

    if mode == "is_error":
        _emit({"type": "assistant", "is_api_error_message": True, "api_error_status": 400,
               "api_error_type": "invalid_request_error", "session_id": session_id,
               "message": {"content": [{"type": "text", "text": "Credit balance is too low"}]}})
        _emit({"type": "result", "subtype": "success", "is_error": True, "session_id": session_id,
               "result": "Credit balance is too low", "total_cost_usd": 0, "num_turns": 1,
               "api_error_status": 400})
        return 0

    if mode == "not_json":
        text = "Đây không phải JSON."
        _emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                  "delta": {"type": "text_delta", "text": text}}})
        _emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session_id,
               "result": text, "total_cost_usd": 0.001, "num_turns": 1, "duration_ms": 12})
        return 0

    structured = _structured(prompt, mode)
    payload = json.dumps(structured, ensure_ascii=False)
    for index in range(0, len(payload), 40):
        _emit({"type": "stream_event", "event": {"type": "content_block_delta", "index": 0,
                                                  "delta": {"type": "input_json_delta",
                                                            "partial_json": payload[index:index + 40]}}})
    _emit({"type": "result", "subtype": "success", "is_error": False, "session_id": session_id,
           "result": "", "structured_output": structured, "total_cost_usd": 0.0011, "num_turns": 1,
           "duration_ms": 25})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
