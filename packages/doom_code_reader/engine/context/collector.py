"""Build the minimum useful source context for one explanation request.

Phase 1 uses only the buffer snapshot the frontend sent. The window is the
target plus a little surrounding code. Small files are sent whole. Claude can
read other files through its read-only tools, so the whole codebase is never
loaded into one request.

Line splitting uses ``split("\\n")`` so numbering matches Emacs
``line-number-at-pos``. ``str.splitlines`` is deliberately not used, because it
also breaks on characters such as form feed, which Emacs does not treat as line
boundaries.
"""

from __future__ import annotations

import hashlib
from dataclasses import dataclass

from engine.config import (
    FULL_FILE_MAX_LINES,
    MAX_SNIPPET_CHARS,
    WINDOW_MAX_LINES,
)
from engine.models.request import WHOLE_FILE_TASK, ExplainRequest, Target

_PADDING = {"explain_block": 20, "explain_function": 15}
_LINE_PREFIX_WIDTH = 7  # "%6d| " rendering overhead, used for the size budget


@dataclass(frozen=True)
class ContextPackage:
    """Everything the prompt builder needs about the source snapshot."""

    snapshot_hash: str
    total_lines: int
    window_start: int
    window_end: int
    target: Target
    point_line: int | None
    symbol: str | None
    file_relpath: str
    language: str
    numbered_snippet: str
    truncated: bool


def snapshot_hash(content: str) -> str:
    """Full SHA-256 of the snapshot text (hex)."""
    return hashlib.sha256(content.encode("utf-8", errors="surrogatepass")).hexdigest()


def split_lines(content: str) -> list[str]:
    """Split like Emacs counts lines: every ``\\n`` starts a new line."""
    return content.split("\n")


def render_numbered(lines: list[str], start: int, end: int) -> str:
    """Render lines ``start..end`` (1-based, inclusive) with absolute numbers."""
    return "\n".join(f"{number:>6}| {lines[number - 1]}" for number in range(start, end + 1))


def _window_bounds(total: int, target: Target, padding: int) -> tuple[int, int, bool]:
    """Pick the window around ``target``. Returns (start, end, truncated)."""
    if total <= FULL_FILE_MAX_LINES:
        return 1, total, False

    start = max(1, target.start_line - padding)
    end = min(total, target.end_line + padding)
    truncated = False

    size = end - start + 1
    if size > WINDOW_MAX_LINES:
        excess = size - WINDOW_MAX_LINES
        cut_before = min(target.start_line - start, excess // 2)
        start += cut_before
        excess -= cut_before
        cut_after = min(end - target.end_line, excess)
        end -= cut_after
        truncated = True

    if end - start + 1 > WINDOW_MAX_LINES:  # the target itself is huge
        end = start + WINDOW_MAX_LINES - 1
        truncated = True

    return start, end, truncated


def _fit_budget(lines: list[str], start: int, end: int, target: Target) -> tuple[int, int, bool]:
    """Shrink the window (never the target) until it fits the character budget."""
    def cost(lo: int, hi: int) -> int:
        return sum(len(lines[n - 1]) + _LINE_PREFIX_WIDTH for n in range(lo, hi + 1))

    truncated = False
    while cost(start, end) > MAX_SNIPPET_CHARS:
        truncated = True
        outside_before = target.start_line - start
        outside_after = end - target.end_line
        if outside_before <= 0 and outside_after <= 0:
            # Only the target is left and it is still too big: cut its tail.
            end -= 1
            if end < start:
                break
            continue
        if outside_before >= outside_after:
            start += 1
        else:
            end -= 1
    return start, end, truncated


def collect_context(request: ExplainRequest) -> ContextPackage:
    """Build the context package for ``request``."""
    lines = split_lines(request.content)
    total = len(lines)
    target = request.target
    padding = _PADDING.get(request.task, 20)

    if request.task == WHOLE_FILE_TASK:
        # The whole file is the context. Its size was checked when the request was parsed.
        start, end, truncated_window, truncated_budget = 1, total, False, False
    else:
        start, end, truncated_window = _window_bounds(total, target, padding)
        start, end, truncated_budget = _fit_budget(lines, start, end, target)

    return ContextPackage(
        snapshot_hash=snapshot_hash(request.content),
        total_lines=total,
        window_start=start,
        window_end=end,
        target=target,
        point_line=request.point_line,
        symbol=request.symbol,
        file_relpath=request.file_relpath,
        language=request.language,
        numbered_snippet=render_numbered(lines, start, end),
        truncated=truncated_window or truncated_budget,
    )
