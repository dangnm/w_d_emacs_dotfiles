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
from engine.cache import ExplanationCache, project_folder
from engine.claude.cli import build_env, run_claude
from engine.claude.session import SessionStore
from engine.orchestrator import Orchestrator
from engine.models.response import NO_DETAIL_TEXT
from engine.org import Section
from engine.org import parse as parse_document
from engine.org import render as render_document
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

    async def test_explanation_is_stored_in_its_project_folder(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source), emit, "o")
        result = emit.of_type("result")[0]
        path = Path(result["cache_path"])
        self.assertTrue(path.exists())
        rel = path.relative_to(self.state / "cache")
        self.assertEqual(rel.parts[0], project_folder(str(self.project)))
        self.assertEqual(rel.parts[1:3], ("lisp", "sample.el"))
        text = path.read_text(encoding="utf-8")
        self.assertIn(f"#+KEY: {result['explanation_key']}", text)
        self.assertIn("#+MODEL: default", text)

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


class CacheUntilRefreshTests(PipelineCase):
    async def test_edited_source_keeps_the_explanation_until_it_is_refreshed(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            first = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="c-1"),
                                              first, "o")
            self.assertFalse(first.of_type("result")[0]["cache_hit"])

            # The file was edited: the cached explanation is still served.
            edited = self.source.read_text(encoding="utf-8") + "\n;; a new comment line\n"
            again = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="c-2", content=edited), again, "o")
            self.assertTrue(again.of_type("result")[0]["cache_hit"], again.messages)
            self.assertEqual(len(self._calls()), 1)

            # Refreshing (use_cache false) makes a new call and replaces the entry.
            refreshed = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="c-3", content=edited, use_cache=False),
                refreshed, "o")
            self.assertFalse(refreshed.of_type("result")[0]["cache_hit"])
            self.assertEqual(len(self._calls()), 2)


class SectionRefreshPipelineTests(PipelineCase):
    async def test_refresh_changes_one_section_until_the_explanation_is_regenerated(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            first = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="s-1"),
                                              first, "o")
            explained = first.of_type("result")[0]
            section = explained["sections"][0]
            lines = (section["source_start"], section["source_end"])

            refresh = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, task="explain_section", target=lines,
                                view="view-refresh-1", request_id="s-2", use_cache=False,
                                explanation_key=explained["explanation_key"]),
                refresh, "o")
            self.assertEqual(refresh.of_type("error"), [], refresh.messages)
            answer = refresh.of_type("result")[0]
            self.assertEqual(answer["task"], "explain_section")
            self.assertEqual(answer["target"], {"start_line": lines[0], "end_line": lines[1]})
            self.assertIn("làm mới", answer["explanation"])
            self.assertIn("làm mới", answer["document"])
            self.assertEqual(answer["sections"][0]["explanation"], answer["explanation"])

            # The next explanation of the file shows the refreshed section, from the cache.
            cached = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="s-3"),
                                              cached, "o")
            result = cached.of_type("result")[0]
            self.assertTrue(result["cache_hit"])
            self.assertIn("làm mới", result["sections"][0]["explanation"])
            self.assertEqual(result["document"], answer["document"])

            # A full refresh (use_cache false) supersedes the section refresh.
            full = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="s-4", use_cache=False), full, "o")
            self.assertNotIn("làm mới", full.of_type("result")[0]["sections"][0]["explanation"])

    async def test_refresh_resets_the_questions_asked_before_it(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            first = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-1"),
                                              first, "o")
            explained = first.of_type("result")[0]
            key = explained["explanation_key"]
            lines = (explained["sections"][0]["source_start"], explained["sections"][0]["source_end"])

            asked = explain_message(self.project, self.source, task="follow_up", target=lines,
                                    question="Old question?", view="view-old-1", request_id="r-2",
                                    explanation_key=key)
            await orchestrator.handle_explain(asked, Collector(), "o")

            refresh = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, task="explain_section", target=lines,
                                view="view-refresh-2", request_id="r-3", use_cache=False,
                                explanation_key=key),
                refresh, "o")
            self.assertEqual(refresh.of_type("error"), [], refresh.messages)
            self.assertEqual(refresh.of_type("result")[0]["sections"][0]["followups"], [])
            self.assertNotIn("Old question?", refresh.of_type("result")[0]["document"])

            after = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-4"),
                                              after, "o")
            self.assertEqual(after.of_type("result")[0]["sections"][0]["followups"], [])

            # A question asked after the refresh is shown again.
            asked_again = explain_message(self.project, self.source, task="follow_up", target=lines,
                                          question="New question?", view="view-new-1", request_id="r-5",
                                          explanation_key=key)
            await orchestrator.handle_explain(asked_again, Collector(), "o")
            later = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="r-6"),
                                              later, "o")
            self.assertEqual([entry["question"] for entry in later.of_type("result")[0]["sections"][0]["followups"]],
                             ["New question?"])

    async def test_section_refresh_needs_the_explanation_on_disk(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, task="explain_section", target=(1, 7),
                                view="view-refresh-3", request_id="s-9", use_cache=False,
                                explanation_key="b" * 64),
                emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(self._calls(), [], "no model call when there is nothing to change")


class FollowUpPipelineTests(PipelineCase):
    async def _explain_file(self, orchestrator: Orchestrator) -> dict:
        emit = Collector()
        await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="e-0"), emit, "o")
        return emit.of_type("result")[0]

    async def test_answer_is_nested_under_its_section_and_kept(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain_file(orchestrator)
            asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7),
                                    question="Explain more about this section?", view="view-chat-1",
                                    request_id="f-1", explanation_key=explained["explanation_key"])
            emit = Collector()
            await orchestrator.handle_explain(asked, emit, "o")
            self.assertEqual(emit.of_type("error"), [], emit.messages)
            answer = emit.of_type("result")[0]
            self.assertEqual(answer["task"], "follow_up")
            self.assertEqual(answer["cache_path"], explained["cache_path"])
            self.assertEqual(answer["question"], "Explain more about this section?")
            self.assertEqual(answer["target"], {"start_line": 1, "end_line": 7})
            self.assertIn("giả lập", answer["answer"])
            self.assertIsNotNone(answer["session_id"])
            self.assertIn("** Question: Explain more about this section?", answer["document"])
            self.assertIn("giả lập", answer["document"])

            # The next explanation of the same file is the same document, with the answer in it.
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="e-1"),
                                              emit, "o")
            self.assertEqual(emit.of_type("error"), [], emit.messages)
            result = emit.of_type("result")[0]
            self.assertTrue(result["cache_hit"])
            self.assertEqual(result["explanation_key"], explained["explanation_key"])
            self.assertEqual(result["document"], answer["document"])
            sections = result["sections"]
            self.assertEqual(len(sections), 1)
            self.assertEqual([entry["question"] for entry in sections[0]["followups"]],
                             ["Explain more about this section?"])
            self.assertIn("giả lập", sections[0]["followups"][0]["answer"])

    async def test_question_about_lines_outside_the_explanation_is_refused(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain_file(orchestrator)
            calls_before = len(self._calls())
            asked = explain_message(self.project, self.source, task="follow_up", target=(2, 3),
                                    question="About lines 2 to 3?", view="view-chat-2", request_id="f-2",
                                    explanation_key=explained["explanation_key"])
            emit = Collector()
            await orchestrator.handle_explain(asked, emit, "o")
            self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
            self.assertEqual(len(self._calls()), calls_before, "no model call for a missing section")
            again = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="e-2"),
                                              again, "o")
            self.assertEqual(again.of_type("result")[0]["sections"][0]["followups"], [])

    async def test_question_is_refused_once_the_explanation_was_cleared(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain_file(orchestrator)
            self.assertEqual(orchestrator.handle_clear_cache()["removed"], 1)
            calls_before = len(self._calls())
            asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7),
                                    question="Still there?", view="view-chat-3", request_id="f-3",
                                    explanation_key=explained["explanation_key"])
            emit = Collector()
            await orchestrator.handle_explain(asked, emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(len(self._calls()), calls_before)

    async def test_full_refresh_keeps_the_questions_on_the_same_lines(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain_file(orchestrator)
            asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7),
                                    question="Kept across a full refresh?", view="view-chat-4", request_id="f-4",
                                    explanation_key=explained["explanation_key"])
            await orchestrator.handle_explain(asked, Collector(), "o")

            regenerated = Collector()
            await orchestrator.handle_explain(
                explain_message(self.project, self.source, request_id="e-3", use_cache=False), regenerated, "o")
            result = regenerated.of_type("result")[0]
            self.assertFalse(result["cache_hit"])
            self.assertEqual(result["explanation_key"], explained["explanation_key"])
            self.assertEqual([entry["question"] for entry in result["sections"][0]["followups"]],
                             ["Kept across a full refresh?"])
            self.assertIn("** Question: Kept across a full refresh?", result["document"])


class DeleteQuestionPipelineTests(PipelineCase):
    async def _explain_and_ask(self, orchestrator, question: str) -> tuple[dict, dict]:
        emit = Collector()
        await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="q-0"), emit, "o")
        explained = emit.of_type("result")[0]
        asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7), question=question,
                                view="view-del-chat", request_id="q-1",
                                explanation_key=explained["explanation_key"])
        answer_emit = Collector()
        await orchestrator.handle_explain(asked, answer_emit, "o")
        return explained, answer_emit.of_type("result")[0]

    def _delete(self, explained: dict, question_at: str, request_id: str) -> Collector:
        return explain_message(self.project, self.source, task="delete_question", target=(1, 7),
                               view="view-del-1", request_id=request_id,
                               explanation_key=explained["explanation_key"], question_at=question_at)

    async def test_a_question_is_removed_from_the_explanation_and_its_file(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained, answer = await self._explain_and_ask(orchestrator, "A question to delete?")
            calls_before = len(self._calls())
            emit = Collector()
            await orchestrator.handle_explain(self._delete(explained, answer["created_at"], "q-2"), emit, "o")
        self.assertEqual(emit.of_type("error"), [], emit.messages)
        result = emit.of_type("result")[0]
        self.assertEqual(result["task"], "delete_question")
        self.assertNotIn("A question to delete?", result["document"])
        self.assertEqual(result["sections"][0]["followups"], [])
        self.assertEqual(len(self._calls()), calls_before, "deleting a question asks Claude nothing")
        self.assertNotIn("A question to delete?", Path(result["cache_path"]).read_text(encoding="utf-8"))

    async def test_a_question_that_is_gone_is_reported_and_nothing_is_written(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained, answer = await self._explain_and_ask(orchestrator, "Only once?")
            first = Collector()
            await orchestrator.handle_explain(self._delete(explained, answer["created_at"], "q-3"), first, "o")
            path = Path(first.of_type("result")[0]["cache_path"])
            after_first = path.read_text(encoding="utf-8")
            again = Collector()
            await orchestrator.handle_explain(self._delete(explained, answer["created_at"], "q-4"), again, "o")
        self.assertEqual(again.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(path.read_text(encoding="utf-8"), after_first)

    async def test_deleting_without_a_saved_explanation_is_refused(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            request = explain_message(self.project, self.source, task="delete_question", target=(1, 7),
                                      view="view-del-2", request_id="q-5", explanation_key="d" * 64,
                                      question_at="2026-11-22T10:00:00.000001+00:00")
            await orchestrator.handle_explain(request, emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(self._calls(), [])


class DetailPipelineTests(PipelineCase):
    """A line-by-line detail explanation, run through the orchestrator and the fake CLI."""

    async def _explain(self, orchestrator, source=None, request_id="d-0") -> dict:
        emit = Collector()
        await orchestrator.handle_explain(explain_message(self.project, source or self.source,
                                                          request_id=request_id), emit, "o")
        self.assertEqual(emit.of_type("error"), [], emit.messages)
        return emit.of_type("result")[0]

    async def _detail(self, orchestrator, explained: dict, *, source=None, request_id="dt-1",
                      content=None, task="explain_detail", target=(1, 1)) -> Collector:
        emit = Collector()
        request = explain_message(self.project, source or self.source, task=task, request_id=request_id,
                                  view=f"view-detail-{request_id}", explanation_key=explained["explanation_key"],
                                  content=content, target=target)
        await orchestrator.handle_explain(request, emit, "o")
        return emit

    def _split_into_two_sections(self, explained: dict) -> None:
        """Rewrite the saved explanation as two sections, lines 1-3 and 5-6, so one can be explained alone."""
        path = Path(explained["cache_path"])
        doc = parse_document(path.read_text(encoding="utf-8"))
        doc.sections[0].source_end = 3
        doc.sections.append(Section(id="second-s", source_start=5, source_end=6, title="Second",
                                    explanation="Second text."))
        path.write_text(render_document(doc), encoding="utf-8")

    async def test_a_section_detail_covers_only_that_section_and_keeps_the_others(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            self._split_into_two_sections(explained)
            whole = (await self._detail(orchestrator, explained, request_id="whole-1")).of_type("result")[0]
            second_before = whole["sections"][1]["detail"]
            calls_before = len(self._calls())
            emit = await self._detail(orchestrator, explained, request_id="one-1",
                                      task="explain_detail_section", target=(1, 3))
        self.assertEqual(emit.of_type("error"), [], emit.messages)
        result = emit.of_type("result")[0]
        self.assertEqual(result["task"], "explain_detail_section")
        self.assertEqual([entry["line"] for entry in result["sections"][0]["detail"]], [1, 2, 3])
        self.assertEqual(result["sections"][1]["detail"], second_before)
        self.assertEqual(len(self._calls()) - calls_before, 1)

    async def test_a_section_detail_for_lines_the_explanation_does_not_have_says_so(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            self._split_into_two_sections(explained)
            calls_before = len(self._calls())
            emit = await self._detail(orchestrator, explained, task="explain_detail_section", target=(1, 4))
        self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(len(self._calls()), calls_before)

    async def test_every_group_gets_a_line_by_line_detail_stored_in_its_file(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            emit = await self._detail(orchestrator, explained)
        self.assertEqual(emit.of_type("error"), [], emit.messages)
        result = emit.of_type("result")[0]
        self.assertEqual(result["task"], "explain_detail")
        self.assertEqual(result["explanation_key"], explained["explanation_key"])
        # Lines 4 and 7 are blank, so they get no entry.
        detail = result["sections"][0]["detail"]
        self.assertEqual([entry["line"] for entry in detail], [1, 2, 3, 5, 6])
        self.assertEqual(detail[0], {"line": 1, "explanation": "Giải thích dòng 1."})
        self.assertNotIn("code", detail[1])
        self.assertIn("\n  - 1\n    Giải thích dòng 1.\n", result["document"])
        self.assertNotIn("(defun greet (name)", result["document"].split("** Detail explanation", 1)[1])
        self.assertIn("\n** Detail explanation\n", result["document"])
        self.assertIn("\n  - 5\n    Giải thích dòng 5.\n", result["document"])
        self.assertNotIn("(defun add (a b)", result["document"])
        self.assertEqual(Path(result["cache_path"]).read_text(encoding="utf-8"), result["document"])

    async def test_detail_calls_use_their_own_sessions_and_leave_the_question_session_alone(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            session_before = orchestrator._sessions.snapshot()
            await self._detail(orchestrator, explained)
            self.assertEqual(orchestrator._sessions.snapshot(), session_before)
            detail_call = self._calls()[-1]
            self.assertIn("--session-id", detail_call)
            self.assertNotIn("--resume", detail_call)
            self.assertNotEqual(detail_call[detail_call.index("--session-id") + 1],
                                session_before[0]["session_id"])
            asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7),
                                    question="Still the same session?", view="view-detail-chat", request_id="dt-2",
                                    explanation_key=explained["explanation_key"])
            await orchestrator.handle_explain(asked, Collector(), "o")
            question_call = self._calls()[-1]
            self.assertEqual(question_call[question_call.index("--resume") + 1], session_before[0]["session_id"])

    async def test_a_long_group_is_explained_in_calls_of_a_few_dozen_lines(self) -> None:
        long_source = self.project / "lisp" / "long.el"
        long_source.write_text("".join(f"(setq value-{number} {number})\n" for number in range(1, 101)),
                               encoding="utf-8")
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator, source=long_source, request_id="long-0")
            before = len(self._calls())
            emit = await self._detail(orchestrator, explained, source=long_source, request_id="long-1")
        self.assertEqual(emit.of_type("error"), [], emit.messages)
        self.assertEqual(len(self._calls()) - before, 3)  # 100 lines in pieces of 34, 33 and 33
        detail = emit.of_type("result")[0]["sections"][0]["detail"]
        self.assertEqual([entry["line"] for entry in detail], list(range(1, 101)))
        self.assertEqual(emit.of_type("progress")[-1]["steps"], {"done": 3, "total": 3})

    async def test_a_line_the_model_leaves_out_says_so(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
        # The orchestrator copies the environment when it is made, so it is made inside the patch.
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="detail_skip")):
            orchestrator, _ = self._orchestrator()
            emit = await self._detail(orchestrator, explained)
        detail = emit.of_type("result")[0]["sections"][0]["detail"]
        self.assertEqual(detail[0], {"line": 1, "explanation": NO_DETAIL_TEXT})
        self.assertEqual(detail[1]["explanation"], "Giải thích dòng 2.")

    async def test_a_detail_answer_without_lines_stores_nothing(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
        with EnvPatch(fake_env(self.state_file, self.argv_log, mode="detail_bad")):
            orchestrator, _ = self._orchestrator()
            emit = await self._detail(orchestrator, explained)
        error = emit.of_type("error")[0]
        self.assertEqual(error["code"], "invalid_response")
        self.assertTrue(error["retryable"])
        self.assertEqual(emit.of_type("result"), [])
        self.assertNotIn("Detail explanation", Path(explained["cache_path"]).read_text(encoding="utf-8"))

    async def test_detail_needs_the_explanation_on_disk(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            emit = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, task="explain_detail",
                                                              request_id="dt-9", view="view-detail-9",
                                                              explanation_key="e" * 64), emit, "o")
        self.assertEqual(emit.of_type("error")[0]["code"], "explanation_missing")
        self.assertEqual(self._calls(), [], "no model call when there is nothing to explain")

    async def test_a_full_refresh_keeps_the_detail_only_while_the_code_is_unchanged(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            detailed = (await self._detail(orchestrator, explained)).of_type("result")[0]

            same = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="dt-r1",
                                                              use_cache=False), same, "o")
            self.assertEqual(same.of_type("result")[0]["sections"][0]["detail"], detailed["sections"][0]["detail"])

            edited = self.source.read_text(encoding="utf-8").replace("(+ a b)", "(+ a b 0)")
            changed = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="dt-r2",
                                                              content=edited, use_cache=False), changed, "o")
            self.assertEqual(changed.of_type("result")[0]["sections"][0]["detail"], [])
            self.assertNotIn("Detail explanation", changed.of_type("result")[0]["document"])

    async def test_questions_and_detail_are_kept_together(self) -> None:
        with EnvPatch(fake_env(self.state_file, self.argv_log)):
            orchestrator, _ = self._orchestrator()
            explained = await self._explain(orchestrator)
            asked = explain_message(self.project, self.source, task="follow_up", target=(1, 7),
                                    question="Kept with the detail?", view="view-both-1", request_id="both-1",
                                    explanation_key=explained["explanation_key"])
            await orchestrator.handle_explain(asked, Collector(), "o")
            emit = await self._detail(orchestrator, explained)
            detail_result = emit.of_type("result")[0]
            self.assertIn("** Question: Kept with the detail?", detail_result["document"])
            cached = Collector()
            await orchestrator.handle_explain(explain_message(self.project, self.source, request_id="both-2"),
                                              cached, "o")
        result = cached.of_type("result")[0]
        self.assertTrue(result["cache_hit"])
        self.assertEqual(len(result["sections"][0]["detail"]), 5)
        self.assertEqual([entry["question"] for entry in result["sections"][0]["followups"]],
                         ["Kept with the detail?"])


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
