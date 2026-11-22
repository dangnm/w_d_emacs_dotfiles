"""On-disk cache of explanation documents, laid out so that a person can browse it.

Layout::

    <cache>/<project name>-<6 hex of the project root>/<file path in the project>/
        <scope>-<language>-<8 key chars>.org

The scope is ``whole-file`` or ``lines-A-B``. The file name is short enough to
read, but a lookup checks the full key, which is the ``#+KEY:`` line of the
document (see :mod:`engine.org`). A name collision therefore cannot return the
wrong explanation.

A key covers everything that changes the answer, except the source text: task,
target, symbol, output language, model, project root, file and the prompt
fingerprint. The source text is left out on purpose, so an explanation stays until
it is regenerated. Editing a prompt template still invalidates old entries
automatically. Entries are written atomically (temp file plus rename).
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

SUFFIX = ".org"
# Entries written before the browsable layout are JSON or sit in hash-prefix folders.
# They are never read, and clear() removes them.
_LEGACY_SUFFIX = ".json"
_KEY_RE = re.compile(r"^[0-9a-f]{64}$")
_UNSAFE_NAME = re.compile(r"[^A-Za-z0-9._-]+")
_KEY_LINE_LIMIT = 10


def make_key(parts: dict[str, Any]) -> str:
    """Stable SHA-256 over a canonical JSON encoding of ``parts``."""
    canonical = json.dumps(parts, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def project_folder(project_root: str) -> str:
    """Return the folder name of a project: its directory name and a short hash of its path.

    The hash keeps two projects with the same directory name apart.
    """
    name = _UNSAFE_NAME.sub("-", os.path.basename(project_root.rstrip("/"))).strip("-.") or "project"
    digest = hashlib.sha256(project_root.encode("utf-8")).hexdigest()[:6]
    return f"{name}-{digest}"


def explanation_name(scope: str, language: str, key: str) -> str:
    """Return the file name of one explanation of a file."""
    safe_language = _UNSAFE_NAME.sub("-", language).strip("-") or "text"
    return f"{scope}-{safe_language}-{key[:8]}{SUFFIX}"


def _check_key(key: str) -> None:
    # The key becomes part of a file name, so only a well-formed key is accepted.
    if not _KEY_RE.fullmatch(key):
        raise ValueError("not a cache key")


class ExplanationCache:
    """Org documents, one file per explanation, under a folder for each project and file."""

    def __init__(self, root: Path) -> None:
        self._root = root

    def _folder(self, project_root: str, file_relpath: str) -> Path:
        return self._root / project_folder(project_root) / file_relpath

    def location(self, project_root: str, file_relpath: str, scope: str, language: str, key: str) -> Path:
        """Return the file that holds the explanation with KEY. The file need not exist yet."""
        _check_key(key)
        return self._folder(project_root, file_relpath) / explanation_name(scope, language, key)

    def locate(self, project_root: str, file_relpath: str, key: str) -> tuple[Path, str] | None:
        """Return the file and text of the explanation with KEY, or None when there is none."""
        _check_key(key)
        folder = self._folder(project_root, file_relpath)
        if not folder.is_dir():
            return None
        for path in sorted(folder.glob(f"*-{key[:8]}{SUFFIX}")):
            text = self._read(path)
            if text is not None and _has_key(text, key):
                return path, text
        return None

    def put(self, path: Path, text: str) -> None:
        """Write the document to PATH atomically, creating its folders."""
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=".tmp-", suffix=SUFFIX)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(text)
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
        return sum(1 for _ in self._root.rglob(f"*{SUFFIX}"))

    def clear(self) -> int:
        """Remove every explanation (and old-layout entry), then the folders left empty."""
        if not self._root.exists():
            return 0
        removed = 0
        for pattern in (f"*{SUFFIX}", f"*{_LEGACY_SUFFIX}"):
            for entry in self._root.rglob(pattern):
                try:
                    entry.unlink()
                    removed += 1
                except OSError:
                    log.warning("could not remove cache entry %s", entry.name)
        for directory, _dirs, _files in os.walk(self._root, topdown=False):
            if directory != str(self._root):
                try:
                    os.rmdir(directory)
                except OSError:
                    pass
        return removed

    @staticmethod
    def _read(path: Path) -> str | None:
        try:
            return path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return None
        except (OSError, UnicodeDecodeError):
            log.warning("discarding unreadable cache entry %s", path.name)
            return None


def _has_key(text: str, key: str) -> bool:
    """Return True when the document's header names KEY in full."""
    wanted = f"#+KEY: {key}"
    return any(line.strip() == wanted for line in text.splitlines()[:_KEY_LINE_LIMIT])
