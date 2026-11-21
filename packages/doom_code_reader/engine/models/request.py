"""Validation of incoming ``explain`` requests.

Everything the frontend sends is untrusted. This module turns a raw JSON
object into an :class:`ExplainRequest` or raises :class:`BadRequest`.
"""

from __future__ import annotations

import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from engine.config import (
    DEFAULT_TIMEOUT_S,
    MAX_CONTENT_BYTES,
    MAX_FILE_CHARS,
    MAX_TIMEOUT_S,
    MIN_TIMEOUT_S,
)

ALLOWED_TASKS = ("explain_file", "explain_block", "explain_function")
# explain_file always covers the whole file; the client's target is ignored.
WHOLE_FILE_TASK = "explain_file"
_MODEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-\[\]]{0,127}$")


class BadRequest(Exception):
    """The client sent something the engine refuses to process."""

    def __init__(self, message: str, *, request_id: str | None = None, details: dict | None = None):
        super().__init__(message)
        self.message = message
        self.request_id = request_id
        self.details = details or {}


@dataclass(frozen=True)
class Target:
    start_line: int
    end_line: int


@dataclass(frozen=True)
class ExplainRequest:
    id: str
    view: str
    task: str
    project_root: Path
    file: Path
    file_relpath: str
    language: str
    content: str
    target: Target
    point_line: int | None
    symbol: str | None
    explain_language: str
    use_cache: bool
    timeout: float
    model: str | None


def _require_str(msg: dict, key: str, *, max_len: int, allow_empty: bool = False) -> str:
    value = msg.get(key)
    if not isinstance(value, str):
        raise BadRequest(f"'{key}' must be a string")
    if not allow_empty and not value.strip():
        raise BadRequest(f"'{key}' must not be empty")
    if len(value) > max_len:
        raise BadRequest(f"'{key}' is too long")
    return value


def _require_int(value: Any, name: str) -> int:
    # bool is a subclass of int in Python; reject it explicitly.
    if isinstance(value, bool) or not isinstance(value, int):
        raise BadRequest(f"'{name}' must be an integer")
    return value


def _is_within(root: Path, path: Path) -> bool:
    try:
        return os.path.commonpath([str(root), str(path)]) == str(root)
    except ValueError:  # different drives or mixed absolute/relative
        return False


def parse_target(raw: Any, total_lines: int) -> Target:
    """Validate ``{"start_line": a, "end_line": b}`` against the snapshot size."""
    if not isinstance(raw, dict):
        raise BadRequest("'target' must be an object with start_line and end_line")
    start = _require_int(raw.get("start_line"), "target.start_line")
    end = _require_int(raw.get("end_line"), "target.end_line")
    if not (1 <= start <= end <= total_lines):
        raise BadRequest(
            f"target lines {start}-{end} are outside the source (1-{total_lines})",
            details={"total_lines": total_lines},
        )
    return Target(start_line=start, end_line=end)


def parse_explain(msg: dict) -> ExplainRequest:
    """Build an :class:`ExplainRequest` from a raw ``explain`` message."""
    request_id = msg.get("id") if isinstance(msg.get("id"), str) else None
    try:
        rid = _require_str(msg, "id", max_len=128)
        view = _require_str(msg, "view", max_len=4096)

        task = _require_str(msg, "task", max_len=64)
        if task not in ALLOWED_TASKS:
            raise BadRequest(f"unsupported task '{task}'")

        root_raw = _require_str(msg, "project_root", max_len=4096)
        file_raw = _require_str(msg, "file", max_len=4096)
        if not os.path.isabs(root_raw) or not os.path.isabs(file_raw):
            raise BadRequest("'project_root' and 'file' must be absolute paths")
        project_root = Path(os.path.realpath(root_raw))
        if not project_root.is_dir():
            raise BadRequest("'project_root' is not a directory")
        file_path = Path(os.path.realpath(file_raw))
        if not _is_within(project_root, file_path) or file_path == project_root:
            raise BadRequest("'file' must be inside 'project_root'", details={"reason": "file_outside_project"})

        language = _require_str(msg, "language", max_len=64, allow_empty=True) or "text"

        content = msg.get("content")
        if not isinstance(content, str):
            raise BadRequest("'content' must be a string")
        if len(content.encode("utf-8", errors="replace")) > MAX_CONTENT_BYTES:
            raise BadRequest("'content' is too large", details={"reason": "content_too_large"})
        total_lines = len(content.split("\n"))

        if task == WHOLE_FILE_TASK:
            if len(content) > MAX_FILE_CHARS:
                raise BadRequest(
                    "this file is too large to explain in one request; "
                    "explain a block or function instead",
                    details={"reason": "file_too_large", "chars": len(content), "limit": MAX_FILE_CHARS},
                )
            target = Target(start_line=1, end_line=total_lines)
        else:
            target = parse_target(msg.get("target"), total_lines)

        point_line = msg.get("point_line")
        if point_line is not None:
            point_line = _require_int(point_line, "point_line")
            if not (1 <= point_line <= total_lines):
                point_line = None

        symbol = msg.get("symbol")
        if symbol is not None:
            symbol = _require_str(msg, "symbol", max_len=256)

        explain_language = _require_str(msg, "explain_language", max_len=64)

        use_cache = msg.get("use_cache", True)
        if not isinstance(use_cache, bool):
            raise BadRequest("'use_cache' must be a boolean")

        timeout_raw = msg.get("timeout", DEFAULT_TIMEOUT_S)
        if isinstance(timeout_raw, bool) or not isinstance(timeout_raw, (int, float)):
            raise BadRequest("'timeout' must be a number")
        timeout = min(max(float(timeout_raw), MIN_TIMEOUT_S), MAX_TIMEOUT_S)

        model = msg.get("model")
        if model is not None:
            if not isinstance(model, str) or not _MODEL_RE.match(model):
                raise BadRequest("'model' has an invalid format")

        return ExplainRequest(
            id=rid,
            view=view,
            task=task,
            project_root=project_root,
            file=file_path,
            file_relpath=os.path.relpath(file_path, project_root),
            language=language,
            content=content,
            target=target,
            point_line=point_line,
            symbol=symbol,
            explain_language=explain_language,
            use_cache=use_cache,
            timeout=timeout,
            model=model,
        )
    except BadRequest as exc:
        if exc.request_id is None:
            exc.request_id = request_id
        raise
