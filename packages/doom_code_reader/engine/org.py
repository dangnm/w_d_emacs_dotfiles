"""Explanations as Org-mode documents.

An explanation is one Org document. The same text is the cache entry on disk and
the text the reader's right pane shows, so each section can be folded and unfolded
with TAB. The layout is::

    #+TITLE: lisp/foo.el
    #+STARTUP: overview
    #+OPTIONS: ^:nil

    * Summary
      :PROPERTIES:
      :KIND: summary
      :END:
      What the file is for.

    * Lines 19–21 · Read the name
      :PROPERTIES:
      :KIND: section
      :SECTION_ID: 9f2c1a0e-s2
      :LINES: 19-21
      :END:
      What these lines do.

    ** Question: what is last_name?
       :PROPERTIES:
       :KIND: question
       :CREATED: 2026-11-22T10:00:00.000000+00:00
       :END:
       The answer.

    * Dependencies
      :PROPERTIES:
      :KIND: dependencies
      :END:
      - json

Body text is indented by two spaces, so text from the model can never start a
heading, a property drawer or a keyword. :func:`render` is the only writer of this
format and :func:`parse` the only reader, so the two stay in step.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any

INDENT = "  "

SUMMARY_KIND = "summary"
SECTION_KIND = "section"
QUESTION_KIND = "question"
# Group headings, in the order they are shown. Each holds a list of strings,
# except "warnings", which holds code and message pairs.
LIST_GROUPS = (("dependencies", "Dependencies"), ("data_flow", "Data flow"), ("notes", "Notes"))
WARNINGS_KIND = "warnings"
WARNINGS_TITLE = "Warnings"

_SECTION_HEADING = re.compile(r"^\* Lines \d+–\d+(?: · (.*))?$")
_QUESTION_HEADING = re.compile(r"^\*\* Question: (.*)$")
_LINES_VALUE = re.compile(r"^(\d+)-(\d+)$")
_PROPERTY = re.compile(r"^:([A-Za-z_][A-Za-z0-9_\-]*):(?: (.*))?$")
_WARNING_ITEM = re.compile(r"^\[([^\]]*)\] ?(.*)$")
_TITLE_KEYWORD = re.compile(r"^#\+TITLE: ?(.*)$")
_PROJECT_KEYWORD = re.compile(r"^#\+PROJECT: ?(.*)$")
_KEY_KEYWORD = re.compile(r"^#\+KEY: ?(.*)$")
_MODEL_KEYWORD = re.compile(r"^#\+MODEL: ?(.*)$")


class DocumentError(Exception):
    """The text is not an explanation document this module wrote."""


@dataclass
class Question:
    """One question asked about a section, and its answer."""

    question: str
    answer: str
    created_at: str


@dataclass
class Section:
    """One explained range of source lines, with the questions asked about it."""

    id: str
    source_start: int
    source_end: int
    title: str
    explanation: str
    followups: list[Question] = field(default_factory=list)
    refreshed_at: str | None = None


@dataclass
class Document:
    """A whole explanation: summary, sections in file order, and the lists."""

    file: str = ""
    # The project root, the cache key of this explanation (see engine/cache.py), and the
    # model it was made with ("default" for the CLI's own). The client checks the model
    # before it shows a saved explanation without asking the engine.
    project: str = ""
    key: str = ""
    model: str = ""
    summary: str = ""
    sections: list[Section] = field(default_factory=list)
    dependencies: list[str] = field(default_factory=list)
    data_flow: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    # Each warning is a dict with "code", "message" and "section_id" (always None here).
    warnings: list[dict[str, Any]] = field(default_factory=list)

    def find_section(self, start: int, end: int) -> Section | None:
        """Return the section that covers exactly the lines START..END, or None."""
        for section in self.sections:
            if section.source_start == start and section.source_end == end:
                return section
        return None


# -- writing -----------------------------------------------------------------


def _one_line(text: object) -> str:
    """Collapse text to one line, for headings, property values and list items."""
    return " ".join(str(text).split())


def _body(text: str) -> list[str]:
    """Indent free text so that no line of it can start a heading or a drawer."""
    lines = []
    for raw in str(text).replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        line = raw.rstrip()
        lines.append(INDENT + line if line else "")
    return lines


def _drawer(props: list[tuple[str, str]]) -> list[str]:
    return [INDENT + ":PROPERTIES:",
            *[f"{INDENT}:{key}: {_one_line(value)}" for key, value in props],
            INDENT + ":END:"]


def _render_section(section: Section) -> list[str]:
    heading = f"* Lines {section.source_start}–{section.source_end}"
    if section.title.strip():
        heading += f" · {_one_line(section.title)}"
    props = [("KIND", SECTION_KIND), ("SECTION_ID", section.id),
             ("LINES", f"{section.source_start}-{section.source_end}")]
    if section.refreshed_at:
        props.append(("REFRESHED", section.refreshed_at))
    lines = [heading, *_drawer(props), *_body(section.explanation), ""]
    for entry in section.followups:
        lines += [f"** Question: {_one_line(entry.question)}",
                  *_drawer([("KIND", QUESTION_KIND), ("CREATED", entry.created_at)]),
                  *_body(entry.answer), ""]
    return lines


def render(doc: Document) -> str:
    """Return the Org text of ``doc``. Empty groups are left out."""
    out: list[str] = [f"#+TITLE: {_one_line(doc.file) or 'Explanation'}"]
    if doc.project:
        out.append(f"#+PROJECT: {_one_line(doc.project)}")
    if doc.key:
        out.append(f"#+KEY: {_one_line(doc.key)}")
    if doc.model:
        out.append(f"#+MODEL: {_one_line(doc.model)}")
    out += ["#+STARTUP: overview", "#+OPTIONS: ^:nil", ""]
    if doc.summary.strip():
        out += ["* Summary", *_drawer([("KIND", SUMMARY_KIND)]), *_body(doc.summary), ""]
    for section in doc.sections:
        out += _render_section(section)
    for attr, title in LIST_GROUPS:
        items = getattr(doc, attr)
        if items:
            out += [f"* {title}", *_drawer([("KIND", attr)]),
                    *[f"{INDENT}- {_one_line(item)}" for item in items], ""]
    if doc.warnings:
        items = [f"[{_one_line(w.get('code') or 'warning')}] {_one_line(w.get('message') or '')}"
                 for w in doc.warnings]
        out += [f"* {WARNINGS_TITLE}", *_drawer([("KIND", WARNINGS_KIND)]),
                *[f"{INDENT}- {item}" for item in items], ""]
    return "\n".join(out).rstrip("\n") + "\n"


def document_from_payload(payload: dict[str, Any], *, file: str, project: str = "", key: str = "",
                          model: str = "") -> Document:
    """Build a :class:`Document` from a validated explanation payload (see ``normalize_output``)."""
    sections = [
        Section(
            id=entry["id"],
            source_start=entry["source_start"],
            source_end=entry["source_end"],
            title=entry["title"],
            explanation=entry["explanation"],
        )
        for entry in payload.get("sections", [])
    ]
    warnings = [
        {"code": str(entry.get("code") or "warning"), "message": str(entry.get("message") or ""),
         "section_id": None}
        for entry in payload.get("warnings", [])
    ]
    return Document(
        file=file,
        project=project,
        key=key,
        model=model,
        summary=str(payload.get("summary") or ""),
        sections=sections,
        dependencies=list(payload.get("dependencies", [])),
        data_flow=list(payload.get("data_flow", [])),
        notes=list(payload.get("notes", [])),
        warnings=warnings,
    )


# -- reading -----------------------------------------------------------------


@dataclass
class _Block:
    level: int
    heading: str
    lines: list[str]


def _split_drawer(lines: list[str]) -> tuple[dict[str, str], list[str]]:
    """Split a block's lines into its property drawer (if any) and its body."""
    index = 0
    while index < len(lines) and not lines[index].strip():
        index += 1
    if index >= len(lines) or lines[index].strip() != ":PROPERTIES:":
        return {}, lines
    props: dict[str, str] = {}
    end = index + 1
    while end < len(lines) and lines[end].strip() != ":END:":
        match = _PROPERTY.match(lines[end].strip())
        if match and match.group(2) is not None:
            props[match.group(1)] = match.group(2).strip()
        end += 1
    if end >= len(lines):
        raise DocumentError("a property drawer is not closed")
    return props, lines[end + 1:]


def _unindent(lines: list[str]) -> str:
    text = [line[len(INDENT):] if line.startswith(INDENT) else line for line in lines]
    return "\n".join(text).strip()


def _items(lines: list[str]) -> list[str]:
    items = []
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("- ") and stripped[2:].strip():
            items.append(stripped[2:].strip())
    return items


def _parse_warning(item: str) -> dict[str, Any]:
    match = _WARNING_ITEM.match(item)
    if match is None:
        return {"code": "warning", "message": item, "section_id": None}
    return {"code": match.group(1).strip() or "warning", "message": match.group(2).strip(),
            "section_id": None}


def _parse_section(heading: str, props: dict[str, str], body: list[str]) -> Section:
    title_match = _SECTION_HEADING.match(heading)
    lines_match = _LINES_VALUE.match(props.get("LINES", ""))
    section_id = props.get("SECTION_ID", "")
    if title_match is None or lines_match is None or not section_id:
        raise DocumentError("a section heading lacks its lines or id")
    return Section(
        id=section_id,
        source_start=int(lines_match.group(1)),
        source_end=int(lines_match.group(2)),
        title=(title_match.group(1) or "").strip(),
        explanation=_unindent(body),
        refreshed_at=props.get("REFRESHED") or None,
    )


def _read_header_keyword(line: str, doc: Document) -> None:
    """Fill in ``doc`` from one ``#+KEYWORD:`` line of the header, if it is one."""
    for pattern, attr in ((_TITLE_KEYWORD, "file"), (_PROJECT_KEYWORD, "project"), (_KEY_KEYWORD, "key"),
                          (_MODEL_KEYWORD, "model")):
        match = pattern.match(line)
        if match:
            setattr(doc, attr, match.group(1).strip())
            return


def parse(text: str) -> Document:
    """Read a document written by :func:`render`. Raises :class:`DocumentError` otherwise."""
    doc = Document()
    blocks: list[_Block] = []
    for line in text.replace("\r\n", "\n").split("\n"):
        if line.startswith("* ") or line.startswith("** "):
            blocks.append(_Block(level=1 if line.startswith("* ") else 2, heading=line, lines=[]))
        elif blocks:
            blocks[-1].lines.append(line)
        else:
            _read_header_keyword(line, doc)

    section: Section | None = None
    for block in blocks:
        props, body = _split_drawer(block.lines)
        kind = props.get("KIND")
        if block.level == 1:
            section = None
            if kind == SUMMARY_KIND:
                doc.summary = _unindent(body)
            elif kind == SECTION_KIND:
                section = _parse_section(block.heading, props, body)
                doc.sections.append(section)
            elif kind == WARNINGS_KIND:
                doc.warnings = [_parse_warning(item) for item in _items(body)]
            elif kind in {attr for attr, _ in LIST_GROUPS}:
                setattr(doc, kind, _items(body))
            else:
                raise DocumentError(f"unknown heading: {block.heading[:60]!r}")
        else:
            match = _QUESTION_HEADING.match(block.heading)
            if section is None or kind != QUESTION_KIND or match is None:
                raise DocumentError("a question is not under a section")
            section.followups.append(Question(
                question=match.group(1).strip(),
                answer=_unindent(body),
                created_at=props.get("CREATED", ""),
            ))
    return doc
