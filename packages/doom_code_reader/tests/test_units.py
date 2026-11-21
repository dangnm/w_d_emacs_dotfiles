"""Unit tests for the pure parts of the engine: parsing, validation, context, prompts, cache, sessions."""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from engine.cache import ExplanationCache, make_key
from engine.claude.cli import REQUIRED_FLAGS, build_argv, build_env, locate_claude, probe_claude
from engine.claude.session import SessionStore
from engine.claude.stream_parser import StreamParser
from engine.config import DENIED_TOOLS, MAX_SNIPPET_CHARS, READ_ONLY_TOOLS
from engine.context.collector import collect_context, render_numbered, split_lines
from engine.models.request import BadRequest, Target, parse_explain
from engine.models.response import InvalidResponse, normalize_output, parse_structured
from engine.prompts import PromptError, build_system_prompt, build_user_prompt, prompt_fingerprint, render
from tests.helpers import FAKE_CLAUDE, explain_message, make_project

FIXTURES = Path(__file__).resolve().parent / "fixtures"


class StreamParserTests(unittest.TestCase):
    def test_structured_stream_from_real_cli_output(self) -> None:
        parser = StreamParser()
        for line in (FIXTURES / "real_stream_structured.jsonl").read_text(encoding="utf-8").splitlines():
            parser.feed(line)
        state = parser.state
        self.assertTrue(state.session_id)  # a real UUID from the captured run
        self.assertEqual(state.model, "claude-haiku-5-5")
        self.assertGreater(state.output_chars, 0)
        self.assertIsNotNone(state.result)
        self.assertFalse(state.result["is_error"])
        structured = state.result["structured_output"]
        self.assertEqual(structured["sections"][0]["source_start"], 1)
        self.assertEqual(state.malformed_lines, 0)

    def test_thinking_deltas_are_not_counted_as_output(self) -> None:
        parser = StreamParser()
        parser.feed(json.dumps({"type": "stream_event", "event": {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "thinking_delta", "thinking": "a very long private thought"}}}))
        self.assertEqual(parser.state.output_chars, 0)

    def test_text_stream_from_real_cli_output(self) -> None:
        parser = StreamParser()
        for line in (FIXTURES / "real_stream_text.jsonl").read_text(encoding="utf-8").splitlines():
            parser.feed(line)
        self.assertEqual(parser.state.result["result"], "PONG")
        self.assertEqual(parser.state.output_chars, len("PONG"))

    def test_progress_callback_receives_state(self) -> None:
        seen: list[int] = []
        parser = StreamParser(on_progress=lambda state: seen.append(state.output_chars))
        parser.feed(json.dumps({"type": "stream_event", "event": {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": "input_json_delta", "partial_json": "abcd"}}}))
        self.assertEqual(seen, [4])

    def test_bad_lines_never_raise(self) -> None:
        parser = StreamParser()
        for raw in (b"", b"not json", b"[1,2]", b"\xff\xfe", b'{"type": 5}'):
            parser.feed(raw)
        self.assertGreaterEqual(parser.state.malformed_lines, 3)

    def test_api_error_is_recorded(self) -> None:
        parser = StreamParser()
        parser.feed(json.dumps({"type": "assistant", "is_api_error_message": True, "api_error_status": 400,
                                "message": {"content": [{"type": "text", "text": "Credit balance is too low"}]}}))
        self.assertEqual(parser.state.api_error["message"], "Credit balance is too low")


class RequestValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name).resolve()
        self.source = make_project(self.root)

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_valid_request_is_parsed(self) -> None:
        req = parse_explain(explain_message(self.root, self.source, target=(1, 3), task="explain_block"))
        self.assertEqual(req.task, "explain_block")
        self.assertEqual(req.target, Target(1, 3))
        self.assertEqual(req.file_relpath, "lisp/sample.el")
        self.assertEqual(req.timeout, 30)

    def test_explain_file_always_covers_the_whole_file(self) -> None:
        # The client's target is ignored for explain_file: the file is the target.
        req = parse_explain(explain_message(self.root, self.source, target=(3, 3), task="explain_file"))
        self.assertEqual(req.target, Target(1, 7))

    def test_explain_file_rejects_files_over_the_limit(self) -> None:
        from engine.config import MAX_FILE_CHARS

        huge = "(setq x 1)\n" * (MAX_FILE_CHARS // 10 + 10)
        with self.assertRaises(BadRequest) as ctx:
            parse_explain(explain_message(self.root, self.source, content=huge, task="explain_file"))
        self.assertEqual(ctx.exception.details.get("reason"), "file_too_large")

    def test_explain_block_still_checks_the_target(self) -> None:
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, target=(1, 999), task="explain_block"))

    def test_file_outside_project_is_rejected(self) -> None:
        outside = self.root.parent / "elsewhere.el"
        with self.assertRaises(BadRequest) as ctx:
            parse_explain(explain_message(self.root, self.source, file=str(outside)))
        self.assertEqual(ctx.exception.details.get("reason"), "file_outside_project")

    def test_traversal_is_rejected(self) -> None:
        bad = str(self.root / "lisp" / ".." / ".." / "etc" / "passwd")
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, file=bad))

    def test_unknown_task_is_rejected(self) -> None:
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, task="trace_call"))

    def test_target_out_of_range_is_rejected(self) -> None:
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, target=(1, 999), task="explain_block"))
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, target=(5, 2), task="explain_block"))

    def test_boolean_line_numbers_are_rejected(self) -> None:
        msg = explain_message(self.root, self.source, task="explain_block")
        msg["target"] = {"start_line": True, "end_line": True}
        with self.assertRaises(BadRequest):
            parse_explain(msg)

    def test_relative_paths_are_rejected(self) -> None:
        msg = explain_message(self.root, self.source)
        msg["project_root"] = "relative/dir"
        with self.assertRaises(BadRequest):
            parse_explain(msg)

    def test_oversized_content_is_rejected(self) -> None:
        big = "x" * (2 * 1024 * 1024 + 1)
        msg = explain_message(self.root, self.source, content=big, target=(1, 1))
        with self.assertRaises(BadRequest) as ctx:
            parse_explain(msg)
        self.assertEqual(ctx.exception.details.get("reason"), "content_too_large")

    def test_model_flag_injection_is_rejected(self) -> None:
        with self.assertRaises(BadRequest):
            parse_explain(explain_message(self.root, self.source, model="--dangerously-skip-permissions"))

    def test_timeout_is_clamped(self) -> None:
        low = parse_explain(explain_message(self.root, self.source, timeout=0))
        high = parse_explain(explain_message(self.root, self.source, timeout=10**9))
        self.assertEqual(low.timeout, 5.0)
        self.assertEqual(high.timeout, 900.0)

    def test_point_line_out_of_range_is_dropped_not_fatal(self) -> None:
        req = parse_explain(explain_message(self.root, self.source, point_line=10_000))
        self.assertIsNone(req.point_line)


class ResponseValidationTests(unittest.TestCase):
    TARGET = Target(1, 2)

    def test_valid_sections_get_stable_ids(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 1, "source_end": 1, "title": "A", "explanation": "a"},
            {"source_start": 2, "source_end": 2, "title": "B", "explanation": "b"},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="abcdef1234")
        self.assertEqual([s["id"] for s in payload.sections], ["abcdef12-s1", "abcdef12-s2"])
        self.assertEqual(payload.warnings, [])

    def test_out_of_bounds_section_is_dropped_with_warning(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 1, "source_end": 1, "title": "A", "explanation": "a"},
            {"source_start": 9000, "source_end": 9001, "title": "B", "explanation": "b"},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="ff")
        self.assertEqual(len(payload.sections), 1)
        codes = [w["code"] for w in payload.warnings]
        self.assertIn("range_out_of_bounds", codes)

    def test_reversed_and_non_integer_ranges_are_dropped(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 3, "source_end": 2, "title": "A", "explanation": "a"},
            {"source_start": "1", "source_end": 1, "title": "B", "explanation": "b"},
            {"source_start": True, "source_end": 1, "title": "C", "explanation": "c"},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="ff")
        self.assertEqual(payload.sections, [])
        self.assertIn("no_valid_sections", [w["code"] for w in payload.warnings])

    def test_overlapping_and_context_sections_are_kept_without_warnings(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 1, "source_end": 3, "title": "A", "explanation": "a"},
            {"source_start": 2, "source_end": 2, "title": "B", "explanation": "b"},
            {"source_start": 5, "source_end": 5, "title": "C", "explanation": "c"},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="ff")
        self.assertEqual(len(payload.sections), 3)
        self.assertEqual(payload.warnings, [])

    def test_empty_explanation_is_flagged_on_its_section(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 1, "source_end": 1, "title": "A", "explanation": "   "},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="ff")
        self.assertEqual(payload.warnings[0]["code"], "empty_explanation")
        self.assertEqual(payload.warnings[0]["section_id"], "ff-s1")

    def test_sections_are_sorted(self) -> None:
        raw = {"summary": "s", "sections": [
            {"source_start": 2, "source_end": 2, "title": "B", "explanation": "b"},
            {"source_start": 1, "source_end": 1, "title": "A", "explanation": "a"},
        ]}
        payload = normalize_output(raw, total_lines=6, target=self.TARGET, snapshot_hash="ff")
        self.assertEqual([s["source_start"] for s in payload.sections], [1, 2])

    def test_missing_summary_is_invalid(self) -> None:
        with self.assertRaises(InvalidResponse):
            normalize_output({"sections": []}, total_lines=3, target=self.TARGET, snapshot_hash="ff")

    def test_parse_structured_prefers_structured_output(self) -> None:
        self.assertEqual(parse_structured({"summary": "x"}, "garbage"), {"summary": "x"})

    def test_parse_structured_accepts_fenced_json_text(self) -> None:
        text = "```json\n{\"summary\": \"hi\", \"sections\": []}\n```"
        self.assertEqual(parse_structured(None, text)["summary"], "hi")

    def test_parse_structured_rejects_non_json(self) -> None:
        with self.assertRaises(InvalidResponse):
            parse_structured(None, "Đây không phải JSON.")
        with self.assertRaises(InvalidResponse):
            parse_structured(None, None)


class ContextTests(unittest.TestCase):
    def test_split_matches_emacs_line_counting(self) -> None:
        self.assertEqual(split_lines("a\nb\n"), ["a", "b", ""])  # Emacs: 3 lines
        self.assertEqual(split_lines("a\x0cb"), ["a\x0cb"])  # form feed is not a line break
        self.assertEqual(split_lines(""), [""])

    def test_render_uses_absolute_numbers(self) -> None:
        rendered = render_numbered(["x", "y", "z"], 2, 3)
        self.assertEqual(rendered, "     2| y\n     3| z")

    def test_small_file_is_sent_whole(self) -> None:
        root = Path(tempfile.mkdtemp()).resolve()
        source = make_project(root)
        from engine.models.request import parse_explain as parse

        ctx = collect_context(parse(explain_message(root, source, target=(2, 2))))
        self.assertEqual((ctx.window_start, ctx.window_end), (1, 7))
        self.assertFalse(ctx.truncated)
        self.assertEqual(ctx.total_lines, 7)

    def test_large_file_gets_a_window_around_target(self) -> None:
        root = Path(tempfile.mkdtemp()).resolve()
        source = root / "big.el"
        source.write_text("\n".join(f"(setq v{i} {i})" for i in range(1, 1001)), encoding="utf-8")
        from engine.models.request import parse_explain as parse

        ctx = collect_context(parse(explain_message(root, source, target=(500, 500), task="explain_block")))
        self.assertLessEqual(ctx.window_start, 500)
        self.assertGreaterEqual(ctx.window_end, 500)
        self.assertLess(ctx.window_end - ctx.window_start + 1, 1000)
        self.assertIn("   500| (setq v500 500)", ctx.numbered_snippet)

    def test_explain_file_sends_the_whole_large_file(self) -> None:
        root = Path(tempfile.mkdtemp()).resolve()
        source = root / "big.el"
        source.write_text("\n".join(f"(setq v{i} {i})" for i in range(1, 1001)), encoding="utf-8")
        from engine.models.request import parse_explain as parse

        ctx = collect_context(parse(explain_message(root, source, task="explain_file")))
        self.assertEqual((ctx.window_start, ctx.window_end), (1, 1000))
        self.assertFalse(ctx.truncated)
        self.assertIn("     1| (setq v1 1)", ctx.numbered_snippet)
        self.assertIn("  1000| (setq v1000 1000)", ctx.numbered_snippet)

    def test_character_budget_never_drops_the_target(self) -> None:
        root = Path(tempfile.mkdtemp()).resolve()
        source = root / "wide.el"
        long_line = "(setq value \"" + "z" * 500 + "\")"
        source.write_text("\n".join(long_line for _ in range(400)), encoding="utf-8")
        from engine.models.request import parse_explain as parse

        ctx = collect_context(parse(explain_message(root, source, target=(200, 200), task="explain_block")))
        self.assertTrue(ctx.truncated)
        self.assertLessEqual(len(ctx.numbered_snippet), MAX_SNIPPET_CHARS + 50)
        self.assertLessEqual(ctx.window_start, 200)
        self.assertGreaterEqual(ctx.window_end, 200)


class PromptTests(unittest.TestCase):
    def test_render_replaces_every_placeholder_once(self) -> None:
        self.assertEqual(render("a {{x}} b {{y}}", {"x": "1", "y": "2"}), "a 1 b 2")

    def test_values_with_braces_are_not_expanded_again(self) -> None:
        self.assertEqual(render("code: {{snippet}}", {"snippet": "{{y}} {x}"}), "code: {{y}} {x}")

    def test_missing_value_raises(self) -> None:
        with self.assertRaises(PromptError):
            render("{{missing}}", {})

    def test_system_prompt_names_the_output_language(self) -> None:
        prompt = build_system_prompt("Vietnamese")
        self.assertIn("Vietnamese", prompt)
        self.assertNotIn("{{", prompt)
        self.assertIn("READ-ONLY", prompt)

    def test_user_prompt_contains_snippet_and_target(self) -> None:
        values = {
            "task_title": "explain file", "file": "lisp/sample.el", "language": "emacs-lisp",
            "project_root": "/p", "target_start": "2", "target_end": "2", "point_line": "2",
            "symbol": "greet", "symbol_note": ", symbol: greet", "window_start": "1", "window_end": "7",
            "total_lines": "7", "truncated_note": "", "snippet": "     2| body",
        }
        prompt = build_user_prompt("explain_file", values)
        self.assertIn("Target lines: 2-2", prompt)
        self.assertIn("     2| body", prompt)
        self.assertNotIn("{{", prompt)

    def test_fingerprint_depends_on_task(self) -> None:
        self.assertNotEqual(prompt_fingerprint("explain_file"), prompt_fingerprint("explain_function"))

    def test_unknown_task_is_rejected(self) -> None:
        with self.assertRaises(PromptError):
            build_user_prompt("trace_call", {})


class CliArgvTests(unittest.TestCase):
    def _argv(self, **overrides: object) -> list[str]:
        values: dict[str, object] = {
            "json_schema": "{}", "system_prompt": "sys", "session_id": "sid-1", "resume": False,
            "max_budget_usd": 0.5, "model": None,
        }
        values.update(overrides)
        return build_argv("/bin/claude", **values)  # type: ignore[arg-type]

    def test_read_only_flags_are_present(self) -> None:
        argv = self._argv()
        self.assertIn("--restricted", argv)
        self.assertEqual(argv[argv.index("--tools") + 1], ",".join(READ_ONLY_TOOLS))
        self.assertEqual(argv[argv.index("--allowedTools") + 1], ",".join(READ_ONLY_TOOLS))
        self.assertEqual(argv[argv.index("--permission-mode") + 1], "dontAsk")
        self.assertEqual(argv[argv.index("--permission-prompts") + 1], "none")
        denied = argv[argv.index("--disallowedTools") + 1].split(",")
        for tool in ("Bash", "Edit", "Write", "NotebookEdit"):
            self.assertIn(tool, denied)
        self.assertEqual(set(denied), set(DENIED_TOOLS))

    def test_never_skips_permissions(self) -> None:
        self.assertNotIn("--dangerously-skip-permissions", self._argv())
        self.assertNotIn("bypassPermissions", self._argv())

    def test_session_flags(self) -> None:
        fresh = self._argv(resume=False)
        self.assertEqual(fresh[fresh.index("--session-id") + 1], "sid-1")
        self.assertNotIn("--resume", fresh)
        resumed = self._argv(resume=True)
        self.assertEqual(resumed[resumed.index("--resume") + 1], "sid-1")
        self.assertNotIn("--session-id", resumed)

    def test_model_only_when_given(self) -> None:
        self.assertNotIn("--model", self._argv())
        argv = self._argv(model="sonnet")
        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")

    def test_effort_is_passed_and_validated(self) -> None:
        self.assertNotIn("--effort", self._argv())
        argv = self._argv(effort="low")
        self.assertEqual(argv[argv.index("--effort") + 1], "low")
        with self.assertRaises(ValueError):
            self._argv(effort="--dangerously-skip-permissions")

    def test_prompt_is_never_a_positional_argument(self) -> None:
        argv = self._argv()
        self.assertFalse(any("hello" in part for part in argv))

    def test_fake_cli_satisfies_required_flags(self) -> None:
        info = probe_claude(str(FAKE_CLAUDE))
        self.assertTrue(info.flags_ok, info.missing_flags)
        self.assertEqual(info.version, "2.1.330")
        self.assertEqual(set(REQUIRED_FLAGS) - set(info.missing_flags), set(REQUIRED_FLAGS))

    def test_probe_reports_missing_flags(self) -> None:
        # A binary whose help lacks flags should be reported, not trusted.
        info = probe_claude("/bin/echo")
        self.assertFalse(info.flags_ok)
        self.assertTrue(info.missing_flags)

    def test_locate_claude_missing(self) -> None:
        self.assertIsNone(locate_claude("/definitely/not/here/claude"))

    def test_locate_claude_finds_a_bare_name_on_path(self) -> None:
        # The frontend passes the bare name "claude" when only PATH has it.
        found = locate_claude("sh")
        self.assertIsNotNone(found)
        self.assertTrue(found.startswith("/"))

    def test_build_env_drops_named_variables(self) -> None:
        env = build_env({"ANTHROPIC_API_KEY": "k", "PATH": "/bin"}, ("ANTHROPIC_API_KEY",))
        self.assertNotIn("ANTHROPIC_API_KEY", env)
        self.assertEqual(env["PATH"], "/bin")


class SessionStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "sessions.json"

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_ensure_creates_and_reuses_one_id(self) -> None:
        store = SessionStore(self.path)
        first = store.ensure("/proj")
        second = store.ensure("/proj")
        self.assertEqual(first.session_id, second.session_id)
        self.assertFalse(first.resume)

    def test_ensure_persists_before_the_call(self) -> None:
        store = SessionStore(self.path)
        ref = store.ensure("/proj")
        self.assertEqual(SessionStore(self.path).ensure("/proj").session_id, ref.session_id)

    def test_mark_started_switches_to_resume(self) -> None:
        store = SessionStore(self.path)
        ref = store.ensure("/proj")
        store.mark_started("/proj", ref.session_id)
        self.assertTrue(SessionStore(self.path).ensure("/proj").resume)

    def test_reset_forgets_the_project(self) -> None:
        store = SessionStore(self.path)
        store.ensure("/proj")
        self.assertTrue(store.reset("/proj"))
        self.assertFalse(store.reset("/proj"))
        self.assertFalse(store.ensure("/proj").resume)

    def test_corrupt_file_is_ignored(self) -> None:
        self.path.write_text("{not json", encoding="utf-8")
        store = SessionStore(self.path)
        self.assertEqual(store.snapshot(), [])
        self.assertFalse(store.ensure("/proj").resume)

    def test_projects_are_independent(self) -> None:
        store = SessionStore(self.path)
        a = store.ensure("/a").session_id
        b = store.ensure("/b").session_id
        self.assertNotEqual(a, b)

    def test_language_change_starts_a_new_session(self) -> None:
        store = SessionStore(self.path)
        vi = store.ensure("/proj", "Vietnamese")
        store.mark_started("/proj", vi.session_id, "Vietnamese")
        en = store.ensure("/proj", "English")
        self.assertNotEqual(en.session_id, vi.session_id)
        self.assertFalse(en.resume)
        store.mark_started("/proj", en.session_id, "English")
        self.assertTrue(SessionStore(self.path).ensure("/proj", "English").resume)
        self.assertEqual(store.snapshot()[0]["language"], "English")


class CacheTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.cache = ExplanationCache(Path(self._tmp.name) / "cache")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_round_trip(self) -> None:
        key = make_key({"a": 1})
        self.assertIsNone(self.cache.get(key))
        self.cache.put(key, {"summary": "x", "sections": []})
        self.assertEqual(self.cache.get(key)["summary"], "x")
        self.assertEqual(self.cache.count(), 1)

    def test_key_changes_with_any_input(self) -> None:
        base = {"snapshot_hash": "h", "task": "explain_file", "model": None}
        self.assertNotEqual(make_key(base), make_key({**base, "model": "sonnet"}))
        self.assertNotEqual(make_key(base), make_key({**base, "snapshot_hash": "h2"}))
        self.assertEqual(make_key(base), make_key(dict(reversed(list(base.items())))))

    def test_clear_removes_entries(self) -> None:
        for i in range(3):
            self.cache.put(make_key({"i": i}), {"i": i})
        self.assertEqual(self.cache.clear(), 3)
        self.assertEqual(self.cache.count(), 0)

    def test_wrong_schema_is_a_miss(self) -> None:
        key = make_key({"x": 1})
        path = self.cache._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"schema": 999, "payload": {}}), encoding="utf-8")
        self.assertIsNone(self.cache.get(key))


if __name__ == "__main__":
    unittest.main()
