"""Incremental parser for ``claude -p --output-format stream-json`` output.

Event shapes were verified against Claude Code 2.1.330 (see tests/fixtures):

* ``{"type": "system", "subtype": "init", "session_id": ..., "model": ...}``
* ``{"type": "stream_event", "event": {...}}`` (only with --include-partial-messages).
  Output characters arrive as ``content_block_delta`` events whose delta is
  ``text_delta`` (``text``) or ``input_json_delta`` (``partial_json``). The
  structured output is streamed as ``input_json_delta``.
* ``{"type": "assistant", "message": {...}, "is_api_error_message": bool}``
* ``{"type": "result", "subtype": ..., "is_error": bool, "result": str,
  "structured_output": obj|absent, "session_id": ..., "total_cost_usd": ...}``

Unknown event types are ignored so new CLI releases do not break parsing.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any


@dataclass
class StreamState:
    """Everything learned from the stream so far."""

    session_id: str | None = None
    model: str | None = None
    output_chars: int = 0
    result: dict[str, Any] | None = None
    api_error: dict[str, Any] | None = None
    malformed_lines: int = 0
    event_types: dict[str, int] = field(default_factory=dict)


ProgressCallback = Callable[[StreamState], None]


class StreamParser:
    """Feed raw stdout lines; query :attr:`state` at any time."""

    def __init__(self, on_progress: ProgressCallback | None = None) -> None:
        self.state = StreamState()
        self._on_progress = on_progress

    def feed(self, raw_line: bytes | str) -> None:
        """Consume one line of stdout. Never raises on bad input."""
        text = raw_line.decode("utf-8", errors="replace") if isinstance(raw_line, bytes) else raw_line
        text = text.strip()
        if not text:
            return
        try:
            event = json.loads(text)
        except json.JSONDecodeError:
            self.state.malformed_lines += 1
            return
        if not isinstance(event, dict):
            self.state.malformed_lines += 1
            return
        self._dispatch(event)

    def _dispatch(self, event: dict[str, Any]) -> None:
        kind = event.get("type")
        if isinstance(kind, str):
            self.state.event_types[kind] = self.state.event_types.get(kind, 0) + 1

        if kind == "system" and event.get("subtype") == "init":
            session_id = event.get("session_id")
            if isinstance(session_id, str):
                self.state.session_id = session_id
            model = event.get("model")
            if isinstance(model, str):
                self.state.model = model
        elif kind == "stream_event":
            self._on_stream_event(event.get("event"))
        elif kind == "assistant":
            if event.get("is_api_error_message"):
                self.state.api_error = {
                    "error": event.get("error"),
                    "api_error_status": event.get("api_error_status"),
                    "api_error_type": event.get("api_error_type"),
                    "message": _first_text(event.get("message")),
                }
        elif kind == "result":
            self.state.result = event
            session_id = event.get("session_id")
            if isinstance(session_id, str):
                self.state.session_id = session_id

    def _on_stream_event(self, inner: Any) -> None:
        if not isinstance(inner, dict) or inner.get("type") != "content_block_delta":
            return
        delta = inner.get("delta")
        if not isinstance(delta, dict):
            return
        chunk = ""
        if delta.get("type") == "text_delta" and isinstance(delta.get("text"), str):
            chunk = delta["text"]
        elif delta.get("type") == "input_json_delta" and isinstance(delta.get("partial_json"), str):
            chunk = delta["partial_json"]
        if not chunk:
            return
        self.state.output_chars += len(chunk)
        if self._on_progress is not None:
            self._on_progress(self.state)


def _first_text(message: Any) -> str | None:
    if not isinstance(message, dict):
        return None
    for block in message.get("content") or []:
        if isinstance(block, dict) and block.get("type") == "text" and isinstance(block.get("text"), str):
            return block["text"]
    return None
