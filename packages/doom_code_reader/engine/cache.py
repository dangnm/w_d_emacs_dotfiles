"""On-disk cache of validated explanations.

A key covers everything that changes the answer: snapshot hash, task, target,
symbol, output language, model, project root, and the prompt fingerprint. Editing
a prompt template therefore invalidates old entries automatically. Entries are
written atomically (temp file plus rename).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)
CACHE_SCHEMA = 1


def make_key(parts: dict[str, Any]) -> str:
    """Stable SHA-256 over a canonical JSON encoding of ``parts``."""
    canonical = json.dumps(parts, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


class ExplanationCache:
    def __init__(self, root: Path) -> None:
        self._root = root

    def _path(self, key: str) -> Path:
        return self._root / key[:2] / f"{key}.json"

    def get(self, key: str) -> dict[str, Any] | None:
        path = self._path(key)
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, json.JSONDecodeError):
            log.warning("discarding unreadable cache entry %s", key[:12])
            return None
        if not isinstance(data, dict) or data.get("schema") != CACHE_SCHEMA:
            return None
        payload = data.get("payload")
        return payload if isinstance(payload, dict) else None

    def put(self, key: str, payload: dict[str, Any]) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        body = json.dumps({"schema": CACHE_SCHEMA, "payload": payload}, ensure_ascii=False)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=".json")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(body)
            os.replace(tmp, path)
        except OSError:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def count(self) -> int:
        if not self._root.exists():
            return 0
        return sum(1 for _ in self._root.glob("*/*.json"))

    def clear(self) -> int:
        if not self._root.exists():
            return 0
        removed = 0
        for entry in self._root.glob("*/*.json"):
            try:
                entry.unlink()
                removed += 1
            except OSError:
                log.warning("could not remove cache entry %s", entry.name)
        return removed
