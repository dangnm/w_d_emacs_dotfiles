"""asyncio UNIX-socket server speaking newline-delimited JSON (see PROTOCOL.md)."""

from __future__ import annotations

import asyncio
import logging
import os
import socket
import stat
import time
from collections.abc import Awaitable, Callable
from typing import Any

from engine import protocol
from engine.claude.cli import ClaudeInfo
from engine.config import ENGINE_VERSION, STREAM_LINE_LIMIT, EngineConfig
from engine.orchestrator import Orchestrator
from engine.requests import REASON_SHUTDOWN, RequestRegistry

log = logging.getLogger(__name__)

Emit = Callable[[dict[str, Any]], Awaitable[None]]
_IDLE_CHECK_S = 5.0


class EngineServer:
    def __init__(self, config: EngineConfig, orchestrator: Orchestrator, registry: RequestRegistry,
                 claude_info: ClaudeInfo | None) -> None:
        self._config = config
        self._orchestrator = orchestrator
        self._registry = registry
        self._claude_info = claude_info
        self._server: asyncio.base_events.Server | None = None
        self._clients = 0
        self._last_activity = time.monotonic()
        self._stop = asyncio.Event()
        self._tasks: set[asyncio.Task] = set()
        self._writers: set[asyncio.StreamWriter] = set()
        self._stop_reason: str | None = None

    # -- lifecycle ---------------------------------------------------------

    async def start(self) -> None:
        path = self._config.socket_path
        path.parent.mkdir(parents=True, exist_ok=True)
        _remove_stale_socket(path)
        self._server = await asyncio.start_unix_server(self._on_client, path=str(path), limit=STREAM_LINE_LIMIT)
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        log.info("listening on %s (engine %s)", path, ENGINE_VERSION)

    async def serve(self) -> None:
        """Run until stopped by shutdown, signal, or idle timeout."""
        idle = asyncio.create_task(self._idle_watch())
        try:
            await self._stop.wait()
        finally:
            idle.cancel()
            await self._shutdown()

    def request_stop(self, reason: str) -> None:
        self._stop_reason = reason
        self._stop.set()

    async def _shutdown(self) -> None:
        log.info("stopping (%s)", self._stop_reason)
        self._registry.cancel_all(REASON_SHUTDOWN)
        if self._server is not None:
            self._server.close()
        # Since Python 3.12, Server.wait_closed() also waits for open client
        # connections. Close them ourselves so shutdown cannot hang on a client.
        for writer in list(self._writers):
            writer.close()
        if self._server is not None:
            try:
                await asyncio.wait_for(self._server.wait_closed(), timeout=5)
            except asyncio.TimeoutError:
                log.warning("some clients did not close promptly")
        if self._tasks:
            await asyncio.wait(self._tasks, timeout=10)
        try:
            self._config.socket_path.unlink()
        except FileNotFoundError:
            pass

    async def _idle_watch(self) -> None:
        while True:
            await asyncio.sleep(_IDLE_CHECK_S)
            idle_for = time.monotonic() - self._last_activity
            if self._clients == 0 and len(self._registry) == 0 and idle_for > self._config.idle_timeout_s:
                self.request_stop("idle timeout")
                return

    def _touch(self) -> None:
        self._last_activity = time.monotonic()

    # -- connections -------------------------------------------------------

    async def _on_client(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        self._clients += 1
        self._writers.add(writer)
        self._touch()
        owner = writer
        write_lock = asyncio.Lock()

        async def emit(message: dict[str, Any]) -> None:
            async with write_lock:
                writer.write(protocol.encode(message))
                await writer.drain()

        try:
            while True:
                try:
                    line = await reader.readline()
                except (asyncio.LimitOverrunError, ValueError):
                    await _best_effort(emit, protocol.error(None, "bad_request", "message is too large"))
                    break
                if not line:
                    break
                if not line.strip():
                    continue
                self._touch()
                await self._dispatch(line, emit, owner)
        except (ConnectionError, OSError):
            log.debug("client connection dropped")
        finally:
            self._registry.cancel_owned_by(owner, "client")
            self._clients -= 1
            self._writers.discard(writer)
            self._touch()
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def _dispatch(self, line: bytes, emit: Emit, owner: object) -> None:
        try:
            msg = protocol.decode(line)
        except protocol.ProtocolError as exc:
            await _best_effort(emit, protocol.error(None, "bad_request", str(exc)))
            return

        kind = msg.get("type")
        if kind == "explain":
            accepted = self._orchestrator.accept_explain(msg, owner)
            if isinstance(accepted, dict):
                await _best_effort(emit, accepted)
                return
            task = asyncio.create_task(self._orchestrator.run_explain(accepted, emit))
            self._tasks.add(task)
            task.add_done_callback(self._tasks.discard)
        elif kind == "ping":
            claude = self._claude_info.to_dict() if self._claude_info else None
            claude_error = self._claude_info.error if self._claude_info else "claude not probed"
            await _best_effort(emit, protocol.pong(claude, claude_error))
        elif kind == "cancel":
            await _best_effort(emit, self._orchestrator.handle_cancel(msg))
        elif kind == "reset_session":
            await _best_effort(emit, self._orchestrator.handle_reset_session(msg))
        elif kind == "clear_cache":
            await _best_effort(emit, self._orchestrator.handle_clear_cache())
        elif kind == "status":
            await _best_effort(emit, self._orchestrator.status())
        elif kind == "shutdown":
            await _best_effort(emit, {"type": "bye"})
            self.request_stop("client shutdown")
        else:
            request_id = msg.get("id") if isinstance(msg.get("id"), str) else None
            await _best_effort(emit, protocol.error(request_id, "bad_request", f"unknown message type {kind!r}"))


async def _best_effort(emit: Emit, message: dict[str, Any]) -> None:
    try:
        await emit(message)
    except (ConnectionError, OSError):
        log.debug("dropped message %s: client gone", message.get("type"))


def _remove_stale_socket(path: os.PathLike[str] | str) -> None:
    """Remove a leftover socket file, but refuse to clobber a live engine."""
    try:
        mode = os.stat(path).st_mode
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(mode):
        raise RuntimeError(f"{path} exists and is not a socket")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(0.5)
        probe.connect(str(path))
    except OSError:
        os.unlink(path)  # nothing listening: stale
    else:
        raise RuntimeError(f"another engine is already listening on {path}")
    finally:
        probe.close()
