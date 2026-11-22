# Doom Code Reader

An AI-assisted code reader for Doom Emacs. The source stays on the left and
explanations appear on the right, organised into sections that line up with the
code. Scrolling either pane moves the other. The explanations come from the
Claude Code CLI, which runs in read-only mode and never edits your files.

Status: **Phase 1 (MVP)**. See [Roadmap](#roadmap).

## How it fits together

```
 Doom Emacs (doom/code-reader/*.el)            Python engine (engine/)
 ┌──────────────────────────────┐   UNIX     ┌──────────────────────────────┐
 │ two-pane UI, scroll sync,    │◄──socket──►│ request validation, cache,   │
 │ highlights, click-to-jump    │  NDJSON    │ context window, prompts,     │
 └──────────────────────────────┘            │ session store, claude runner │
                                             └──────────────┬───────────────┘
                                                            │ claude -p
                                                            │ --output-format stream-json
                                                            ▼
                                                     Claude Code CLI (read-only)
```

- The engine is a standard-library-only Python daemon. Emacs starts it on demand
  and it exits after 30 minutes without clients.
- Emacs talks to it over a UNIX socket with one JSON object per line. The
  contract is in [PROTOCOL.md](PROTOCOL.md).
- Each project gets its own Claude session, so follow-up explanations reuse
  context. Sessions are resumed with `--resume`.
- Each explanation is an Org document, cached on disk under a key made from task,
  target, language, model, and prompt version. The cache file is the document the
  right pane shows. It stays until you press `g`: editing the source does not expire
  it. A change to a prompt applies when you next press `g`. See [Where explanations are
  stored](#where-explanations-are-stored) for the folder layout.

## Requirements

- macOS or Linux, GNU Emacs 29+ (developed on 29.4), Doom Emacs.
- Python 3.10+ (no third-party packages).
- The Claude Code CLI (developed on 2.1.330). The engine checks the flags it
  needs at startup and reports any that are missing.
- A Claude login (`claude` run once interactively), or an API key.

## Setup

The dotfiles' `doom_3_0_0_pre_config.org` already loads the package and binds
the keys (section "Code reader config"). After pulling the change, run
`SPC h r r` or `doom sync`, then restart Emacs.

To load the package without Doom, add it to `load-path` and call
`code-reader-open`.

### Settings

All settings live in the `code-reader` customize group (`M-x customize-group`):

| Variable | Default | Purpose |
|---|---|---|
| `code-reader-python-command` | `"python3"` | interpreter for the engine |
| `code-reader-claude-command` | auto | path to `claude` (`~/.local/bin/claude`, then `PATH`) |
| `code-reader-explain-language` | `"English"` | language of explanations (change it with `M-x code-reader-set-language`) |
| `code-reader-timeout` | `300` | seconds before a request is abandoned (whole-file explanations can take minutes) |
| `code-reader-model` | `nil` | model alias for the CLI (`nil` = CLI default) |
| `code-reader-effort` | `"low"` | reasoning effort (`low`, `medium`, `high`, `xhigh`, `max`). Low is several times faster and cheaper. Run `code-reader-shutdown-engine` after changing it |
| `code-reader-claude-env-remove` | `("ANTHROPIC_API_KEY")` | variables removed before calling `claude` |
| `code-reader-state-directory` | `~/.cache/doom-code-reader/` | cache, sessions, logs (see [Where explanations are stored](#where-explanations-are-stored)) |

`code-reader-claude-env-remove` defaults to dropping `ANTHROPIC_API_KEY`. The
CLI then uses your claude.ai login. An exhausted or invalid key in the shell
would otherwise make every request fail with "Credit balance is too low".
Set the list to `nil` to use the key instead.

### Where explanations are stored

Explanations live in `cache/` under the state directory, one folder per project.
Inside it, the folder tree follows the source file's path in the project:

```
cache/
└── dotfiles-3f9a2c/                          project folder: name + short hash of its root path
    └── packages/doom_code_reader/engine/
        └── protocol.py/                      the source file, at its path in the project
            ├── whole-file-English-a1b2c3d4.org
            └── lines-12-20-English-9e8f7a6b.org
```

Each `.org` file is one explanation, as an Org document. Its header names the project
(`#+PROJECT:`) and the full cache key (`#+KEY:`). The eight characters in the file name
are the start of that key. The engine checks the full key before it uses a file.
Press `p` in the explanation pane to show the file's path and copy it to the clipboard.
Opening a file reads its saved explanation directly, so the engine does not start for
it. The engine starts only when Claude is needed: for a new explanation (`g`), a
question, a section refresh, or a detail explanation (`D`). `code-reader-clear-cache` removes every explanation, in every project, after asking
yes or no.

## Usage

| Key | Command | What it does |
|---|---|---|
| `SPC c r` | `code-reader-open` | open the two-pane view. If the file has a saved explanation, it is shown and the engine is not started; otherwise the whole file is explained |
| `SPC c b` | `code-reader-explain-block` | explain the active region |
| `SPC c F` | `code-reader-explain-function` | explain the function at point |

Opening a file sends its whole content to Claude once. The explanation has a
section for each top-level definition, in file order, so you scroll the source
to the part you need and the explanation follows. The result is cached, so
reopening is instant. Press `g` to regenerate after the file changes. Files over
300 000 characters are rejected with a message. Explain a region or function
instead.

**Reading the explanation.** The right pane is an Org buffer. Each section is a
heading, and the sections start folded. `TAB` folds and unfolds the section at
point, or one line's detail item when point is on that item (from anywhere on its
line), and `S-TAB` folds or unfolds all of them. A detail item's fold is not kept when
the explanation is redrawn, for example after a question is answered.

**Asking about a section.** Under the explanation pane is a question box. Its
header shows the lines it is about: the section highlighted in the explanation,
which is the section that holds the source point. Type a question and press
`RET`. The answer is added to the explanation as a heading nested under that
section, `** Question: ...`, and the section opens to show it. The answer stays
folded until you press `TAB` on the question.

**Asking about a line.** When the highlighted line has a detail entry (the source
point is on it, or you pointed at it in the explanation), `a` asks about that line
instead. The header then says `About line 19 of lines 1–60`. The answer appears under
that line's entry, in a drawer. `TAB` on the question, or anywhere in its answer, folds
the answer away, and `TAB` again opens it. The answer is not a heading, because folding a
heading would hide the lines after it. `d` on the question or its answer deletes it. A full refresh (`g`) keeps the question while its line is
unchanged, and a section refresh (`r`) removes it. The question is kept in the cache
file, so reopening the file shows it again. `a` in the explanation pane moves to
the box. From the box, press `ESC` and then `C-w k` to
go back. A question sends the file text and the section's lines, and Claude can
read other files in the project to answer.

**Line-by-line detail.** `D` in the explanation pane explains the whole file in detail.
It asks yes or no first, because it takes several minutes. It adds a `** Detail explanation`
subsection to every section: each line of code in the section, top to bottom, with the
line number underneath. Each explanation is two sentences: the decision behind the line
(why it is there), then what would happen without it, so the flow of the code is clear.
The model reads the section's explanation, and it searches the project for the names a
line uses, so the reason can come from other files that use the same code. The code itself is not
repeated, because the source pane shows it, and each explanation maps to its line there. The subsection
starts folded; `TAB` opens it, and after `D` the details are open. A section is cut into
pieces of about forty lines, and the pieces are explained a few at a time, so a long file
takes a few minutes. The top of the explanation pane shows the status:
`Detail explanation running: 2 of 9 pieces done · 41s`, or `failed` with the reason until
you try again. `c` cancels. The details are kept in the cache file with the rest.
Pressing `D` again replaces them. A full refresh (`g`) keeps a section's detail while
none of its lines changed, and drops it when one did.

`s` explains only the highlighted section in detail. It starts without a question,
because it is one section's worth of calls, and it replaces only that section's detail.

`M-x code-reader-explain-file` runs the same whole-file explanation without
opening the layout.

In the explanation pane: `RET` or click jumps to the source (on a folded detail item, `RET` opens it instead), `TAB` folds or
unfolds a section, `g` refreshes (bypasses the cache; it asks yes or no first, because it replaces the saved file), `r` refreshes only the
highlighted section (the lines the question box is about) and leaves the rest of
the explanation as it is, `c` cancels, `p` shows the explanation's cache file and copies its path, `d` deletes the question
at point after asking yes or no (it is removed from the saved file too), `D` explains the whole file in detail after a yes or no (see below), `s` explains the highlighted section in detail, `C` collapses every section (only the headings show), `t` toggles
the pane, `q` closes it. A
section refresh is kept with its section, so it survives later explanations until a
full refresh (`g`) replaces the whole explanation. It also resets the section: its
questions are removed from the explanation.
Moving the cursor from the source into the explanation pane (`C-w l`, or a click)
shows a small table of the pane's keys in a bottom panel under it. The panel also holds the question box: selecting the panel (`C-w j`, or `a`) clears the table and shows the box, ready to type. The panel is on screen only while the cursor is in it, or while the key table is up; otherwise the explanation takes the whole column. The table goes away when the
cursor moves inside the pane, or when you move back to the source.

Other commands (run with `M-x`): `code-reader-cancel`,
`code-reader-clear-cache`, `code-reader-reset-session`,
`code-reader-show-status`, `code-reader-set-language`,
`code-reader-shutdown-engine`.

Closing the reader restores the original window layout.

### Scrolling and highlights

- Scrolling the source with the mouse or scroll keys, without moving point, moves
  the explanation pane to the section covering the middle of the visible source.
  Point in the source does not move.
- Moving point in the source marks the section that covers it with a fringe bar.
  When point enters a different section, that section is placed at the top of the
  explanation pane, even if it is already on screen, so the pane follows the cursor
  line by line. Page keys usually move point too, and then they follow the cursor the same way.
  This never calls Claude.
- Scrolling the explanation pane brings the matching source region into view and
  marks it with a bar in the left fringe.
- With a detail explanation open, a line with its own detail entry is selected on
  its own. Point on that source line highlights its entry in the explanation, and
  point on the entry marks only its source line in the source pane. The selected
  line is shown in the middle of its pane, so the lines around it are in view. `RET` on an
  entry jumps to that line alone. When the cursor moves into a section that has a
  detail explanation and the detail is folded, the detail opens, so the line is
  selected in it. A section without a detail stays as it is. Scrolling the source
  without moving point does not open anything.
- Explanations stay until you press `g`. Editing the source does not expire them,
  and the header does not change. Line numbers in an explanation refer to the text
  when it was made, so press `g` after large edits.

## Security model

This is a comprehension tool and must not change code. Several layers enforce
that:

1. `--restricted`: the CLI removes Bash and other code-running tools, ignores
   your user, project, and local settings (so your hooks do not run), and
   confines file tools to the project directory.
2. `--tools Read,Grep,Glob` limits the built-in tools to read-only ones.
3. `--allowedTools` pre-approves only those tools.
4. `--disallowedTools` explicitly denies Bash, Edit, Write, NotebookEdit,
   WebFetch, and WebSearch.
5. `--permission-mode dontAsk` plus `--permission-prompts none` turns any other
   request into a denial. Nothing waits for input.
6. `--dangerously-skip-permissions` is never used.

Other safeguards:

- The engine only accepts files inside the project root (after `realpath`), so
  symlinks and `..` cannot escape it.
- Subprocesses are started with argument arrays, never through a shell.
- Each call has a spending cap (`--max-budget-usd`, default 1.00 USD).
- Logs record metadata only: request ids, sizes, hashes, phases. Source code is
  never logged. Note that the Claude CLI itself keeps session transcripts under
  `~/.claude`, as it does for any session.

## Engine command line

```
python3 -m engine --socket PATH --state-dir DIR [--claude-bin BIN]
                  [--drop-env VAR]... [--idle-timeout SEC]
                  [--max-budget-usd N] [--model M] [--effort low|medium|high|xhigh|max]
                  [--log-level LEVEL]
```

The engine is started by Emacs. You can run it by hand for debugging and send it
NDJSON messages with `nc -U PATH`.

## Tests

Run from this directory:

```sh
# Engine: 115 tests, including real-socket and subprocess end-to-end tests.
# They use tests/fixtures/fake_claude.py, so no API calls are made.
python3 -m unittest discover -s tests -t . -p 'test_*.py'

# Emacs Lisp: ERT tests (batch mode).
emacs -Q --batch -L doom/code-reader -L tests/elisp \
      -l tests/elisp/code-reader-test.el -f ert-run-tests-batch-and-exit
```

`tests/fixtures/real_stream_*.jsonl` are trimmed captures from Claude Code
2.1.330. They pin the stream-json shapes the parser depends on.

To check the real CLI, run the engine against it with
`--drop-env ANTHROPIC_API_KEY` and a small `--max-budget-usd`. With the default
`--effort low`, a 120-line file took about 20 seconds and under a cent. Without the
flag (the CLI's own default), the same file took about 100 seconds and roughly 3 cents.

## Layout

```
engine/            Python daemon (protocol, orchestration, CLI adapter, cache, org.py)
  claude/          CLI discovery, argv, runner, stream parser, session store
  context/         source window and numbering
  models/          request validation, response validation, JSON schema
  prompts/         Markdown prompt templates (read-only charter + per-task)
doom/code-reader/  Emacs Lisp frontend
tests/             Python unit and pipeline tests, fake CLI, ERT tests
PROTOCOL.md        wire contract between Emacs and the engine
```

## Troubleshooting

- **"the Claude Code CLI could not be found"**: set `code-reader-claude-command`.
- **"Credit balance is too low"**: the API key in your environment is out of
  credit. Keep `code-reader-claude-env-remove` at its default, or fix the key.
- **Line numbers in an explanation look wrong**: the file changed since the
  explanation was made. Press `g` to regenerate it.
- **Engine problems**: check `code-reader-state-directory/engine.log`, and the
  `*code-reader-engine*` buffer for stderr.
- **Sessions behave oddly**: `code-reader-reset-session` forgets the Claude
  session for the current project.
- **Explanations from before the Org format**: they were JSON, or sat in hash-named
  folders. The engine ignores them. Questions asked before the change are not carried over. Run
  `code-reader-clear-cache` to delete the old files, then press `g` to explain again.
- **"explanation is no longer cached"**: the cache was cleared after the explanation
  was shown. Press `g` to explain the file again.

## Roadmap

- **Phase 1 (this version)**: two-pane view, synchronized scrolling,
  explain whole file/block/function, configurable explanation language, cache, sessions, cancellation.
- **Phase 2**: tree-sitter for exact function and class ranges, LSP symbol
  resolution, dependency discovery, progressive context.
- **Phase 3**: call tracing (`trace_call`), data-flow tracing, class/file/project
  explanations, free-form questions.
- **Phase 4**: persistent sessions, streaming polish, better error recovery.

Not yet implemented: Phase 2 and 3 commands, and `SPC c t` / `SPC c a` bindings.
