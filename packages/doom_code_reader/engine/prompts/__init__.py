"""Prompt templates for each explanation task.

Templates live beside this file as Markdown. Placeholders use ``{{name}}``.
Rendering is a single regex pass, so values that contain braces (common in
source code) are never re-expanded.
"""

from __future__ import annotations

import hashlib
import re
from functools import lru_cache
from pathlib import Path

_PROMPT_DIR = Path(__file__).resolve().parent
_PLACEHOLDER = re.compile(r"\{\{([a-z_]+)\}\}")

TASK_TEMPLATES: dict[str, str] = {
    "explain_file": "explain_file.md",
    "explain_block": "explain_block.md",
    "explain_function": "explain_function.md",
    "follow_up": "follow_up.md",
    "follow_up_line": "follow_up_line.md",
    "explain_section": "explain_section.md",
    "explain_detail": "explain_detail.md",
}

TASK_TITLES: dict[str, str] = {
    "explain_file": "Explain file",
    "explain_block": "Explain block",
    "explain_function": "Explain function",
    "follow_up": "Follow-up question",
    "follow_up_line": "Follow-up question about a line",
    "explain_section": "Refresh section",
    "explain_detail": "Detail explanation",
}


class PromptError(Exception):
    """A template is missing a value or refers to an unknown placeholder."""


@lru_cache(maxsize=None)
def _read(name: str) -> str:
    return (_PROMPT_DIR / name).read_text(encoding="utf-8")


def render(template: str, values: dict[str, str]) -> str:
    """Substitute ``{{key}}`` placeholders in one pass.

    Extra keys in ``values`` are ignored, so one value set can feed every template.
    """

    def replace(match: re.Match[str]) -> str:
        key = match.group(1)
        if key not in values:
            raise PromptError(f"missing prompt value: {key}")
        return str(values[key])

    return _PLACEHOLDER.sub(replace, template)


def build_system_prompt(explain_language: str) -> str:
    """Read-only charter for every request, in the requested output language."""
    return render(_read("base_system.md"), {"explain_language": explain_language}).strip()


def build_user_prompt(task: str, values: dict[str, str]) -> str:
    """Task-specific user message. ``values`` must cover every placeholder."""
    if task not in TASK_TEMPLATES:
        raise PromptError(f"unknown task: {task}")
    return render(_read(TASK_TEMPLATES[task]), values).strip() + "\n"


def prompt_fingerprint(task: str) -> str:
    """Hash of the templates for ``task``. Changing a prompt invalidates the cache."""
    digest = hashlib.sha256()
    digest.update(_read("base_system.md").encode("utf-8"))
    digest.update(_read(TASK_TEMPLATES[task]).encode("utf-8"))
    return digest.hexdigest()
