# Doom Code Reader – Engine Protocol (v1)

The Emacs frontend (`doom/code-reader/`) talks to the Python engine (`engine/`)
over a UNIX domain socket. This document is the contract between the two sides.

## Transport

- UNIX stream socket, path supplied by the frontend (`--socket`).
- Framing: one JSON object per line, UTF-8, terminated by `\n`.
- Full duplex and asynchronous. A client may send several requests without
  waiting. The engine answers each request with one or more events that carry
  the request `id`.
- Line numbers are **1-based** and match Emacs `line-number-at-pos` (absolute).
  A text is split with `text.split("\n")`, so a trailing newline produces one
  extra empty last line. `total_lines == len(content.split("\n"))`.

## Client → engine messages

### `ping`
```json
{"type": "ping"}
```
Reply: `pong` (see below).

### `explain`
```json
{
  "type": "explain",
  "id": "r-42",
  "view": "/abs/path/to/file.el",
  "task": "explain_file",
  "project_root": "/abs/project",
  "file": "/abs/project/lisp/foo.el",
  "language": "emacs-lisp",
  "content": "<entire buffer text, widened>",
  "target": {"start_line": 1, "end_line": 900},
  "point_line": 12,
  "symbol": null,
  "explain_language": "Vietnamese",
  "use_cache": true,
  "timeout": 180,
  "model": null
}
```

- `task`: one of `explain_file`, `explain_block`, `explain_function`.
  Other tasks are rejected with `bad_request` in v1.
  - `explain_file` explains the whole file. The engine uses lines `1..total_lines`
    and ignores the client's `target`. Files over 300 000 characters are rejected
    with `bad_request` (`details.reason == "file_too_large"`).
  - `explain_block` and `explain_function` explain only `target`.
- `view`: identifies the explanation pane for the source buffer. A newer
  `explain` for the same `view` supersedes (cancels) the older active one.
- `file` must lie under `project_root` after `realpath`, otherwise `bad_request`.
- `target` must satisfy `1 <= start_line <= end_line <= total_lines` for
  `explain_block` and `explain_function`.
- `symbol` may be `null`. `model` may be `null` (CLI default).
- `use_cache: false` forces a fresh LLM call (used by "refresh").
- `timeout` is seconds. The engine clamps it to a sane maximum.

### `explain` with task `follow_up`

Asks one question about one section of a file, and keeps the answer with that section.

- `task`: `"follow_up"`.
- `question`: required, non-empty, at most 2000 characters. It is trimmed.
- `target`: `{start_line, end_line}` of the section the question is about. It must lie inside the file.
- `view`: use an id of its own, for example `"<file>#chat-<id>"`. The engine supersedes an older request with the same view id, so a question must not reuse the explanation's view id.
- `explanation_key`: required. The `explanation_key` of the `explain` result that the section belongs to. The answer is added to that explanation.
- `use_cache` is ignored. Each question is a new model call.

The engine runs the question in the same Claude session as the explanation for the same language, so the answer can build on it. The answer comes back as a `result` event with `task: "follow_up"`, carrying `question`, `answer` (non-empty, at most 6000 characters), `target`, `created_at`, `explanation_key`, `cache_path`, `document`, `sections`, `session_id`, `session_resumed`, `cost_usd` and `duration_ms`. `document` is the whole explanation, with the answer nested under its section (see [Explanation documents](#explanation-documents)).

Answers are kept in the explanation's document, under the section they are about. A full explanation (`use_cache` false) keeps the answers for the same lines. If the explanation is no longer cached, or has no section for `target`, the request fails with `explanation_missing`, and no model call is made.

### `explain` with task `follow_up_line`

Asks one question about one line of a section, and keeps the answer under that line's detail entry.

- `task`: `"follow_up_line"`. `question` is as for `follow_up`.
- `line`: required, an integer. It must lie inside `target`, and that line must hold code (not be blank).
- `target`: `{start_line, end_line}` of the section the line belongs to, as the explanation has it.
- `explanation_key` and `view` are as for `follow_up`. `use_cache` is ignored.

The prompt gives the model the line, its code, and the line's detail explanation if there is one, so the answer adds to it. The result is a `result` event with `task: "follow_up_line"` and `line`, with the same fields as `follow_up`. `document` holds the answer as plain indented text under the line's item (not a heading, so it never folds away the items after it). Where the line has no item, the question is written at the top level of the detail explanation. If the line is blank or outside the section, the request fails with `bad_request` before any model call.

### `explain` with task `explain_section`

Explains one section again, on its own lines, and makes that the section's explanation.

- `task`: `"explain_section"`. `target` is the section's `{start_line, end_line}`, inside the file.
- `explanation_key`: required, as for a follow-up.
- `view`: use an id of its own, for example `"<file>#refresh-<id>"`, so the request does not supersede the explanation.
- `use_cache` is ignored. The call is always made.

The result is a `result` event with `task: "explain_section"`, carrying `explanation` (non-empty, at most 3000 characters), `target`, `created_at`, `explanation_key`, `document`, `sections` and the usual session and cost fields. The engine rewrites the explanation: the section's text is replaced, the questions asked about the section are removed, and the section carries `refreshed_at`. A full explanation (`use_cache` false) replaces that text again.

### `explain` with task `delete_question`

Removes one question from its section, in the explanation and in its file. No model
call is made.

- `task`: `"delete_question"`. `target` is the question's section `{start_line, end_line}`.
- `explanation_key`: required, as for a follow-up.
- `question_at`: required. The question's `created_at` time, which identifies it.
- `view`: use an id of its own, for example `"<file>#delete-<id>"`.

The result is a `result` event with `task: "delete_question"`, carrying `explanation_key`,
`question_at`, `cache_path`, `document` and `sections`. If the explanation is not cached,
or the question is no longer in the section, the request fails with `explanation_missing`,
and nothing is written.

### `explain` with task `explain_detail`

Adds a line-by-line explanation to every lines group of an explanation.

- `task`: `"explain_detail"`. `target` is ignored: the whole file is used, as for `explain_file`.
- `explanation_key`: required, as for a follow-up.
- `view`: use an id of its own, for example `"<file>#detail-<id>"`, so the request does not supersede the explanation.
- `use_cache` is ignored. The calls are always made.

Each entry is an explanation of exactly two sentences: the decision behind the line, then what would happen without it. Each call also gets the lines group's saved explanation as context. The model may read and search other files in the project (Read, Grep, Glob) to find the reason a line is there.

Each lines group is cut into pieces of at most 40 lines, and each piece is one model call. Three calls run at a time, and each starts a new Claude session, so none of them adds to the session that answers questions. If one piece fails, the request fails and nothing is stored.

The result is a `result` event with `task: "explain_detail"`, carrying `explanation_key`, `cache_path`, `document` and `sections`, where each section has its `detail`. Every group of the file gets a new detail. Questions and the rest of the explanation are kept. `cost_usd` is the total of the calls, or `null`. If the explanation is not cached, the request fails with `explanation_missing` and no model call is made. An answer without a `lines` list fails with `invalid_response`.

### `explain` with task `explain_detail_section`

Adds a line-by-line explanation to one lines group only: the highlighted section.

- `task`: `"explain_detail_section"`. `target` is required, and it must be exactly the lines of the section as the explanation has them (`source_start` to `source_end`). `content` is the whole file, as for `explain_detail`.
- `explanation_key`, `view` and `use_cache` are as for `explain_detail`.

Only that group's pieces are explained, so one request is one model call for a section of up to 40 lines. The other sections keep their details. The result is a `result` event with `task: "explain_detail_section"`, with the same fields as `explain_detail`. If the explanation has no section with exactly that target, the request fails with `explanation_missing` and no model call is made.

### `cancel`
```json
{"type": "cancel", "id": "r-42"}
```
Reply: `cancel_ack` with `active` set to whether a matching request was running.
The cancelled request then emits `cancelled` with `reason: "client"`.

### `reset_session`
```json
{"type": "reset_session", "project_root": "/abs/project"}
```
Reply: `session_reset`. Forgets the Claude session for that project.

### `clear_cache`
```json
{"type": "clear_cache"}
```
Reply: `cache_cleared` with `removed` (count of deleted entries).

### `status`
```json
{"type": "status"}
```
Reply: `status`.

### `shutdown`
```json
{"type": "shutdown"}
```
Cancels active requests, replies `bye`, then the engine exits.

## Engine → client messages

### `pong`
```json
{"type": "pong", "protocol": 1, "engine_version": "0.1.0",
 "claude": {"path": "/Users/x/.local/bin/claude", "version": "2.1.330",
            "flags_ok": true, "missing_flags": []},
 "claude_error": null}
```
`claude` is `null` and `claude_error` is a string when the CLI cannot be found
or probed.

### `cancel_ack`
```json
{"type": "cancel_ack", "id": "r-42", "active": true}
```

### `progress`
```json
{"type": "progress", "id": "r-42",
 "phase": "queued | building_context | running | validating",
 "elapsed_ms": 1234, "output_chars": 560}
```
Emitted at most about twice per second while running. `output_chars` counts
streamed model output characters. It is zero before the first token.
A detail explanation (`explain_detail`) also sends `"steps": {"done": 2, "total": 9}`,
the number of its model calls that have finished and the number it makes in all.

### `result`
```json
{
  "type": "result",
  "id": "r-42",
  "view": "/abs/path/to/file.el",
  "task": "explain_file",
  "file": "lisp/foo.el",
  "snapshot_hash": "9f2c...full sha256 hex...",
  "cache_hit": false,
  "explain_language": "Vietnamese",
  "target": {"start_line": 12, "end_line": 12},
  "explanation_key": "5e0c…64 hex characters…",
  "document": "#+TITLE: lisp/foo.el\n#+STARTUP: overview\n…",
  "summary": "Tóm tắt ngắn...",
  "sections": [
    {"id": "9f2c1a0e-s1", "source_start": 12, "source_end": 12,
     "title": "Gán giá trị", "explanation": "..."}
  ],
  "dependencies": ["..."],
  "data_flow": ["..."],
  "notes": ["..."],
  "warnings": [{"code": "range_out_of_bounds", "message": "...", "section_id": null}],
  "session_id": "e3b5...",
  "session_resumed": false,
  "cost_usd": 0.0011,
  "duration_ms": 4321
}
```

- Section ids are `"<snapshot_hash[:8]>-s<n>"`, stable for a given snapshot.
- Every section already passed validation: integers, `1 <= source_start <= source_end <= total_lines`,
  sorted by `source_start`. Invalid sections are dropped and listed in `warnings`.
- **Sections may overlap** (layered explanations) and **may fall outside the target**
  (related context). Neither is reported as a warning. For "which section contains
  line N", prefer the containing section with the smallest span, and break ties by the
  lower `source_start`.
- Warning codes: `range_out_of_bounds`, `invalid_section`, `empty_explanation`,
  `no_valid_sections`, `context_truncated`. Warnings are informational. Show them, but
  the result is still usable.
- `session_id`, `cost_usd` may be `null` on cache hits.
- `session_resumed` is `true` when the Claude call continued an existing session
  (`--resume`), and `false` when it started a new one. It is `null` on cache hits.
- `document` is the whole explanation as Org-mode text, the form it is cached in. The
  frontend shows it as it is. See [Explanation documents](#explanation-documents).
- `cache_path` is the file the explanation is stored in, as an absolute path, or `null`
  when the explanation has no sections and so is not stored.
- `explanation_key` is the cache key of that document. Send it back with a follow-up
  or a section refresh.
- Each section in `sections` carries `followups`, its questions as
  `{question, answer, created_at, line}`, where `line` is `null` for a question about the
  section, and `refreshed_at`, which is `null` unless the
  section was refreshed. It also carries `detail`, the line-by-line explanation as
  `{line, explanation}` items, which is empty until a detail explanation is asked for.
  The code is not sent: the source pane shows it beside the explanation.

### `error`
```json
{"type": "error", "id": "r-42", "code": "claude_timeout",
 "message": "Claude did not finish within 180s", "retryable": true,
 "details": {}}
```
`id` may be `null` for protocol-level problems. Codes:

| code              | meaning                                                  | retryable |
|-------------------|----------------------------------------------------------|-----------|
| `bad_request`     | malformed or invalid message (file outside project, bad range, unknown task) | no |
| `claude_not_found`| the `claude` binary could not be located                  | no        |
| `claude_timeout`  | the CLI exceeded `timeout`                               | yes       |
| `claude_failed`   | the CLI exited non-zero or reported `is_error`           | yes       |
| `invalid_response`| the CLI output did not match the expected schema         | yes       |
| `explanation_missing` | a follow-up, section refresh, deletion or detail explanation names an explanation that is not cached, or a section the explanation does not have | no |
| `internal`        | unexpected engine bug (details in the engine log)        | no        |

### `cancelled`
```json
{"type": "cancelled", "id": "r-42", "reason": "client | superseded | shutdown"}
```

### `session_reset`, `cache_cleared`, `status`, `bye`
```json
{"type": "session_reset", "project_root": "/abs/project", "had_session": true}
{"type": "cache_cleared", "removed": 7}
{"type": "status", "engine_version": "0.1.0",
 "active": [{"id": "r-42", "view": "...", "task": "explain_file", "phase": "running"}],
 "sessions": [{"project_root": "/abs/project", "session_id": "e3b5...", "started": true}],
 "cache_entries": 7}
{"type": "bye"}
```

## Explanation documents

An explanation is one Org-mode document. It is the cache entry on disk, and the
`document` field of a result. The writer and reader are `engine/org.py`:

- `#+TITLE:` names the file, `#+PROJECT:` the project root, `#+KEY:` the full cache key,
  and `#+MODEL:` the model the request asked for (`default` when none). The client reads
  the file in the cache directly, and checks the model before showing it.
- `* Summary` comes first, then one heading per section in file order:
  `* Lines A–B · title`. Then `* Dependencies`, `* Data flow`, `* Notes` and
  `* Warnings`, each present only when it has items.
- Each heading has a property drawer. A section's drawer has `:KIND: section`,
  `:SECTION_ID:` and `:LINES: A-B`, plus `:REFRESHED:` after a section refresh.
- A question about the section is a `** Question: ...` heading under its section, with `:KIND: question`
  and `:CREATED:`. Its answer is the body.
- A question about a line is text under that line's item, indented by four spaces:
  `Question about line N (asked CREATED, FINGERPRINT): text`, then an `:ANSWER:` drawer
  whose answer is indented by six, and `:END:`. The drawer lets TAB fold the answer. It is
  not a heading, because a heading would fold away the items after it.
- A detail explanation is a `** Detail explanation` subsection under its section, with
  `:KIND: detail`, written before the questions. Each line of code is an item,
  `  - LINE`, with its explanation indented on the next line. The code is not written, so
  the explanation is read next to the source. Blank lines have no item. A line the model
  did not explain says so in its explanation. The drawer also has `:FINGERPRINT:`, a short
  hash of the lines the detail was made from, which a refresh checks before it keeps the
  detail. An explanation saved by an earlier version may still have `  - LINE · code`
  items. They are read, but they have no fingerprint, so a full refresh drops that detail
  and it has to be asked for again.
- Body text is indented by two spaces, so text from the model cannot start a heading
  or a drawer.

Files are stored under `cache/<project folder>/<file path in the project>/`, as
`<scope>-<language>-<8 key chars>.org`, where the scope is `whole-file` or `lines-A-B`.
A lookup finds the file by its name, then checks the `#+KEY:` line. Entries written in
earlier layouts (JSON, or hash-named folders) are never read. `clear_cache` removes them.

## Lifecycle notes for the frontend

- The engine is started by Emacs (`python3 -m engine --socket PATH ...`). The
  frontend connects, retrying briefly until the socket exists.
- The engine exits after an idle period with no connected clients
  (`--idle-timeout`). The frontend must reconnect (and restart the engine if
  needed) on the next command.
- Ignore events whose `id` no longer matches the pending request for that
  view. This prevents late results from overwriting newer ones.
- Only the `result` event contains explanation content. `progress` is for
  the status line.
