"""Turn Claude's structured output into a validated explanation payload.

The model's line numbers are never trusted. Every section is checked against
the real snapshot size and the requested target. Invalid sections are dropped
and reported in ``warnings`` so the frontend can show what happened.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any

from engine.config import MAX_SECTIONS_TEXT_CHARS
from engine.models.request import Target

_FENCE_RE = re.compile(r"^```(?:json)?\s*(.*?)\s*```$", re.DOTALL)
_LIST_ITEM_LIMIT = 30


class InvalidResponse(Exception):
    """Claude's output does not have the expected top-level shape."""


@dataclass
class ExplanationPayload:
    """Validated explanation, independent of any one request."""

    summary: str
    sections: list[dict[str, Any]]
    dependencies: list[str] = field(default_factory=list)
    data_flow: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    warnings: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "summary": self.summary,
            "sections": self.sections,
            "dependencies": self.dependencies,
            "data_flow": self.data_flow,
            "notes": self.notes,
            "warnings": self.warnings,
        }


def parse_structured(structured: Any, result_text: str | None) -> dict[str, Any]:
    """Prefer ``structured_output``; fall back to parsing the result text as JSON."""
    if isinstance(structured, dict):
        return structured
    if not isinstance(result_text, str) or not result_text.strip():
        raise InvalidResponse("the model returned no structured output")
    text = result_text.strip()
    fence = _FENCE_RE.match(text)
    if fence:
        text = fence.group(1)
    try:
        value = json.loads(text)
    except json.JSONDecodeError as exc:
        raise InvalidResponse(f"the model output is not valid JSON: {exc.msg}") from exc
    if not isinstance(value, dict):
        raise InvalidResponse("the model output is not a JSON object")
    return value


def _string_list(raw: Any, warnings: list[dict[str, Any]], name: str) -> list[str]:
    if raw is None:
        return []
    if not isinstance(raw, list):
        warnings.append(_warning("invalid_section", f"'{name}' was not a list and was ignored"))
        return []
    items: list[str] = []
    for entry in raw[:_LIST_ITEM_LIMIT]:
        if isinstance(entry, str) and entry.strip():
            items.append(entry.strip()[:MAX_SECTIONS_TEXT_CHARS])
    return items


def _warning(code: str, message: str, section_id: str | None = None) -> dict[str, Any]:
    return {"code": code, "message": message, "section_id": section_id}


def _is_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def normalize_output(
    raw: dict[str, Any],
    *,
    total_lines: int,
    target: Target,
    snapshot_hash: str,
) -> ExplanationPayload:
    """Validate and normalise a parsed structured-output object.

    Raises :class:`InvalidResponse` only when the top-level shape is unusable.
    """
    summary = raw.get("summary")
    if not isinstance(summary, str):
        raise InvalidResponse("'summary' must be a string")
    raw_sections = raw.get("sections")
    if not isinstance(raw_sections, list):
        raise InvalidResponse("'sections' must be a list")

    warnings: list[dict[str, Any]] = []
    valid: list[dict[str, Any]] = []

    for index, entry in enumerate(raw_sections, start=1):
        label = f"section {index}"
        if not isinstance(entry, dict):
            warnings.append(_warning("invalid_section", f"{label} is not an object and was dropped"))
            continue
        start = entry.get("source_start")
        end = entry.get("source_end")
        if not (_is_int(start) and _is_int(end)):
            warnings.append(_warning("invalid_section", f"{label} has non-integer line numbers and was dropped"))
            continue
        if not (1 <= start <= end <= total_lines):
            warnings.append(
                _warning(
                    "range_out_of_bounds",
                    f"{label} points to lines {start}-{end}, outside 1-{total_lines}; dropped",
                )
            )
            continue
        title = entry.get("title")
        explanation = entry.get("explanation")
        if not isinstance(title, str) or not isinstance(explanation, str):
            warnings.append(_warning("invalid_section", f"{label} is missing a title or explanation; dropped"))
            continue
        title = title.strip()[:300] or f"Lines {start}-{end}"
        explanation = explanation.strip()[:MAX_SECTIONS_TEXT_CHARS]
        valid.append(
            {
                "source_start": start,
                "source_end": end,
                "title": title,
                "explanation": explanation,
            }
        )

    valid.sort(key=lambda s: (s["source_start"], s["source_end"]))

    # Sections may overlap (layered explanations) and may fall outside the target
    # (context the prompt asked for). Neither is an error, so neither is reported.
    sections: list[dict[str, Any]] = []
    for number, section in enumerate(valid, start=1):
        section_id = f"{snapshot_hash[:8]}-s{number}"
        sections.append({"id": section_id, **section})
        if not section["explanation"]:
            warnings.append(_warning("empty_explanation", f"section '{section['title']}' has no explanation", section_id))

    if not sections:
        warnings.append(_warning("no_valid_sections", "no section passed validation"))

    return ExplanationPayload(
        summary=summary.strip()[:MAX_SECTIONS_TEXT_CHARS],
        sections=sections,
        dependencies=_string_list(raw.get("dependencies"), warnings, "dependencies"),
        data_flow=_string_list(raw.get("data_flow"), warnings, "data_flow"),
        notes=_string_list(raw.get("notes"), warnings, "notes"),
        warnings=warnings,
    )
