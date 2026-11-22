"""JSON Schema passed to ``claude --json-schema`` for structured explanations."""

from __future__ import annotations

_STRING_LIST = {"type": "array", "items": {"type": "string"}}

# One section's explanation, written again on its own (task "explain_section").
SECTION_EXPLANATION_SCHEMA: dict = {
    "type": "object",
    "properties": {"explanation": {"type": "string"}},
    "required": ["explanation"],
}

# Answer to a question about one section (task "follow_up").
FOLLOW_UP_SCHEMA: dict = {
    "type": "object",
    "properties": {"answer": {"type": "string"}},
    "required": ["answer"],
}

EXPLANATION_SCHEMA: dict = {
    "type": "object",
    "properties": {
        "summary": {"type": "string"},
        "sections": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "source_start": {"type": "integer"},
                    "source_end": {"type": "integer"},
                    "title": {"type": "string"},
                    "explanation": {"type": "string"},
                },
                "required": ["source_start", "source_end", "title", "explanation"],
            },
        },
        "dependencies": _STRING_LIST,
        "data_flow": _STRING_LIST,
        "notes": _STRING_LIST,
    },
    "required": ["summary", "sections"],
}
