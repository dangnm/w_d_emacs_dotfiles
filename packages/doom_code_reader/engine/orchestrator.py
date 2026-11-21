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
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

from engine import protocol
from engine.cache import ExplanationCache, make_key
from engine.claude.cli import build_argv, build_env, dump_schema, locate_claude, run_claude
from engine.claude.session import SessionStore
from engine.config import ENGINE_VERSION, PROGRESS_INTERVAL_S, EngineConfig
from engine.context.collector import ContextPackage, collect_context
from engine.models.request import BadRequest, ExplainRequest, parse_explain
from engine.models.response import InvalidResponse, normalize_output, parse_structured
from engine.models.schema import EXPLANATION_SCHEMA
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
        started = time.monotonic()
        await emit(protocol.progress(req.id, "building_context", 0, 0))
        ctx = collect_context(req)

        system_prompt = build_system_prompt(req.explain_language)
        user_prompt = build_user_prompt(req.task, _prompt_values(req, ctx))
        model = req.model or self._config.claude_model
        key = make_key(
            {
                "context_version": CONTEXT_VERSION,
                "snapshot_hash": ctx.snapshot_hash,
                "task": req.task,
                "target": [req.target.start_line, req.target.end_line],
                "symbol": req.symbol,
                "explain_language": req.explain_language,
                "model": model,
                "project_root": str(req.project_root),
                "file": req.file_relpath,
                "prompt": prompt_fingerprint(req.task),
            }
        )

        if req.use_cache:
            cached = self._cache.get(key)
            if cached is not None:
                log.info("request %s served from cache", req.id)
                await emit(self._result_message(req, ctx, cached, cache_hit=True, session_id=None,
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

        payload_dict = payload.to_dict()
        if payload.sections:
            self._cache.put(key, payload_dict)
        await emit(self._result_message(req, ctx, payload_dict, cache_hit=False, session_id=call.session_id,
                                        session_resumed=call.resumed, cost_usd=call.cost_usd,
                                        duration_ms=call.duration_ms))

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
            return await self._call_claude(req, system_prompt, user_prompt, model, claude_path, on_progress)
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
    ) -> _CallResult:
        """Call the CLI, recovering from stale or in-use sessions (at most a few retries)."""
        root = str(req.project_root)
        schema = dump_schema(EXPLANATION_SCHEMA)
        for attempt in range(1, _MAX_ATTEMPTS + 1):
            ref = self._sessions.ensure(root, req.explain_language)
            argv = build_argv(
                claude_path,
                json_schema=schema,
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
                if "already in use" in stderr and not ref.resume:
                    # The session exists from an earlier, interrupted call. Continue it.
                    self._sessions.mark_started(root, ref.session_id, req.explain_language)
                    continue
                if ref.resume and "No conversation found" in stderr:
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
                if ref.resume and ("No conversation found" in (result_text or "") or "No conversation found" in stderr):
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
        payload: dict[str, Any],
        *,
        cache_hit: bool,
        session_id: str | None,
        cost_usd: float | None,
        duration_ms: int,
        session_resumed: bool | None = None,
    ) -> dict[str, Any]:
        warnings = list(payload.get("warnings", []))
        if ctx.truncated:
            warnings.append(
                {
                    "code": "context_truncated",
                    "message": "the source context was trimmed to fit; some surrounding code is not shown",
                    "section_id": None,
                }
            )
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
            "summary": payload.get("summary", ""),
            "sections": payload.get("sections", []),
            "dependencies": payload.get("dependencies", []),
            "data_flow": payload.get("data_flow", []),
            "notes": payload.get("notes", []),
            "warnings": warnings,
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
        "snippet": ctx.numbered_snippet,
    }


def _elapsed(started: float) -> int:
    return int((time.monotonic() - started) * 1000)


async def _safe_emit(emit: Emit, message: dict[str, Any]) -> None:
    """Emit without letting a dead connection crash the request handler."""
    try:
        await emit(message)
    except (ConnectionError, OSError, RuntimeError):
        log.debug("client went away before message %s could be delivered", message.get("type"))
