"""Static configuration and limits shared by every engine module."""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

ENGINE_VERSION = "0.3.0"
PROTOCOL_VERSION = 1

# Limits. Keep prompts small: the spec forbids loading the whole codebase.
MAX_CONTENT_BYTES = 2 * 1024 * 1024
# A whole file is sent for explain_file. Larger files get a clear error instead.
MAX_FILE_CHARS = 300_000
MAX_SNIPPET_CHARS = 60_000
FULL_FILE_MAX_LINES = 400
WINDOW_MAX_LINES = 600
DEFAULT_TIMEOUT_S = 180.0
MIN_TIMEOUT_S = 5.0
MAX_TIMEOUT_S = 900.0
MAX_SECTIONS_TEXT_CHARS = 4000
PROGRESS_INTERVAL_S = 0.5
# A detail explanation is asked for this many lines at a time, and this many calls run at once.
DETAIL_CHUNK_LINES = 40
DETAIL_CONCURRENCY = 3
# asyncio stream limit for claude stdout lines (stream-json lines can be large).
STREAM_LINE_LIMIT = 32 * 1024 * 1024

READ_ONLY_TOOLS = ("Read", "Grep", "Glob")
DENIED_TOOLS = ("Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch")


@dataclass(frozen=True)
class EngineConfig:
    """Runtime settings, populated from command-line arguments."""

    socket_path: Path
    state_dir: Path
    claude_bin: str | None = None
    drop_env: tuple[str, ...] = ()
    idle_timeout_s: float = 1800.0
    max_budget_usd: float = 1.0
    claude_model: str | None = None
    # Reasoning effort for each call. "low" is several times faster and cheaper
    # for explanations, which are read-only and do not need long reasoning.
    claude_effort: str | None = "low"
    extra: dict[str, str] = field(default_factory=dict)

    @property
    def cache_dir(self) -> Path:
        return self.state_dir / "cache"

    @property
    def sessions_file(self) -> Path:
        return self.state_dir / "sessions.json"

    @property
    def log_file(self) -> Path:
        return self.state_dir / "engine.log"
