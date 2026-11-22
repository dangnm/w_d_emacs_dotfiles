# Architecture: Org-mode Code Reader

Design for [PR #2](https://github.com/dangnm/w_d_emacs_dotfiles/pull/2), `doom_code_reader_org_mode` into `main`.
It describes the code committed as `342138f`, which matches the working tree.

This is not the user manual (see [README.md](README.md)) or the wire contract (see [PROTOCOL.md](PROTOCOL.md)).
It explains how the parts fit, why they are split this way, and what a reviewer should check.

---

## 1. What the PR does

- Replaces the JSON explanation cache and the Emacs-side section rendering with **one Org-mode document per explanation**. The right pane is an `org-mode` buffer, and the cache file is that same text.
- Questions asked about a section, and section refreshes, are stored **inside that document** as nested headings. The engine writes them. Emacs displays them.
- Opening a file reads a **saved explanation directly from disk**, so the Python engine does not start when an explanation already exists.
- The cache is **browsable**: `cache/<project>-<hash>/<file path>/<scope>-<language>-<key8>.org`.
- New commands: `p` copies the cache path, `d` deletes a question through the engine. `g` and `M-x code-reader-clear-cache` ask for confirmation first.
- Cursor and scroll sync rules are reworked. Fold state, cursor position and the key table are kept across redraws.

Size: 26 files, about 3,600 lines added and about 400 removed. Tests: 123 Python, 82 ERT.

## 2. Goals and non-goals

**Goals**

- Explain a whole file in one Claude call, not per line. The reader scrolls, and the explanation follows.
- Keep explanations readable and foldable.
- A saved explanation lasts until the reader asks to regenerate it (`g`).
- Claude is read-only. Emacs never writes explanation files; only the engine does.
- Start the engine only when Claude is needed, or when the engine must change a file.

**Non-goals for this PR**

- Migrating the old JSON or hash-folder caches (they are ignored and cleared).
- Checking prompt versions when a saved explanation is opened (see §13).
- Phase 2 features (tree-sitter, LSP).
- Verifying the GUI automatically. The batch tests cannot measure what is on screen (see §12).

## 3. System overview

```
 Emacs (doom/code-reader/*.el)                       Python engine (engine/)
 +------------------------------------+  UNIX socket  +---------------------------------------+
 | layout, org-mode explanation pane  |<--- NDJSON -->| server.py -> requests.py (registry)   |
 | question box, key table, sync      |               |   -> orchestrator.py                  |
 | transport (start, connect, retry)  |               |        models/  request, response    |
 | cache reader: saved explanation    |               |        context/ numbered snapshot    |
 +-----------------+------------------+               |        prompts/ templates            |
                   | reads, no engine                |        claude/  cli, stream, session |
                   v                                 |        org.py   document format      |
 ~/.cache/doom-code-reader/cache/  <---- writes ------|        cache.py ExplanationCache     |
                                                     +-----------------+---------------------+
                                                                       | claude -p (read-only)
                                                                       v
                                                                 Claude Code CLI
```

The cache directory is the shared state. Emacs may read it without the engine. Only the engine writes it.

## 4. Components

### 4.1 Engine (Python, standard library only)

| Module | Responsibility |
|---|---|
| `server.py` | asyncio UNIX server. NDJSON framing. Routes `explain`, `ping`, `cancel`, `reset_session`, `clear_cache`, `status`, `shutdown`. Exits after 30 minutes with no client. |
| `protocol.py` | Message constructors and the list of error codes. |
| `requests.py` | `RequestRegistry`. Active requests by id and view. A newer request for the same view supersedes the older one. |
| `models/request.py` | Validates every `explain` message: task, project root, file under the project (after `realpath`), target range, explanation key (64 hex, since it becomes a file name), size limits. |
| `models/response.py`, `schema.py` | Normalises Claude's structured output. Line numbers are checked against the snapshot, and text is capped. Holds the JSON schemas. |
| `context/collector.py` | Builds the numbered snapshot sent to Claude. `explain_file` sends the whole file (up to 300 000 characters). Other tasks send a window around the target. |
| `prompts/` | `base_system.md` (read-only charter, output language, Org formatting rule) and one template per task. The prompt fingerprint is part of the cache key. |
| `claude/cli.py` | Finds the `claude` binary, checks required flags, builds argv (read-only tools, `--restricted`, `dontAsk`, budget cap, `--effort low`, session flags). No shell. |
| `claude/stream_parser.py` | Reads `stream-json` output. Counts progress and extracts the result. |
| `claude/session.py` | `SessionStore`: one Claude session per (project root, explanation language), in `sessions.json`. Resumed with `--resume`. |
| `org.py` | The document format. `render()` is the only writer, `parse()` the only reader. Body text is indented, so model text cannot start a heading. |
| `cache.py` | `ExplanationCache`: folder layout, `locate()` by key prefix then full-key check, atomic `put()`, `count()`, `clear()`. |
| `orchestrator.py` | Pipeline for `explain`, `follow_up`, `explain_section`, `delete_question`. Carries questions over on full regeneration. Builds result messages. |

### 4.2 Emacs frontend (`doom/code-reader/`)

| Module | Responsibility |
|---|---|
| `code-reader.el` | Customisation group, autoloads, requires. |
| `code-reader-transport.el` | Starts the engine with `make-process`, connects over the UNIX socket with retries, encodes and decodes NDJSON, shuts down. |
| `code-reader-session.el` | `code-reader-view` struct (one per source buffer). Builds requests, dispatches events, applies results, shows saved explanations, handles deletion events. |
| `code-reader-cache.el` | Reads a saved whole-file explanation from disk without the engine. Computes folder and file names the same way the engine does. |
| `code-reader-ui.el` | Two-window layout. Explanation mode, derived from `org-mode`. Keymap, including evil motion state. Renders the document, restores folds and cursor anchors, indexes sections. |
| `code-reader-sync.el` | Scroll and cursor sync rules A to E, with idle-timer debounce and recursion guards (§9). |
| `code-reader-highlight.el` | Fringe bars and range marks. Pure section-lookup functions, unit-testable without buffers. |
| `code-reader-chat.el` | Question box in the bottom panel. Sends `follow_up`. |
| `code-reader-guide.el` | Key table in the bottom panel, and the rules for entering and leaving the explanation pane. |
| `code-reader-commands.el` | Interactive commands: open, explain, refresh (confirms), refresh section, delete question (confirms), copy cache path, clear cache (confirms), toggle, close, status, shutdown. |

## 5. The explanation document

The document is Org text. The same text is the cache file and the right pane.

```org
#+TITLE: lisp/sample.el
#+PROJECT: /Users/me/dotfiles
#+KEY: 9f0c...64 hex...
#+MODEL: default
#+STARTUP: overview
#+OPTIONS: ^:nil

* Summary
  :PROPERTIES:
  :KIND: summary
  :END:
  What the file is for.

* Lines 1-3 · Greet
  :PROPERTIES:
  :KIND: section
  :SECTION_ID: 9f0c1a2b-s1
  :LINES: 1-3
  :END:
  What these lines do.

** Question: why message?
   :PROPERTIES:
   :KIND: question
   :CREATED: 2026-11-22T10:00:00.000001+00:00
   :END:
   The answer, indented.

* Dependencies
  :PROPERTIES:
  :KIND: dependencies
  :END:
  - subr-x
```

Rules:

- Each heading has a property drawer with `:KIND:`. Sections also have `:SECTION_ID:` and `:LINES:`, and `:REFRESHED:` after a section refresh.
- Questions are `**` headings nested under their section. Their identity is `:CREATED:`, a microsecond timestamp.
- Section ids are `<snapshot hash, 8 chars>-s<n>`. They are stable for the life of the document.
- Body text is indented by two spaces. Model text therefore cannot create a heading, a drawer or a keyword.
- Both sides read the format. The engine uses `org.py`. Emacs reads the same properties in `code-reader-cache.el`, with a small reader for headings and `:SECTION_ID:`.

## 6. Storage

```
~/.cache/doom-code-reader/cache/
└── dotfiles-ff7dbe/                          <project name>-<first 6 hex of sha256(root path)>
    └── packages/doom_code_reader/engine/
        └── protocol.py/                      source file, at its path in the project
            ├── whole-file-English-a1b2c3d4.org
            └── lines-12-20-English-9e8f7a6b.org
```

- **Scope:** `whole-file`, or `lines-A-B` for blocks and functions.
- **Key:** SHA-256 of canonical JSON of `context_version`, `task`, `target` (`whole_file` for `explain_file`), `symbol`, `explain_language`, `model`, `project_root`, `file`, and the prompt fingerprint (SHA-256 of `base_system.md` and the task template). The source text is not part of the key.
- **Lookup:** in the engine, take the file's folder, then match `*-<key8>.org`, then require `#+KEY:` to equal the full key. In Emacs, for whole-file explanations, take the newest `whole-file-<language>-*.org` whose `#+MODEL:` equals the model setting (a missing header counts as `default`).
- **Lifetime:** until `g`, `clear-cache`, or a manual delete. A prompt change takes effect on `g`, not on open (see §13).
- **Legacy:** JSON files and hash-folder entries are never read. `clear-cache` removes them.

## 7. Protocol summary

Explanation tasks go through `explain`:

| Task | Calls Claude | Changes the file | Needs key | Result carries |
|---|---|---|---|---|
| `explain_file`, `explain_block`, `explain_function` | Only on a cache miss | Writes the explanation | No | `document`, `sections`, `cache_path`, `explanation_key` |
| `follow_up` | Yes | Adds a question under its section | Yes | `answer`, `document`, `sections` |
| `explain_section` | Yes | Replaces the section text and removes its questions | Yes | `explanation`, `document`, `sections` |
| `delete_question` | **No** | Removes one question | Yes | `document`, `sections`, `cache_path` |

Other messages: `ping`/`pong`, `cancel`/`cancel_ack`, `reset_session`, `clear_cache`, `status`, `shutdown`/`bye`, `progress`, `cancelled`, `error`.

Error codes: `bad_request`, `claude_not_found`, `claude_timeout`, `claude_failed`, `invalid_response`, `explanation_missing`, `internal`.

`explanation_missing` covers a follow-up, refresh or deletion that names an explanation that is no longer cached, or a section or question that no longer exists. Nothing is written in that case.

## 8. Key flows

**8.1 Open a file (`SPC c r`)**
1. `code-reader-open` calls `code-reader-explain-file`, then `commands--explain`.
2. Emacs looks for a saved whole-file explanation (`code-reader-cache-find`).
3. If one is found, `code-reader-session-show-cached` sets the view to `explain_file` with status `cached`, then renders and places it. **The engine is not started.**
4. If none is found, the executables are checked, the panes open, and `session-explain` connects. That starts the engine. The engine misses the cache, calls Claude, stores the file, and returns the result.

**8.2 Regenerate (`g`)**
1. `y-or-n-p` asks first, naming the saved file.
2. `explain` with `use_cache=false`. Claude is asked again.
3. The new document replaces the file. Questions on lines that still match are carried over. Section refreshes are superseded.

**8.3 Ask a question (`a`, then RET in the box)**
1. `follow_up` for the highlighted section. The Claude session for the project and language is resumed.
2. The engine adds a `**` question under the section and returns the whole document.
3. Emacs re-renders. The section opens, with the new question visible and its answer folded.

**8.4 Refresh one section (`r`)**
1. `explain_section` for the highlighted section's lines.
2. The section text is replaced and its questions are removed. The rest of the document is unchanged.
3. No confirmation: only one section changes.

**8.5 Delete a question (`d`)**
1. Point must be on a `**` question heading or in its text. Otherwise the command refuses without asking.
2. `y-or-n-p` asks first, showing the question text.
3. `delete_question` removes the question in the engine, with no Claude call. The view re-renders with its anchors kept.

**8.6 Copy the cache path (`p`)**
The path goes to the kill ring and the clipboard, and the echo area shows it. Clipboard: the window-system selection in a GUI, or `pbcopy` in a terminal on macOS.

**8.7 Clear the cache (`M-x code-reader-clear-cache`)**
`y-or-n-p` asks first. The engine deletes every `.org` and legacy `.json` file under the cache directory, then the folders left empty.

## 9. Scroll and cursor sync

| Rule | Trigger | Effect | Guard |
|---|---|---|---|
| **A** | Source scrolled, point not moved | Section at the middle of the source goes to the top of the explanation | Skipped when a cursor move caused the scroll, because C handles that case |
| **B** | Explanation scrolled | Source scrolls to the start of the section at the top. Point in the source does not move | Size-only changes are ignored |
| **C** | Point enters a different section | That section is highlighted and moved to the top of the explanation, even if it is already visible. If it has a detail explanation that is folded, the section and the detail are opened first | Debounced 0.1 s idle timer |
| **D** | RET or click in the explanation | Source point moves to the section, and its range is highlighted. On a detail line, the point goes to that source line alone and only it is marked | Mouse entry is excluded from the entry rule below |
| **E** | Point moves onto a detail line in the explanation | That detail line is highlighted, and only its source line is marked and shown in the middle of the source | Debounced idle timer, skipped when that line is already highlighted |

A detail line is one `  - N` entry of a section's `** Detail explanation`, with its explanation lines (`code-reader-ui-detail-entries`). When the cursor moves into a section that has a detail, `code-reader-ui-show-detail` opens the section and its detail if the detail is folded, so its lines are on screen. A section with no detail is left as it is. When the source point or the explanation point is on a detail line, that line is highlighted instead of the section, and A, B and C show it in the middle of the pane (`code-reader-sync--centre`), so the lines around it are in view. When a detail explanation arrives, the line under the source point is highlighted again, without moving the pane (`code-reader-sync-refresh-highlight`).

Also: entering the explanation from the source with a key puts the cursor on the highlighted section's heading, or on the highlighted detail line. If that place is out of view, the pane scrolls to it first. The key table is shown after the cursor is placed, so the next command does not hide it.

Guards: `code-reader-sync--syncing` (set while code moves a window), `sync-target` and `sync-detail-line` (the section and detail line last placed), and the recorded start and size of the pane after every programmatic change. Scroll events are debounced with idle timers.

## 10. State, concurrency and redraws

- **Single writer.** Only the engine writes explanation files. Each write is a read-modify-write inside one synchronous step of the asyncio loop, so follow-ups, refreshes and deletions cannot interleave. A full regeneration rereads the file after Claude returns, so a question asked while Claude was working is kept.
- **Sessions.** One Claude session per project and language. A lock per project queues requests, and the view shows `queued`.
- **Emacs state.** Views are kept in one global registry. Events are matched by request id, and stale events are dropped.
- **Redraws.** `code-reader-ui-render` erases and rebuilds the explanation. It restores:
  - the open or folded state of each section (`expanded` keys);
  - the window's top line and cursor, as anchors of (section id, lines from its heading, column);
  - the cursor's screen position. If the cursor would fall below the window, the top moves up to keep it visible.
- **Why anchors.** A plain text position moves when content above it changes. A section id plus a line offset does not.

## 11. Security model

- Claude runs with `--restricted`, the read-only tools `Read`, `Grep` and `Glob`, `--permission-mode dontAsk`, and no Bash, Edit, Write or web tools. It ignores the user's settings, so hooks do not run. A budget cap applies (default 1.00 USD per call), with effort `low`.
- File paths must lie under the project root after `realpath`.
- Explanation keys are checked as 64 hex digits before they become file names.
- Cache paths are computed by the engine. The client never supplies a path.
- Subprocesses use argument arrays, never a shell.
- Logs record metadata only (request ids, sizes, hashes, phases), not source text.
- The engine has no network port. It listens on a UNIX socket in the state directory.
- Explanation files hold model output and text from the source. They are ordinary files in the user's cache directory.

## 12. Testing

- **Python** (149 tests): unit tests for parsing, validation, the Org round trip and the cache; pipeline tests for the orchestrator (fake CLI), cancellation and supersede, the socket server, and a subprocess engine.
  `python3 -m unittest discover -s tests -t . -p 'test_*.py'`
- **ERT** (116 tests, batch; one is skipped unless evil-snipe is on the load path): sync, highlight, detail-line and fold logic; the question box; the key table; saved-explanation lookup; deletion and confirmations; and an end-to-end test through the real engine with the fake CLI. The end-to-end test also checks that Emacs finds the file the engine wrote.
  `emacs -Q --batch -L doom/code-reader -L tests/elisp -l tests/elisp/code-reader-test.el -f ert-run-tests-batch-and-exit`
- **Real CLI** (manual, not in CI): a 77-line file took 23 s and about 1.8 cents. A follow-up question took about 8 s.

**Gaps.** Batch Emacs has no layout, so it cannot check what is on screen. `pos-visible-in-window-p` reads the last redisplay, so the code counts lines with `vertical-motion` instead, and the tests state their premises with the same helper. Not covered: GUI rendering, fringe bars, evil keys, the author's Doom configuration, several Emacs instances on one state directory, and Org versions other than 9.6.15.

## 13. Risks and limitations

| # | Risk | Impact | Status |
|---|---|---|---|
| 1 | A saved explanation is shown on open without checking the prompts | After a prompt change, the old explanation stays until `g` | Accepted by design, since the cache should last until `g`. A fingerprint check in Emacs is possible (hash the prompt files) |
| 2 | GUI behaviour is unverified | Folds, cursor placement, marks and the panel may differ from the tests | Needs manual review (§14) |
| 3 | Org API dependency | Uses `org-fold-*` and `org-end-of-meta-data`, which exist in Org 9.6+ | Tested on 9.6.15, the version bundled with Emacs 29.4 |
| 4 | Doom's evil-org | Could bind keys in the explanation pane | A hook turns evil-org off in that pane. Other Doom Org modules are untested |
| 5 | Cache grows without limit | Disk use | Only `clear-cache` removes files. No size or age limit |
| 6 | Deleting a question and asking follow-ups start the engine | Slower than a local edit | By design. Both are manual actions, and deletion avoids a race with the engine |
| 7 | Clipboard | Terminal copy only works with `pbcopy` (macOS) | GUI uses the window-system selection |
| 8 | Legacy caches | Old explanations and answers are not carried over | Ignored and cleared by `clear-cache` |
| 9 | Several Emacs instances on one state directory | Unknown | Not tested |
| 10 | Document size | Every answer returns the whole document, so repeated questions make a large response | Acceptable at current sizes. Watch it on long files |

## 14. Manual review checklist (GUI)

1. `SPC c r` on a file with a saved explanation: the panes open at once, and the `*code-reader-engine*` buffer does not appear.
2. Move the source cursor line by line across a section boundary. The explanation moves to that section's heading.
3. `TAB` folds and unfolds a section. `S-TAB` folds or unfolds all sections.
4. Ask a question in the box. The question appears under its section, the section opens, and the answer is folded.
5. `d` on a question: the prompt appears, and "yes" removes it from the pane and the file.
6. `g`: "no" changes nothing. "yes" regenerates, and questions on unchanged lines are kept.
7. `M-x code-reader-clear-cache`: "no" deletes nothing.
8. `p`: the path appears in the echo area, and pasting it elsewhere gives the path.
9. Page up and page down in the source move the explanation. Single-line moves do too.

## 15. Decisions

| Decision | Reason | Alternatives considered |
|---|---|---|
| Org document is both the cache and the display | Folding, readable, and greppable from one text | JSON cache with Emacs rendering (hard to fold or edit); Markdown (no folding) |
| The engine is the only writer of explanation files | Avoids races between follow-ups, refreshes and deletions. Key checks stay in one place | Emacs writes files directly |
| Emacs reads saved explanations | Opening a file must not start Python when the explanation exists | Always ask the engine (rejected) |
| Questions live inside the document | One file to browse. Questions survive `g` by line range | Separate follow-up store (two sources of truth, the previous design) |
| Deletion goes through the engine | Single writer. No Claude call | Emacs edits the file |
| Folders by project and file path | Browsable in Finder and Emacs | Hash-prefix folders (unreadable, which was the original layout) |
| Model in the header, prompts not checked on open | Cheap check without the engine | Fingerprint in Emacs (possible, more code) |

## 16. Questions for reviewers

1. Is it acceptable that a prompt change takes effect on `g` rather than on open (§13, item 1)?
2. Is it acceptable that deleting a question starts the engine (§13, item 6)?
3. Are the keys `g`, `r`, `a`, `c`, `d`, `p`, `t`, `q`, `TAB` and `S-TAB` free in your Doom setup, and do they fit with evil motion state?
4. Should `r` (section refresh) ask for confirmation too? It currently does not, since it changes one section.
5. Should the summary stay open by default?

## 17. Suggested PR description

The PR currently has an empty description. This document's sections 1, 3 and 16 would make a short one.
