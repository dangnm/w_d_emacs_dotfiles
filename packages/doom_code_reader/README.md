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
- Explanations are cached on disk, keyed by snapshot hash, task, target,
  language, model, and prompt version. Editing a prompt invalidates old entries.

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
| `code-reader-state-directory` | `~/.cache/doom-code-reader/` | cache, sessions, logs |

`code-reader-claude-env-remove` defaults to dropping `ANTHROPIC_API_KEY`. The
CLI then uses your claude.ai login. An exhausted or invalid key in the shell
would otherwise make every request fail with "Credit balance is too low".
Set the list to `nil` to use the key instead.

## Usage

| Key | Command | What it does |
|---|---|---|
| `SPC c r` | `code-reader-open` | open the two-pane view and explain the whole file (first open only) |
| `SPC c b` | `code-reader-explain-block` | explain the active region |
| `SPC c F` | `code-reader-explain-function` | explain the function at point |

Opening a file sends its whole content to Claude once. The explanation has a
section for each top-level definition, in file order, so you scroll the source
to the part you need and the explanation follows. The result is cached, so
reopening is instant. Press `g` to regenerate after the file changes. Files over
300 000 characters are rejected with a message. Explain a region or function
instead.

`M-x code-reader-explain-file` runs the same whole-file explanation without
opening the layout.

In the explanation pane: `RET` or click jumps to the source, `g` refreshes
(bypasses the cache), `c` cancels, `t` toggles the pane, `q` closes it.
Moving the cursor from the source into the explanation pane (`C-w l`, or a click)
shows a small table of the pane's keys under it. The table goes away when the
cursor moves inside the pane, or when you move back to the source.

Other commands (run with `M-x`): `code-reader-cancel`,
`code-reader-clear-cache`, `code-reader-reset-session`,
`code-reader-show-status`, `code-reader-set-language`,
`code-reader-shutdown-engine`.

Closing the reader restores the original window layout.

### Scrolling and highlights

- Scrolling the source moves the explanation pane to the section covering the
  middle of the visible source. Point in the source does not move.
- Scrolling the explanation pane brings the matching source region into view and
  highlights it.
- Moving point in the source highlights the section that covers it. This never
  calls Claude.
- Explanations are tied to the text they were generated from. If the buffer
  changes, the header shows "stale". Press `g` to regenerate.

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
# Engine: 90 tests, including real-socket and subprocess end-to-end tests.
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
engine/            Python daemon (protocol, orchestration, CLI adapter, cache)
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
- **Explanation says "stale"**: the buffer changed after the explanation was made.
  Press `g`.
- **Engine problems**: check `code-reader-state-directory/engine.log`, and the
  `*code-reader-engine*` buffer for stderr.
- **Sessions behave oddly**: `code-reader-reset-session` forgets the Claude
  session for the current project.

## Roadmap

- **Phase 1 (this version)**: two-pane view, synchronized scrolling,
  explain whole file/block/function, configurable explanation language, cache, sessions, cancellation.
- **Phase 2**: tree-sitter for exact function and class ranges, LSP symbol
  resolution, dependency discovery, progressive context.
- **Phase 3**: call tracing (`trace_call`), data-flow tracing, class/file/project
  explanations, free-form questions.
- **Phase 4**: persistent sessions, streaming polish, better error recovery.

Not yet implemented: Phase 2 and 3 commands, and `SPC c t` / `SPC c a` bindings.
