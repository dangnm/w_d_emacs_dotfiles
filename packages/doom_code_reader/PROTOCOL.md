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
