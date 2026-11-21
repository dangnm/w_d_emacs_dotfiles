"""Shared fixtures for the engine test suite."""

from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from engine.config import EngineConfig

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FAKE_CLAUDE = FIXTURES / "fake_claude.py"

SAMPLE_SOURCE = "\n".join(
    [
        "(defun greet (name)",
        '  "Say hello."',
        "  (message \"Hello %s\" name))",
        "",
        "(defun add (a b)",
        "  (+ a b))",
        "",
    ]
)


def make_config(state_dir: Path, *, claude_bin: str | None = str(FAKE_CLAUDE), **overrides: Any) -> EngineConfig:
    values: dict[str, Any] = {
        "socket_path": state_dir / "engine.sock",
        "state_dir": state_dir,
        "claude_bin": claude_bin,
        "drop_env": (),
        "idle_timeout_s": 1800.0,
        "max_budget_usd": 0.5,
    }
    values.update(overrides)
    return EngineConfig(**values)


def make_project(root: Path) -> Path:
    """Create a small project with one source file. Returns the file path."""
    (root / "lisp").mkdir(parents=True, exist_ok=True)
    source = root / "lisp" / "sample.el"
    source.write_text(SAMPLE_SOURCE, encoding="utf-8")
    return source


def explain_message(
    project_root: Path,
    source_file: Path,
    *,
    request_id: str = "r-1",
    view: str | None = None,
    task: str = "explain_file",
    content: str | None = None,
    target: tuple[int, int] = (1, 1),
    **overrides: Any,
) -> dict[str, Any]:
    text = content if content is not None else source_file.read_text(encoding="utf-8")
    message: dict[str, Any] = {
        "type": "explain",
        "id": request_id,
        "view": view or str(source_file),
        "task": task,
        "project_root": str(project_root),
        "file": str(source_file),
        "language": "emacs-lisp",
        "content": text,
        "target": {"start_line": target[0], "end_line": target[1]},
        "point_line": target[0],
        "symbol": "greet",
        "explain_language": "Vietnamese",
        "use_cache": True,
        "timeout": 30,
        "model": None,
    }
    message.update(overrides)
    return message


def fake_env(state_file: Path | None = None, argv_log: Path | None = None, mode: str = "ok",
             sleep: float | None = None) -> dict[str, str]:
    """Environment variables that control FAKE_CLAUDE behaviour."""
    env = {"FAKE_CLAUDE_MODE": mode}
    if state_file is not None:
        env["FAKE_CLAUDE_STATE"] = str(state_file)
    if argv_log is not None:
        env["FAKE_CLAUDE_ARGV_LOG"] = str(argv_log)
    if sleep is not None:
        env["FAKE_CLAUDE_SLEEP"] = str(sleep)
    return env


class EnvPatch:
    """Context manager that sets environment variables and restores them afterwards."""

    def __init__(self, values: dict[str, str]) -> None:
        self._values = values
        self._saved: dict[str, str | None] = {}

    def __enter__(self) -> "EnvPatch":
        for key, value in self._values.items():
            self._saved[key] = os.environ.get(key)
            os.environ[key] = value
        return self

    def __exit__(self, *exc: object) -> None:
        for key, old in self._saved.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old


class Collector:
    """Async ``emit`` replacement that records every message."""

    def __init__(self) -> None:
        self.messages: list[dict[str, Any]] = []

    async def __call__(self, message: dict[str, Any]) -> None:
        self.messages.append(message)

    def of_type(self, kind: str) -> list[dict[str, Any]]:
        return [m for m in self.messages if m.get("type") == kind]
