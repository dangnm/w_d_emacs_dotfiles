"""Pipeline tests: orchestrator, request registry, CLI runner, and the socket server.

They run the real code paths against ``tests/fixtures/fake_claude.py``, so no
network calls or API costs are involved.
"""

from __future__ import annotations

import asyncio
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from engine import protocol
from engine.cache import ExplanationCache
from engine.claude.cli import build_env, run_claude
from engine.claude.session import SessionStore
from engine.orchestrator import Orchestrator
from engine.requests import REASON_SUPERSEDED, RequestRegistry
from engine.server import EngineServer
from tests.helpers import (
    EnvPatch,
    FAKE_CLAUDE,
    Collector,
    explain_message,
    fake_env,
    make_config,
    make_project,
)

ENGINE_ROOT = Path(__file__).resolve().parent.parent


class PipelineCase(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        base = Path(self._tmp.name).resolve()
        self.project = base / "project"
        self.project.mkdir()
        self.source = make_project(self.project)
        self.state = base / "state"
        self.state.mkdir()
        self.state_file = base / "fake_sessions.json"
        self.argv_log = base / "argv.log"
        self.config = make_config(self.state)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def _orchestrator(self, config=None) -> tuple[Orchestrator, RequestRegistry]:
        registry = RequestRegistry()
        orchestrator = Orchestrator(
            config or self.config,
            SessionStore(self.state / "sessions.json"),
            ExplanationCache(self.state / "cache"),
            registry,
        )
        return orchestrator, registry

    def _calls(self) -> list[list[str]]:
        if not self.argv_log.exists():
            return []
        return [json.loads(line) for line in self.argv_log.read_text(encoding="utf-8").splitlines()]


class OrchestratorTests(PipelineCase):
    async def test_successful_explanation_is_validated_and_emitted(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        results = emit.of_type("result")
        self.assertEqual(len(results), 1, emit.messages)
        result = results[0]
        self.assertFalse(result["cache_hit"])
        # explain_file covers the whole 7-line sample, whatever target the client sent.
        self.assertEqual(result["sections"][0]["source_start"], 1)
        self.assertEqual(result["sections"][0]["source_end"], 7)
        self.assertEqual(result["target"], {"start_line": 1, "end_line": 7})
        self.assertEqual(result["explain_language"], "Vietnamese")
        self.assertEqual(result["file"], "lisp/sample.el")
        self.assertIsNotNone(result["session_id"])
        self.assertEqual(emit.of_type("error"), [])

    async def test_block_explanation_stays_within_its_target(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, task="explain_block",
                                                              target=(2, 2)), emit, "o")
        result = emit.of_type("result")[0]
        self.assertEqual((result["sections"][0]["source_start"], result["sections"][0]["source_end"]), (2, 2))

    async def test_progress_phases_are_reported(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        phases = [m["phase"] for m in emit.of_type("progress")]
        self.assertIn("building_context", phases)
        self.assertIn("validating", phases)

    async def test_second_identical_request_is_a_cache_hit(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            await orchestrator.handle_explain(explain_message(self.project, self.source, target=(1, 1)),
                                              Collector(), "o")
            calls_before = len(self._calls())
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-2",
                                                              target=(1, 1)), emit, "o")
        self.assertEqual(len(self._calls()), calls_before, "cache hit must not call claude")
        self.assertTrue(emit.of_type("result")[0]["cache_hit"])

    async def test_use_cache_false_forces_a_fresh_call(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            await orchestrator.handle_explain(explain_message(self.project, self.source), Collector(), "o")
            before = len(self._calls())
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-2",
                                                              use_cache=False), Collector(), "o")
        self.assertEqual(len(self._calls()), before + 1)

    async def test_follow_up_requests_resume_the_project_session(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            first_emit, second_emit = Collector(), Collector()
            # Two different tasks, so the second call is not served from the cache.
            await orchestrator.handle_explain(explain_message(self.project, self.source, task="explain_block",
                                                              target=(1, 1)), first_emit, "o")
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-2",
                                                              task="explain_function", target=(2, 2)),
                                              second_emit, "o")
        first, second = self._calls()
        self.assertIn("--session-id", first)
        self.assertIn("--resume", second)
        self.assertEqual(first[first.index("--session-id") + 1], second[second.index("--resume") + 1])
        self.assertIs(first_emit.of_type("result")[0]["session_resumed"], False)
        self.assertIs(second_emit.of_type("result")[0]["session_resumed"], True)

    async def test_stale_session_is_recreated(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            sessions = orchestrator._sessions
            ref = sessions.ensure(str(self.project))
            sessions.mark_started(str(self.project), ref.session_id)  # store says started, CLI does not know it
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        self.assertEqual(len(emit.of_type("result")), 1, emit.messages)
        self.assertEqual(emit.of_type("error"), [])

    async def test_session_in_use_is_resumed_instead_of_failing(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            sessions = orchestrator._sessions
            ref = sessions.ensure(str(self.project))  # store says new
            self.state_file.write_text(json.dumps([ref.session_id]), encoding="utf-8")  # CLI already has it
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        self.assertEqual(len(emit.of_type("result")), 1, emit.messages)
        self.assertEqual(emit.of_type("error"), [])

    async def test_bad_json_from_model_is_invalid_response(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="not_json")):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        error = emit.of_type("error")[0]
        self.assertEqual(error["code"], "invalid_response")
        self.assertTrue(error["retryable"])

    async def test_api_error_is_claude_failed_with_message(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="is_error")):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        error = emit.of_type("error")[0]
        self.assertEqual(error["code"], "claude_failed")
        self.assertIn("Credit balance", error["message"])
        self.assertEqual(emit.of_type("result"), [])

    async def test_missing_result_reports_stderr_tail(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="no_result")):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        error = emit.of_type("error")[0]
        self.assertEqual(error["code"], "claude_failed")
        self.assertIn("boom", error["details"]["stderr_tail"])

    async def test_out_of_range_sections_are_dropped_and_reported(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="bad_range")):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, target=(1, 2)), emit, "o")
        result = emit.of_type("result")[0]
        self.assertEqual(len(result["sections"]), 1)
        self.assertIn("range_out_of_bounds", [w["code"] for w in result["warnings"]])

    async def test_missing_claude_binary_is_reported(self) -> None:
        config = make_config(self.state, claude_bin="/definitely/not/here/claude")
        orchestrator, _ = self._orchestrator(config)
        emit = Collector()
        await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "claude_not_found")

    async def test_bad_request_is_reported_without_registering(self) -> None:
        orchestrator, registry = self._orchestrator()
        emit = Collector()
        await orchestrator.handle_explain(explain_message(self.project, self.source, task="ask"), emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "bad_request")
        self.assertEqual(len(registry), 0)

    async def test_duplicate_request_id_is_rejected(self) -> None:
        orchestrator, registry = self._orchestrator()
        first = orchestrator.accept_explain(explain_message(self.project, self.source), "o")
        self.assertNotIsInstance(first, dict)
        second = orchestrator.accept_explain(explain_message(self.project, self.source), "o")
        self.assertEqual(second["code"], "bad_request")
        registry.finish(first.id)

    async def test_secrets_in_environment_are_dropped_for_the_cli(self) -> None:
        env = build_env({"ANTHROPIC_API_KEY": "secret", "HOME": "/h"}, ("ANTHROPIC_API_KEY",))
        self.assertNotIn("secret", json.dumps(env))


class CancellationAndSupersedeTests(PipelineCase):
    async def test_cancel_while_running_kills_claude_and_reports_client_reason(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="sleep", sleep=30)):
            orchestrator, registry = self._orchestrator()
            emit = Collector()
            task = asyncio.create_task(orchestrator.handle_explain(explain_message(self.project, self.source),
                                                                   emit, "o"))
            await self._wait_for(lambda: any(m.get("type") == "progress" and m.get("phase") == "running"
                                             for m in emit.messages))
            started = time.monotonic()
            self.assertTrue(registry.cancel("r-1", "client"))
            # The handler re-raises CancelledError after reporting it, so the task ends cancelled.
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(task, timeout=10)
        self.assertLess(time.monotonic() - started, 8, "child process should be terminated promptly")
        cancelled = emit.of_type("cancelled")
        self.assertEqual(cancelled[0]["reason"], "client")
        self.assertEqual(len(registry), 0)

    async def test_newer_request_for_same_view_supersedes_the_older(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="sleep", sleep=30)):
            orchestrator, registry = self._orchestrator()
            old_emit, new_emit = Collector(), Collector()
            old_task = asyncio.create_task(orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="old", use_cache=False), old_emit, "o"))
            await self._wait_for(lambda: any(m.get("phase") == "running" for m in old_emit.messages))
            new_task = asyncio.create_task(orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="new", use_cache=False), new_emit, "o"))
            with self.assertRaises(asyncio.CancelledError):
                await asyncio.wait_for(old_task, timeout=10)
            self.assertEqual(old_emit.of_type("cancelled")[0]["reason"], REASON_SUPERSEDED)
            new_task.cancel()
            try:
                await new_task
            except asyncio.CancelledError:
                pass
        self.assertEqual(len(registry), 0)

    async def test_cancel_before_start_is_honoured(self) -> None:
        orchestrator, registry = self._orchestrator()
        accepted = orchestrator.accept_explain(explain_message(self.project, self.source), "o")
        registry.cancel(accepted.id, "client")
        emit = Collector()
        await orchestrator.run_explain(accepted, emit)
        self.assertEqual(emit.of_type("cancelled")[0]["reason"], "client")
        self.assertEqual(len(registry), 0)

    async def test_run_claude_timeout_terminates_the_child(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="sleep", sleep=30)):
            env = build_env(dict(os.environ), ())
        outcome = await run_claude(
            [str(FAKE_CLAUDE), "--session-id", "00000000-0000-4000-8000-0000000000aa"],
            cwd=self.project,
            env=env,
            prompt="x",
            timeout=1.0,
        )
        self.assertEqual(outcome.status, "timeout")

    async def _wait_for(self, predicate, timeout: float = 10.0) -> None:
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                self.fail("condition not reached in time")
            await asyncio.sleep(0.02)


class ServerTests(PipelineCase):
    """Protocol-level tests against a real UNIX socket served in this process."""

    async def asyncSetUp(self) -> None:
        self.socket_path = Path(tempfile.mkdtemp(prefix="dcr-")) / "s.sock"
        self.config = make_config(self.state, socket_path=self.socket_path)
        registry = RequestRegistry()
        orchestrator = Orchestrator(self.config, SessionStore(self.state / "sessions.json"),
                                    ExplanationCache(self.state / "cache"), registry)
        from engine.claude.cli import probe_claude

        self.server = EngineServer(self.config, orchestrator, registry, probe_claude(str(FAKE_CLAUDE)))
        await self.server.start()
        self.serve_task = asyncio.create_task(self.server.serve())

    async def asyncTearDown(self) -> None:
        if not self.serve_task.done():
            self.server.request_stop("test teardown")
            await asyncio.wait_for(self.serve_task, timeout=10)

    async def _connect(self):
        return await asyncio.open_unix_connection(str(self.socket_path))

    @staticmethod
    async def _read_until(reader, predicate, timeout: float = 20.0) -> list[dict]:
        seen: list[dict] = []
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out; saw {seen}")
            line = await asyncio.wait_for(reader.readline(), timeout=remaining)
            if not line:
                raise AssertionError(f"connection closed; saw {seen}")
            message = json.loads(line)
            seen.append(message)
            if predicate(message):
                return seen

    async def test_ping_reports_claude_flags(self) -> None:
        reader, writer = await self._connect()
        writer.write(protocol.encode({"type": "ping"}))
        await writer.drain()
        pong = (await self._read_until(reader, lambda m: m["type"] == "pong"))[-1]
        self.assertEqual(pong["protocol"], 1)
        self.assertTrue(pong["claude"]["flags_ok"])
        writer.close()

    async def test_explain_round_trip_over_socket(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            reader, writer = await self._connect()
            writer.write(protocol.encode(explain_message(self.project, self.source)))
            await writer.drain()
            messages = await self._read_until(reader, lambda m: m["type"] in ("result", "error"))
        result = messages[-1]
        self.assertEqual(result["type"], "result", messages)
        self.assertEqual(result["id"], "r-1")
        self.assertEqual(result["sections"][0]["source_start"], 1)
        self.assertEqual(result["sections"][0]["source_end"], 7)
        writer.close()

    async def test_malformed_and_unknown_messages_get_errors(self) -> None:
        reader, writer = await self._connect()
        writer.write(b"this is not json\n")
        writer.write(protocol.encode({"type": "frobnicate", "id": "x"}))
        await writer.drain()
        first = await asyncio.wait_for(reader.readline(), 10)
        second = await asyncio.wait_for(reader.readline(), 10)
        self.assertEqual(json.loads(first)["code"], "bad_request")
        self.assertEqual(json.loads(second)["code"], "bad_request")
        writer.close()

    async def test_status_cache_and_session_messages(self) -> None:
        reader, writer = await self._connect()
        writer.write(protocol.encode({"type": "status"}))
        writer.write(protocol.encode({"type": "clear_cache"}))
        writer.write(protocol.encode({"type": "reset_session", "project_root": str(self.project)}))
        await writer.drain()
        seen = await self._read_until(reader, lambda m: m["type"] == "session_reset")
        types = {m["type"] for m in seen}
        self.assertTrue({"status", "cache_cleared", "session_reset"} <= types)
        writer.close()

    async def test_shutdown_message_stops_the_server(self) -> None:
        reader, writer = await self._connect()
        writer.write(protocol.encode({"type": "shutdown"}))
        await writer.drain()
        await self._read_until(reader, lambda m: m["type"] == "bye")
        # The client is still connected here: shutdown must not wait for it to hang up.
        await asyncio.wait_for(self.serve_task, timeout=10)
        self.assertFalse(self.socket_path.exists())
        writer.close()


class SubprocessEngineTests(unittest.TestCase):
    """Run ``python3 -m engine`` as a real process, the way Emacs starts it."""

    def test_engine_process_serves_and_exits_on_shutdown(self) -> None:
        import socket as socketlib

        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp).resolve()
            project = base / "project"
            project.mkdir()
            source = make_project(project)
            socket_path = base / "e.sock"
            state = base / "state"
            argv = [sys.executable, "-m", "engine", "--socket", str(socket_path), "--state-dir", str(state),
                    "--claude-bin", str(FAKE_CLAUDE), "--drop-env", "ANTHROPIC_API_KEY"]
            env = dict(os.environ)
            env.update(fake_env(base / "fake_sessions.json", None))
            proc = subprocess.Popen(argv, cwd=str(ENGINE_ROOT), env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 15
                while not socket_path.exists():
                    if proc.poll() is not None or time.monotonic() > deadline:
                        self.fail(f"engine did not start: {proc.stderr.read().decode(errors='replace')}")
                    time.sleep(0.05)
                client = socketlib.socket(socketlib.AF_UNIX, socketlib.SOCK_STREAM)
                client.settimeout(30)
                client.connect(str(socket_path))
                client.sendall(protocol.encode(explain_message(project, source, target=(1, 1))))
                buffer = b""
                result = None
                while result is None:
                    chunk = client.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                    for line in buffer.split(b"\n")[:-1]:
                        message = json.loads(line)
                        if message["type"] in ("result", "error"):
                            result = message
                            break
                    buffer = buffer.split(b"\n")[-1]
                self.assertIsNotNone(result)
                self.assertEqual(result["type"], "result", result)
                client.sendall(protocol.encode({"type": "shutdown"}))
                client.close()
                self.assertEqual(proc.wait(timeout=15), 0)
                self.assertFalse(socket_path.exists())
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait()


if __name__ == "__main__":
    unittest.main()
