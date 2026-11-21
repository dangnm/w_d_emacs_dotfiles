"""Per-project Claude session bookkeeping.

Each project root maps to one Claude Code session so follow-up explanations
reuse context instead of starting cold. The mapping is persisted as JSON so a
restarted engine can resume. Requests for the same project are serialised with
an ``asyncio.Lock`` because a session cannot be resumed by two processes at once.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)
_STORE_VERSION = 1


@dataclass(frozen=True)
class SessionRef:
    """Which session to pass to the CLI for the next call."""

    session_id: str
    resume: bool  # False: create with --session-id; True: continue with --resume


class SessionStore:
    """Thread-unsafe JSON store; only used from the engine's event loop."""

    def __init__(self, path: Path) -> None:
        self._path = path
        self._sessions: dict[str, dict[str, Any]] = {}
        self._locks: dict[str, asyncio.Lock] = {}
        self._load()

    # -- persistence -------------------------------------------------------

    def _load(self) -> None:
        try:
            data = json.loads(self._path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return
        if isinstance(data, dict) and data.get("version") == _STORE_VERSION:
            sessions = data.get("sessions")
            if isinstance(sessions, dict):
                self._sessions = {
                    k: v for k, v in sessions.items() if isinstance(v, dict) and isinstance(v.get("session_id"), str)
                }

    def _save(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps({"version": _STORE_VERSION, "sessions": self._sessions}, indent=2)
        fd, tmp = tempfile.mkstemp(dir=str(self._path.parent), prefix=".sessions-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(payload)
            os.replace(tmp, self._path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    # -- queries -----------------------------------------------------------

    def lock_for(self, project_root: str) -> asyncio.Lock:
        """Return the per-project lock, creating it on first use."""
        lock = self._locks.get(project_root)
        if lock is None:
            lock = asyncio.Lock()
            self._locks[project_root] = lock
        return lock

    def ensure(self, project_root: str, language: str | None = None) -> SessionRef:
        """Return the session for the next call, persisting a new id if needed.

        A session written in one explanation language is not resumed in another:
        the earlier answers would pull the model back into that language. So a
        language change starts a new session.

        Persisting before the call means a retry after a partial failure reuses
        the same id, so the CLI reports "already in use" and we resume instead of
        orphaning a session.
        """
        record = self._sessions.get(project_root)
        if record is None or record.get("language") != language:
            self.set_fresh(project_root, str(uuid.uuid4()), language)
            record = self._sessions[project_root]
        return SessionRef(session_id=record["session_id"], resume=bool(record.get("started")))

    def snapshot(self) -> list[dict[str, Any]]:
        return [
            {"project_root": root, "session_id": rec["session_id"], "started": bool(rec.get("started")),
             "language": rec.get("language")}
            for root, rec in sorted(self._sessions.items())
        ]

    # -- mutations ---------------------------------------------------------

    def mark_started(self, project_root: str, session_id: str, language: str | None = None) -> None:
        """Record that the CLI has created (or resumed) ``session_id``."""
        self._sessions[project_root] = {
            "session_id": session_id,
            "started": True,
            "language": language,
            "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        self._save()

    def set_fresh(self, project_root: str, session_id: str, language: str | None = None) -> None:
        """Use ``session_id`` for the next call and create it with ``--session-id``."""
        self._sessions[project_root] = {
            "session_id": session_id,
            "started": False,
            "language": language,
            "updated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        self._save()

    def reset(self, project_root: str) -> bool:
        """Forget the session for a project. Returns whether one existed."""
        existed = self._sessions.pop(project_root, None) is not None
        if existed:
            self._save()
        return existed
