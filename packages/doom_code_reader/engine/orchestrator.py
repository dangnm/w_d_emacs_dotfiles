"""Explain-request pipeline: validate, cache, build context, call Claude, validate output.

The orchestrator is transport-agnostic. It receives an ``emit`` coroutine and
never touches sockets, so the same code is exercised by unit tests and by the
server.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Any

from engine import protocol
from engine.cache import ExplanationCache, make_key
from datetime import datetime, timezone

from engine.claude.cli import build_argv, build_env, dump_schema, locate_claude, run_claude
from engine.claude.session import SessionRef, SessionStore
from engine.config import DETAIL_CHUNK_LINES, DETAIL_CONCURRENCY, ENGINE_VERSION, PROGRESS_INTERVAL_S, EngineConfig
from engine.context.collector import ContextPackage, collect_context, split_lines
from engine.models.request import (
    DELETE_QUESTION_TASK,
    DETAIL_SECTION_TASK,
    DETAIL_TASK,
    FOLLOW_UP_LINE_TASK,
    FOLLOW_UP_TASK,
    SECTION_TASK,
    WHOLE_FILE_TASK,
    BadRequest,
    ExplainRequest,
    Target,
    parse_explain,
)
from engine.models.response import (
    InvalidResponse,
    detail_fingerprint,
    normalize_answer,
    normalize_detail,
    normalize_output,
    normalize_section_explanation,
    parse_structured,
)
from engine.models.schema import DETAIL_SCHEMA, EXPLANATION_SCHEMA, FOLLOW_UP_SCHEMA, SECTION_EXPLANATION_SCHEMA
from engine.org import Document, DocumentError, DetailLine, Question, Section, code_text, document_from_payload
from engine.org import parse as parse_document
from engine.org import render as render_document
from engine.prompts import build_system_prompt, build_user_prompt, prompt_fingerprint
from engine.requests import REASON_CLIENT, DuplicateRequest, RequestRegistry

log = logging.getLogger(__name__)

Emit = Callable[[dict[str, Any]], Awaitable[None]]

# Bump when the context-building rules change so stale cache entries are ignored.
CONTEXT_VERSION = 1
_MAX_ATTEMPTS = 3


class EngineError(Exception):
    """A failure that should be reported to the client as an ``error`` event."""

    def __init__(self, code: str, message: str, *, retryable: bool = False,
                 details: dict[str, Any] | None = None) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.details = details or {}


@dataclass
class _CallResult:
    structured: dict[str, Any]
    session_id: str | None
    resumed: bool
    cost_usd: float | None
    duration_ms: int


class Orchestrator:
    def __init__(
        self,
        config: EngineConfig,
        sessions: SessionStore,
        cache: ExplanationCache,
        registry: RequestRegistry,
    ) -> None:
        self._config = config
        self._sessions = sessions
        self._cache = cache
        self._registry = registry
        self._env = build_env(dict(os.environ), config.drop_env)

    # -- entry points ------------------------------------------------------

    def accept_explain(self, raw: dict[str, Any], owner: object) -> ExplainRequest | dict[str, Any]:
        """Validate and register a request synchronously, before any task is created.

        Registering here (not inside the task) means a ``cancel`` or a newer
        request for the same view that arrives right after this call is always
        seen. Returns either the accepted request or an ``error`` message.
        """
        request_id = raw.get("id") if isinstance(raw.get("id"), str) else None
        try:
            req = parse_explain(raw)
        except BadRequest as exc:
            return protocol.error(exc.request_id or request_id, "bad_request", exc.message, details=exc.details)
        try:
            self._registry.register(req.id, req.view, req.task, owner)
        except DuplicateRequest:
            return protocol.error(req.id, "bad_request", "request id is already in use")
        return req

    async def run_explain(self, req: ExplainRequest, emit: Emit) -> None:
        """Run an accepted request. Never raises except CancelledError."""
        self._registry.attach(req.id, asyncio.current_task())  # type: ignore[arg-type]
        try:
            reason = self._registry.cancel_reason(req.id)
            if reason is not None:
                # Cancelled (or superseded) before it started running.
                await _safe_emit(emit, protocol.cancelled(req.id, reason))
                return
            await self._run(req, emit)
        except asyncio.CancelledError:
            reason = self._registry.cancel_reason(req.id) or REASON_CLIENT
            log.info("request %s cancelled (%s)", req.id, reason)
            await _safe_emit(emit, protocol.cancelled(req.id, reason))
            raise
        except EngineError as exc:
            log.info("request %s failed: %s", req.id, exc.code)
            await _safe_emit(emit, protocol.error(req.id, exc.code, exc.message, retryable=exc.retryable,
                                                 details=exc.details))
        except Exception:  # noqa: BLE001 - report instead of killing the connection
            log.exception("internal error while handling request %s", req.id)
            await _safe_emit(emit, protocol.error(req.id, "internal",
                                                 "internal engine error; see engine.log", retryable=False))
        finally:
            self._registry.finish(req.id)

    async def handle_explain(self, raw: dict[str, Any], emit: Emit, owner: object) -> None:
        """Accept and run one request in the current task (used by tests and simple callers)."""
        accepted = self.accept_explain(raw, owner)
        if isinstance(accepted, dict):
            await _safe_emit(emit, accepted)
            return
        await self.run_explain(accepted, emit)

    def handle_cancel(self, raw: dict[str, Any]) -> dict[str, Any]:
        request_id = raw.get("id")
        active = isinstance(request_id, str) and self._registry.cancel(request_id, REASON_CLIENT)
        return {"type": "cancel_ack", "id": request_id, "active": bool(active)}

    def handle_reset_session(self, raw: dict[str, Any]) -> dict[str, Any]:
        root = raw.get("project_root")
        if not isinstance(root, str) or not os.path.isabs(root):
            return protocol.error(None, "bad_request", "'project_root' must be an absolute path")
        normalized = os.path.realpath(root)
        had = self._sessions.reset(normalized)
        return {"type": "session_reset", "project_root": normalized, "had_session": had}

    def handle_clear_cache(self) -> dict[str, Any]:
        return {"type": "cache_cleared", "removed": self._cache.clear()}

    def status(self) -> dict[str, Any]:
        return {
            "type": "status",
            "engine_version": ENGINE_VERSION,
            "active": self._registry.snapshot(),
            "sessions": self._sessions.snapshot(),
            "cache_entries": self._cache.count(),
        }

    # -- pipeline ----------------------------------------------------------

    async def _run(self, req: ExplainRequest, emit: Emit) -> None:
        if req.task in (FOLLOW_UP_TASK, FOLLOW_UP_LINE_TASK):
            await self._run_follow_up(req, emit)
            return
        if req.task == SECTION_TASK:
            await self._run_section_refresh(req, emit)
            return
        if req.task == DELETE_QUESTION_TASK:
            await self._run_delete_question(req, emit)
            return
        if req.task in (DETAIL_TASK, DETAIL_SECTION_TASK):
            await self._run_detail(req, emit)
            return
        started = time.monotonic()
        await emit(protocol.progress(req.id, "building_context", 0, 0))
        ctx = collect_context(req)

        system_prompt = build_system_prompt(req.explain_language)
        user_prompt = build_user_prompt(req.task, _prompt_values(req, ctx))
        model = req.model or self._config.claude_model
        # The source text is deliberately not part of the key: an explanation stays
        # until it is regenerated (use_cache false), even after the file is edited.
        key = make_key(
            {
                "context_version": CONTEXT_VERSION,
                "task": req.task,
                # A whole-file explanation is keyed by "the whole file", not by its line
                # count, so an edit that adds lines keeps the cached explanation.
                "target": (["whole_file"] if req.task == WHOLE_FILE_TASK
                           else [req.target.start_line, req.target.end_line]),
                "symbol": req.symbol,
                "explain_language": req.explain_language,
                "model": model,
                "project_root": str(req.project_root),
                "file": req.file_relpath,
                "prompt": prompt_fingerprint(req.task),
            }
        )

        if req.use_cache:
            stored = self._load(req, key)
            if stored is not None:
                log.info("request %s served from cache", req.id)
                path, text, doc = stored
                await emit(self._result_message(req, ctx, key, path, text, doc, cache_hit=True, session_id=None,
                                                cost_usd=None, duration_ms=0))
                return

        claude_path = locate_claude(self._config.claude_bin)
        if claude_path is None:
            raise EngineError("claude_not_found", "the Claude Code CLI could not be found", retryable=False)

        lock = self._sessions.lock_for(str(req.project_root))
        if lock.locked():
            self._registry.set_phase(req.id, "queued")
            await emit(protocol.progress(req.id, "queued", _elapsed(started), 0))
        async with lock:
            self._registry.set_phase(req.id, "running")
            call = await self._call_with_progress(req, ctx, system_prompt, user_prompt, model, claude_path,
                                                  emit, started)

        self._registry.set_phase(req.id, "validating")
        await emit(protocol.progress(req.id, "validating", _elapsed(started), 0))
        try:
            payload = normalize_output(
                call.structured,
                total_lines=ctx.total_lines,
                target=req.target,
                snapshot_hash=ctx.snapshot_hash,
            )
        except InvalidResponse as exc:
            raise EngineError("invalid_response", str(exc), retryable=True) from exc

        # The client reads the model from this header to decide whether a saved
        # explanation matches its settings, so it is the request's model, not the CLI's.
        doc = document_from_payload(payload.to_dict(), file=req.file_relpath,
                                    project=str(req.project_root), key=key,
                                    model=req.model or "default")
        if ctx.truncated:
            doc.warnings.append({
                "code": "context_truncated",
                "message": "the source context was trimmed to fit; some surrounding code is not shown",
                "section_id": None,
            })
        # A full refresh keeps the questions the reader asked before it, as the
        # sections they belong to. The file is read again here, after the call, so
        # a question added while Claude was working is kept too.
        previous = self._load(req, key)
        if previous is not None:
            _carry_questions(previous[2], doc, split_lines(req.content))
            _carry_details(previous[2], doc, split_lines(req.content))
        text = render_document(doc)
        path = self._cache.location(str(req.project_root), req.file_relpath,
                                    _scope(req), req.explain_language, key)
        if doc.sections:
            self._cache.put(path, text)
        await emit(self._result_message(req, ctx, key, path if path.exists() else None, text, doc,
                                        cache_hit=False, session_id=call.session_id,
                                        session_resumed=call.resumed, cost_usd=call.cost_usd,
                                        duration_ms=call.duration_ms))

    def _load(self, req: ExplainRequest, key: str) -> tuple[Path, str, Document] | None:
        """Return the file, its Org text and the parsed document for KEY, or None."""
        found = self._cache.locate(str(req.project_root), req.file_relpath, key)
        if found is None:
            return None
        path, text = found
        try:
            return path, text, parse_document(text)
        except DocumentError:
            log.warning("discarding unreadable explanation %s", key[:12])
            return None

    def _locate_section(self, req: ExplainRequest) -> tuple[Path, str, Document, Section]:
        """Return the stored explanation that a follow-up or refresh changes, and its section.

        Raises ``explanation_missing`` when the explanation is no longer cached
        (for example after ``clear_cache``) or no longer has that section.
        """
        stored = self._load(req, req.explanation_key or "")
        if stored is None:
            raise EngineError("explanation_missing",
                              "this explanation is no longer cached; press g to explain the file again")
        path, text, doc = stored
        section = doc.find_section(req.target.start_line, req.target.end_line)
        if section is None:
            raise EngineError("explanation_missing",
                              "that section is no longer in the explanation; press g to explain the file again")
        return path, text, doc, section

    def _edit_section(self, req: ExplainRequest,
                      change: Callable[[Section], None]) -> tuple[Path, str, Document, Section]:
        """Apply CHANGE to the section of the stored explanation, and store the result."""
        path, _text, doc, section = self._locate_section(req)
        change(section)
        text = render_document(doc)
        self._cache.put(path, text)
        return path, text, doc, section

    async def _ask_model(self, req: ExplainRequest, emit: Emit, task: str,
                         schema: dict[str, Any],
                         extra: dict[str, str] | None = None) -> tuple[ContextPackage, _CallResult]:
        """Run one model call for a section-level task: a question or a section refresh.

        These calls are never served from the explanation cache. They share the
        project's Claude session for the language, so they can use the explanation
        already given. EXTRA holds prompt values that only this task has.
        """
        started = time.monotonic()
        await emit(protocol.progress(req.id, "building_context", 0, 0))
        ctx = collect_context(req)
        system_prompt = build_system_prompt(req.explain_language)
        values = _prompt_values(req, ctx)
        values.update(extra or {})
        user_prompt = build_user_prompt(task, values)
        model = req.model or self._config.claude_model
        claude_path = locate_claude(self._config.claude_bin)
        if claude_path is None:
            raise EngineError("claude_not_found", "the Claude Code CLI could not be found", retryable=False)

        lock = self._sessions.lock_for(str(req.project_root))
        if lock.locked():
            self._registry.set_phase(req.id, "queued")
            await emit(protocol.progress(req.id, "queued", _elapsed(started), 0))
        async with lock:
            self._registry.set_phase(req.id, "running")
            call = await self._call_with_progress(req, ctx, system_prompt, user_prompt, model, claude_path,
                                                  emit, started, schema=schema)

        self._registry.set_phase(req.id, "validating")
        await emit(protocol.progress(req.id, "validating", _elapsed(started), 0))
        return ctx, call

    async def _run_follow_up(self, req: ExplainRequest, emit: Emit) -> None:
        """Answer one question about a section, or about one line of it, and store the answer.

        A question about the section is written after the section's detail explanation. A
        question about a line is written under that line's detail entry. Either way the answer
        is a nested heading, so the reader can fold it away.
        """
        _path, _text, _doc, section = self._locate_section(req)  # fail before a model call when it is gone
        lines = split_lines(req.content)
        extra = _line_question_values(req, section, lines) if req.line is not None else None
        ctx, call = await self._ask_model(req, emit, req.task, FOLLOW_UP_SCHEMA, extra=extra)
        try:
            answer = normalize_answer(call.structured)
        except InvalidResponse as exc:
            raise EngineError("invalid_response", str(exc), retryable=True) from exc

        fingerprint = detail_fingerprint(lines, req.line, req.line) if req.line is not None else ""
        entry = Question(question=req.question or "", answer=answer, created_at=_timestamp(),
                         line=req.line, fingerprint=fingerprint)

        def add(target: Section) -> None:
            (target.followups if entry.line is None else target.line_followups).append(entry)

        path, text, doc, _section = self._edit_section(req, add)
        await emit(self._followup_message(req, ctx, entry, call, path, text, doc))

    async def _run_section_refresh(self, req: ExplainRequest, emit: Emit) -> None:
        """Explain one section's lines again, and make that the section's explanation.

        Only the section changes. Its old questions are removed, because they were
        asked about the text that is being replaced. A full refresh (use_cache
        false) of the whole explanation replaces every section.
        """
        self._locate_section(req)
        ctx, call = await self._ask_model(req, emit, SECTION_TASK, SECTION_EXPLANATION_SCHEMA)
        try:
            explanation = normalize_section_explanation(call.structured)
        except InvalidResponse as exc:
            raise EngineError("invalid_response", str(exc), retryable=True) from exc

        refreshed_at = _timestamp()

        def reset(section: Section) -> None:
            section.explanation = explanation
            section.followups = []
            section.line_followups = []
            section.refreshed_at = refreshed_at

        path, text, doc, section = self._edit_section(req, reset)
        await emit(self._section_message(req, ctx, section, call, path, text, doc))

    async def _run_delete_question(self, req: ExplainRequest, emit: Emit) -> None:
        """Remove one question from its section in the stored explanation. No model call is made.

        The question is found by its CREATED time. When it is no longer there, nothing
        is written and the request fails with ``explanation_missing``.
        """
        def drop(section: Section) -> None:
            for questions in (section.followups, section.line_followups):
                for index, entry in enumerate(questions):
                    if entry.created_at == req.question_at:
                        del questions[index]
                        return
            raise EngineError("explanation_missing", "that question is no longer in the explanation")

        path, text, doc, _section = self._edit_section(req, drop)
        await emit(self._delete_message(req, path, text, doc))

    async def _run_detail(self, req: ExplainRequest, emit: Emit) -> None:
        """Explain every lines group of a saved explanation line by line.

        Each group is cut into pieces of a few dozen lines, and each piece is one model
        call. The calls run a few at a time, and each one starts a new Claude session,
        so none of them adds to the session that answers questions. The saved
        explanation changes only when every call has succeeded.
        """
        stored = self._load(req, req.explanation_key or "")
        if stored is None:
            raise EngineError("explanation_missing",
                              "this explanation is no longer cached; press g to explain the file again")
        _path, _text, doc = stored
        lines = split_lines(req.content)
        pieces = _detail_pieces(doc, len(lines))
        if req.task == DETAIL_SECTION_TASK:
            # Only the lines group named by the target is explained; the others keep their detail.
            group = (req.target.start_line, req.target.end_line)
            pieces = [piece for piece in pieces if (piece.group_start, piece.group_end) == group]
            if not pieces:
                raise EngineError("explanation_missing",
                                  "this section is not in the saved explanation; press g to explain the file again")
        claude_path = locate_claude(self._config.claude_bin)
        if pieces and claude_path is None:
            raise EngineError("claude_not_found", "the Claude Code CLI could not be found", retryable=False)
        model = req.model or self._config.claude_model
        system_prompt = build_system_prompt(req.explain_language)
        started = time.monotonic()
        finished = {"count": 0}
        chars: dict[int, int] = {}
        semaphore = asyncio.Semaphore(DETAIL_CONCURRENCY)

        def steps() -> dict[str, int]:
            return {"done": finished["count"], "total": len(pieces)}

        async def ticker() -> None:
            while True:
                await asyncio.sleep(PROGRESS_INTERVAL_S)
                await _safe_emit(emit, protocol.progress(req.id, "running", _elapsed(started),
                                                         sum(chars.values()), steps=steps()))

        async def explain_piece(index: int, piece: _Piece) -> tuple[list[DetailLine], _CallResult]:
            sub = replace(req, target=Target(start_line=piece.start, end_line=piece.end))
            async with semaphore:
                ctx = collect_context(sub)
                user_prompt = build_user_prompt(DETAIL_TASK, _prompt_values(sub, ctx))

                def on_progress(state: Any) -> None:
                    chars[index] = state.output_chars

                call = await self._call_claude(sub, system_prompt, user_prompt, model, claude_path, on_progress,
                                               schema=DETAIL_SCHEMA, fresh=True)
            finished["count"] += 1
            try:
                entries = normalize_detail(call.structured, start=piece.start, end=piece.end, lines=lines)
            except InvalidResponse as exc:
                raise EngineError("invalid_response", str(exc), retryable=True) from exc
            return [DetailLine(line=e["line"], explanation=e["explanation"]) for e in entries], call

        await emit(protocol.progress(req.id, "running", 0, 0, steps=steps()))
        ticking = asyncio.create_task(ticker())
        tasks = [asyncio.create_task(explain_piece(index, piece)) for index, piece in enumerate(pieces)]
        try:
            outcomes = await asyncio.gather(*tasks)
        except BaseException:
            # One failed or cancelled piece ends the request, so the others must not go on.
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            raise
        finally:
            ticking.cancel()

        self._registry.set_phase(req.id, "validating")
        await emit(protocol.progress(req.id, "validating", _elapsed(started), sum(chars.values()), steps=steps()))
        # The file is read again here, so a question or a refresh made meanwhile is kept.
        fresh = self._load(req, req.explanation_key or "")
        if fresh is None:
            raise EngineError("explanation_missing",
                              "this explanation was cleared while it was explained; press g to explain the file again")
        path, _text, current = fresh
        by_group: dict[tuple[int, int], list[DetailLine]] = {}
        for piece, (entries, _call) in zip(pieces, outcomes):
            by_group.setdefault((piece.group_start, piece.group_end), []).extend(entries)
        for (start, end), entries in by_group.items():
            section = current.find_section(start, end)
            if section is not None:
                section.detail = sorted(entries, key=lambda entry: entry.line)
                section.detail_fingerprint = detail_fingerprint(lines, start, end)
        text = render_document(current)
        self._cache.put(path, text)
        costs = [call.cost_usd for _entries, call in outcomes if call.cost_usd is not None]
        await emit(self._detail_message(req, path, text, current,
                                        cost_usd=sum(costs) if costs else None,
                                        duration_ms=_elapsed(started)))

    def _detail_message(self, req: ExplainRequest, path: Path, text: str, doc: Document, *,
                        cost_usd: float | None, duration_ms: int) -> dict[str, Any]:
        return {
            "type": "result",
            "id": req.id,
            "view": req.view,
            "task": req.task,
            "file": req.file_relpath,
            "explain_language": req.explain_language,
            "target": {"start_line": req.target.start_line, "end_line": req.target.end_line},
            "explanation_key": req.explanation_key,
            "cache_path": str(path),
            "document": text,
            "sections": _section_dicts(doc),
            "session_id": None,
            "session_resumed": None,
            "cost_usd": cost_usd,
            "duration_ms": duration_ms,
        }

    def _delete_message(self, req: ExplainRequest, path: Path, text: str, doc: Document) -> dict[str, Any]:
        return {
            "type": "result",
            "id": req.id,
            "view": req.view,
            "task": DELETE_QUESTION_TASK,
            "file": req.file_relpath,
            "explain_language": req.explain_language,
            "target": {"start_line": req.target.start_line, "end_line": req.target.end_line},
            "explanation_key": req.explanation_key,
            "question_at": req.question_at,
            "cache_path": str(path),
            "document": text,
            "sections": _section_dicts(doc),
        }

    def _section_message(self, req: ExplainRequest, ctx: ContextPackage, section: Section,
                         call: _CallResult, path: Path, text: str, doc: Document) -> dict[str, Any]:
        return {
            "type": "result",
            "id": req.id,
            "view": req.view,
            "task": SECTION_TASK,
            "file": req.file_relpath,
            "snapshot_hash": ctx.snapshot_hash,
            "explain_language": req.explain_language,
            "target": {"start_line": req.target.start_line, "end_line": req.target.end_line},
            "explanation_key": req.explanation_key,
            "cache_path": str(path),
            "explanation": section.explanation,
            "created_at": section.refreshed_at,
            "document": text,
            "sections": _section_dicts(doc),
            "session_id": call.session_id,
            "session_resumed": call.resumed,
            "cost_usd": call.cost_usd,
            "duration_ms": call.duration_ms,
        }

    def _followup_message(self, req: ExplainRequest, ctx: ContextPackage, entry: Question,
                          call: _CallResult, path: Path, text: str, doc: Document) -> dict[str, Any]:
        return {
            "type": "result",
            "id": req.id,
            "view": req.view,
            "task": req.task,
            "line": req.line,
            "file": req.file_relpath,
            "snapshot_hash": ctx.snapshot_hash,
            "explain_language": req.explain_language,
            "target": {"start_line": req.target.start_line, "end_line": req.target.end_line},
            "explanation_key": req.explanation_key,
            "cache_path": str(path),
            "question": entry.question,
            "answer": entry.answer,
            "created_at": entry.created_at,
            "document": text,
            "sections": _section_dicts(doc),
            "session_id": call.session_id,
            "session_resumed": call.resumed,
            "cost_usd": call.cost_usd,
            "duration_ms": call.duration_ms,
        }

    async def _call_with_progress(
        self,
        req: ExplainRequest,
        ctx: ContextPackage,
        system_prompt: str,
        user_prompt: str,
        model: str | None,
        claude_path: str,
        emit: Emit,
        started: float,
        schema: dict = EXPLANATION_SCHEMA,
    ) -> _CallResult:
        """Run the CLI while a ticker emits progress; cancels the ticker on exit."""
        chars = {"value": 0}

        def on_progress(state: Any) -> None:
            chars["value"] = state.output_chars

        async def ticker() -> None:
            while True:
                await asyncio.sleep(PROGRESS_INTERVAL_S)
                await _safe_emit(emit, protocol.progress(req.id, "running", _elapsed(started), chars["value"]))

        ticking = asyncio.create_task(ticker())
        try:
            return await self._call_claude(req, system_prompt, user_prompt, model, claude_path, on_progress,
                                           schema=schema)
        finally:
            ticking.cancel()

    async def _call_claude(
        self,
        req: ExplainRequest,
        system_prompt: str,
        user_prompt: str,
        model: str | None,
        claude_path: str,
        on_progress: Callable[[Any], None],
        schema: dict = EXPLANATION_SCHEMA,
        *,
        fresh: bool = False,
    ) -> _CallResult:
        """Call the CLI, recovering from stale or in-use sessions (at most a few retries).

        A ``fresh`` call starts a new Claude session of its own. It is not recorded as the
        project's session, so the session that answers questions is left as it is.
        """
        root = str(req.project_root)
        schema_text = dump_schema(schema)
        for attempt in range(1, _MAX_ATTEMPTS + 1):
            if fresh:
                ref = SessionRef(session_id=str(uuid.uuid4()), resume=False)
            else:
                ref = self._sessions.ensure(root, req.explain_language)
            argv = build_argv(
                claude_path,
                json_schema=schema_text,
                system_prompt=system_prompt,
                session_id=ref.session_id,
                resume=ref.resume,
                max_budget_usd=self._config.max_budget_usd,
                model=model,
                effort=self._config.claude_effort,
            )
            log.info("request %s: claude call attempt %d (resume=%s)", req.id, attempt, ref.resume)
            outcome = await run_claude(
                argv,
                cwd=req.project_root,
                env=self._env,
                prompt=user_prompt,
                timeout=req.timeout,
                on_progress=on_progress,
            )
            stderr = outcome.stderr_tail
            if outcome.status == "not_found":
                raise EngineError("claude_not_found", "the Claude Code CLI could not be started", retryable=False)
            if outcome.status == "timeout":
                raise EngineError("claude_timeout", f"Claude did not finish within {req.timeout:.0f}s", retryable=True)

            result = outcome.state.result
            if result is None:
                if not fresh and "already in use" in stderr and not ref.resume:
                    # The session exists from an earlier, interrupted call. Continue it.
                    self._sessions.mark_started(root, ref.session_id, req.explain_language)
                    continue
                if not fresh and ref.resume and "No conversation found" in stderr:
                    self._sessions.reset(root)
                    continue
                raise EngineError(
                    "claude_failed",
                    "Claude exited without a result",
                    retryable=True,
                    details={"returncode": outcome.returncode, "stderr_tail": stderr[-500:]},
                )

            result_text = result.get("result") if isinstance(result.get("result"), str) else None
            if result.get("is_error"):
                if not fresh and ref.resume and ("No conversation found" in (result_text or "")
                                                 or "No conversation found" in stderr):
                    self._sessions.reset(root)
                    continue
                raise EngineError(
                    "claude_failed",
                    result_text or f"Claude reported an error ({result.get('subtype', 'unknown')})",
                    retryable=True,
                    details={"subtype": result.get("subtype"), "api_error_status": result.get("api_error_status")},
                )

            try:
                structured = parse_structured(result.get("structured_output"), result_text)
            except InvalidResponse as exc:
                raise EngineError("invalid_response", str(exc), retryable=True) from exc

            session_id = result.get("session_id") if isinstance(result.get("session_id"), str) else ref.session_id
            if not fresh:
                self._sessions.mark_started(root, session_id, req.explain_language)
            cost = result.get("total_cost_usd")
            duration = result.get("duration_ms")
            return _CallResult(
                structured=structured,
                session_id=session_id,
                resumed=ref.resume,
                cost_usd=float(cost) if isinstance(cost, (int, float)) else None,
                duration_ms=int(duration) if isinstance(duration, (int, float)) else 0,
            )
        raise EngineError("claude_failed", "Claude session could not be recovered", retryable=True)

    def _result_message(
        self,
        req: ExplainRequest,
        ctx: ContextPackage,
        key: str,
        cache_path: Path | None,
        text: str,
        doc: Document,
        *,
        cache_hit: bool,
        session_id: str | None,
        cost_usd: float | None,
        duration_ms: int,
        session_resumed: bool | None = None,
    ) -> dict[str, Any]:
        return {
            "type": "result",
            "id": req.id,
            "view": req.view,
            "task": req.task,
            "file": req.file_relpath,
            "snapshot_hash": ctx.snapshot_hash,
            "cache_hit": cache_hit,
            "explain_language": req.explain_language,
            "target": {"start_line": req.target.start_line, "end_line": req.target.end_line},
            "explanation_key": key,
            # None when the explanation has no file (it had no sections).
            "cache_path": str(cache_path) if cache_path is not None else None,
            "document": text,
            "summary": doc.summary,
            "sections": _section_dicts(doc),
            "dependencies": doc.dependencies,
            "data_flow": doc.data_flow,
            "notes": doc.notes,
            "warnings": doc.warnings,
            "session_id": session_id,
            "session_resumed": session_resumed,
            "cost_usd": cost_usd,
            "duration_ms": duration_ms,
        }


def _prompt_values(req: ExplainRequest, ctx: ContextPackage) -> dict[str, str]:
    symbol_note = f", symbol: {req.symbol}" if req.symbol else ""
    truncated_note = (
        " The snapshot was trimmed; say so in notes if it limits your explanation."
        if ctx.truncated
        else ""
    )
    return {
        "task_title": req.task.replace("_", " "),
        "file": ctx.file_relpath,
        "language": ctx.language,
        "project_root": str(req.project_root),
        "target_start": str(req.target.start_line),
        "target_end": str(req.target.end_line),
        "point_line": str(req.point_line or req.target.start_line),
        "symbol": req.symbol or "(unknown)",
        "symbol_note": symbol_note,
        "window_start": str(ctx.window_start),
        "window_end": str(ctx.window_end),
        "total_lines": str(ctx.total_lines),
        "truncated_note": truncated_note,
        "question": req.question or "",
        "snippet": ctx.numbered_snippet,
    }


def _scope(req: ExplainRequest) -> str:
    """Return the scope part of an explanation's file name: the whole file, or its lines."""
    if req.task == WHOLE_FILE_TASK:
        return "whole-file"
    return f"lines-{req.target.start_line}-{req.target.end_line}"


def _section_dicts(doc: Document) -> list[dict[str, Any]]:
    """Describe each section for the client: its lines, text and questions."""
    return [
        {
            "id": section.id,
            "source_start": section.source_start,
            "source_end": section.source_end,
            "title": section.title,
            "explanation": section.explanation,
            "followups": [
                {"question": entry.question, "answer": entry.answer, "created_at": entry.created_at,
                 "line": entry.line}
                for entry in [*section.followups, *section.line_followups]
            ],
            "refreshed_at": section.refreshed_at,
            "detail": [
                {"line": entry.line, "explanation": entry.explanation}
                for entry in section.detail
            ],
        }
        for section in doc.sections
    ]


def _carry_questions(previous: Document, doc: Document, lines: list[str]) -> None:
    """Keep the questions of ``previous`` on the sections of ``doc`` that cover the same lines.

    A question about one line is kept only while that line is the same: it has the same
    number, and the same code as when the question was asked.
    """
    for section in doc.sections:
        old = previous.find_section(section.source_start, section.source_end)
        if old is None:
            continue
        section.followups = list(old.followups)
        section.line_followups = [
            entry for entry in old.line_followups
            if entry.line is not None and entry.fingerprint
            and section.source_start <= entry.line <= section.source_end
            and detail_fingerprint(lines, entry.line, entry.line) == entry.fingerprint
        ]


def _line_question_values(req: ExplainRequest, section: Section, lines: list[str]) -> dict[str, str]:
    """Check that the line of a question can be asked about, and return its prompt values.

    The line must belong to the section and must hold code. Its detail explanation, if it has one,
    is given to the model, so that the answer adds to it.
    """
    number = req.line
    if number is None or not section.source_start <= number <= section.source_end or number > len(lines) \
            or not code_text(lines[number - 1]).strip():
        raise EngineError("bad_request", "that line has no code to ask about in this section", retryable=False)
    explained = next((item.explanation for item in section.detail if item.line == number), None)
    return {
        "line": str(number),
        "line_code": code_text(lines[number - 1]),
        "line_explanation": explained or "(no detail explanation for this line yet)",
    }


def _carry_details(previous: Document, doc: Document, lines: list[str]) -> None:
    """Keep the detail explanation of a section while the lines it was made from are unchanged.

    The detail is kept with the fingerprint of those lines. When a line of the section was
    edited, moved, or gained or lost its code, the fingerprint differs, so the whole detail
    is dropped and the reader asks for it again. A detail saved without a fingerprint is
    dropped too, because nothing shows that it still fits the file.
    """
    for section in doc.sections:
        old = previous.find_section(section.source_start, section.source_end)
        if old is None or not old.detail or not old.detail_fingerprint:
            continue
        if old.detail_fingerprint == detail_fingerprint(lines, section.source_start, section.source_end):
            section.detail = list(old.detail)
            section.detail_fingerprint = old.detail_fingerprint


@dataclass(frozen=True)
class _Piece:
    """A few lines of one lines group, explained in one model call."""

    group_start: int
    group_end: int
    start: int
    end: int


def _detail_pieces(doc: Document, total: int) -> list[_Piece]:
    """Cut each lines group of ``doc`` into pieces of at most DETAIL_CHUNK_LINES lines, in file order.

    A group that runs past the end of the file (the file was shortened since it was
    explained) is detailed up to its last line. A group that starts past it is skipped.
    """
    pieces: list[_Piece] = []
    for section in doc.sections:
        end = min(section.source_end, total)
        if section.source_start > end:
            continue
        for start, stop in _split_range(section.source_start, end, DETAIL_CHUNK_LINES):
            pieces.append(_Piece(group_start=section.source_start, group_end=section.source_end,
                                 start=start, end=stop))
    return pieces


def _split_range(start: int, end: int, size: int) -> list[tuple[int, int]]:
    """Split START..END into the fewest pieces of at most SIZE lines, of equal length where possible."""
    length = end - start + 1
    count = -(-length // size)  # ceiling division
    base, extra = divmod(length, count)
    ranges: list[tuple[int, int]] = []
    cursor = start
    for index in range(count):
        span = base + (1 if index < extra else 0)
        ranges.append((cursor, cursor + span - 1))
        cursor += span
    return ranges


def _timestamp() -> str:
    """Return the current UTC time, to the microsecond, so that later entries sort after earlier ones."""
    return datetime.now(timezone.utc).isoformat(timespec="microseconds")


def _elapsed(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


async def _safe_emit(emit: Emit, message: dict[str, Any]) -> None:
    """Emit without letting a dead connection crash the request handler."""
    try:
        await emit(message)
    except (ConnectionError, OSError, RuntimeError):
        log.debug("client went away before message %s could be delivered", message.get("type"))
