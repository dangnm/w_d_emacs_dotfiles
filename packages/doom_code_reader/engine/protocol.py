"""Wire-level helpers: newline-delimited JSON encoding and outgoing message builders.

The shapes produced here are documented in PROTOCOL.md. Keep them in sync.
"""

from __future__ import annotations

import json
from typing import Any

from engine.config import ENGINE_VERSION, PROTOCOL_VERSION

ERROR_CODES = (
    "bad_request",
    "claude_not_found",
    "claude_timeout",
    "claude_failed",
    "invalid_response",
    # A follow-up or section refresh names an explanation that is no longer cached,
    # or a section that the explanation no longer has.
    "explanation_missing",
    "internal",
)


class ProtocolError(Exception):
    """An inbound line is not a JSON object."""


def encode(message: dict[str, Any]) -> bytes:
    """Serialise one message as a single UTF-8 line."""
    return (json.dumps(message, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def decode(line: bytes) -> dict[str, Any]:
    """Parse one inbound line. Raises :class:`ProtocolError` if it is not an object."""
    try:
        value = json.loads(line.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ProtocolError(f"invalid JSON: {exc}") from exc
    if not isinstance(value, dict):
        raise ProtocolError("message must be a JSON object")
    return value


def error(request_id: str | None, code: str, message: str, *, retryable: bool = False,
          details: dict[str, Any] | None = None) -> dict[str, Any]:
    assert code in ERROR_CODES, code
    return {
        "type": "error",
        "id": request_id,
        "code": code,
        "message": message,
        "retryable": retryable,
        "details": details or {},
    }


def progress(request_id: str, phase: str, elapsed_ms: int, output_chars: int) -> dict[str, Any]:
    return {
        "type": "progress",
        "id": request_id,
        "phase": phase,
        "elapsed_ms": elapsed_ms,
        "output_chars": output_chars,
    }


def cancelled(request_id: str, reason: str) -> dict[str, Any]:
    return {"type": "cancelled", "id": request_id, "reason": reason}


def pong(claude: dict[str, Any] | None, claude_error: str | None) -> dict[str, Any]:
    return {
        "type": "pong",
        "protocol": PROTOCOL_VERSION,
        "engine_version": ENGINE_VERSION,
        "claude": claude,
        "claude_error": claude_error,
    }
