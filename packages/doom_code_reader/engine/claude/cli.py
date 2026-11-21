"""Claude Code CLI adapter: discovery, capability checks, argv, async runner.

Read-only guarantees are enforced with several layers, because no single flag
is enough on its own:

1. ``--restricted`` removes Bash and other code-running tools, ignores user,
   project and local settings (so user hooks cannot run), and confines file
   tools to the working directory.
2. ``--tools Read,Grep,Glob`` restricts the built-in tool set to read-only tools.
3. ``--allowedTools`` pre-approves exactly those tools.
4. ``--disallowedTools`` explicitly denies write- and network-capable tools.
5. ``--permission-mode dontAsk`` plus ``--permission-prompts none`` turns every
   non-approved request into a denial instead of a prompt.

``--dangerously-skip-permissions`` is never used.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import signal
import subprocess
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from engine.claude.stream_parser import StreamParser, StreamState
from engine.config import (
    DENIED_TOOLS,
    READ_ONLY_TOOLS,
    STREAM_LINE_LIMIT,
)

log = logging.getLogger(__name__)

# Flags this adapter depends on. Verified against the installed CLI at startup.
REQUIRED_FLAGS: tuple[str, ...] = (
    "--print",
    "--output-format",
    "--verbose",
    "--include-partial-messages",
    "--json-schema",
    "--tools",
    "--allowedTools",
    "--disallowedTools",
    "--permission-mode",
    "--permission-prompts",
    "--restricted",
    "--max-budget-usd",
    "--session-id",
    "--resume",
    "--append-system-prompt",
    "--model",
    "--effort",
)

EFFORT_LEVELS = ("low", "medium", "high", "xhigh", "max")

STDERR_TAIL_BYTES = 8192
_HELP_TIMEOUT_S = 20


@dataclass(frozen=True)
class ClaudeInfo:
    """Result of probing a Claude CLI binary."""

    path: str | None
    version: str | None = None
    flags_ok: bool = False
    missing_flags: tuple[str, ...] = ()
    error: str | None = None

    def to_dict(self) -> dict[str, Any] | None:
        if self.path is None:
            return None
        return {
            "path": self.path,
            "version": self.version,
            "flags_ok": self.flags_ok,
            "missing_flags": list(self.missing_flags),
        }


def locate_claude(explicit: str | None) -> str | None:
    """Return an executable path for the CLI, or ``None``.

    Order: an explicit path (a bare name like ``claude`` is looked up on
    ``PATH``), then ``~/.local/bin/claude``, then ``PATH``.
    """
    candidates: list[str] = []
    if explicit:
        expanded = os.path.expanduser(explicit)
        if os.path.dirname(expanded):
            candidates.append(expanded)
        else:
            found = shutil.which(expanded)
            if found:
                candidates.append(found)
    else:
        candidates.append(os.path.expanduser("~/.local/bin/claude"))
        found = shutil.which("claude")
        if found:
            candidates.append(found)
    for candidate in candidates:
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return os.path.realpath(candidate)
    return None


def probe_claude(path: str | None) -> ClaudeInfo:
    """Run ``--version`` and ``--help`` once and check the flags we need."""
    if path is None:
        return ClaudeInfo(path=None, error="claude executable not found")
    try:
        version_out = subprocess.run(
            [path, "--version"], capture_output=True, text=True, timeout=_HELP_TIMEOUT_S, check=False
        ).stdout.strip()
        help_out = subprocess.run(
            [path, "--help"], capture_output=True, text=True, timeout=_HELP_TIMEOUT_S, check=False
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        return ClaudeInfo(path=path, error=f"could not run claude: {exc}")
    version = version_out.split()[0] if version_out else None
    missing = tuple(flag for flag in REQUIRED_FLAGS if flag not in help_out)
    if missing:
        log.warning("claude %s is missing flags: %s", version, ", ".join(missing))
    return ClaudeInfo(path=path, version=version, flags_ok=not missing, missing_flags=missing)


def build_argv(
    claude_bin: str,
    *,
    json_schema: str,
    system_prompt: str,
    session_id: str,
    resume: bool,
    max_budget_usd: float,
    model: str | None,
    effort: str | None = None,
) -> list[str]:
    """Assemble the argument array. The prompt itself is sent on stdin."""
    if resume:
        session_args = ["--resume", session_id]
    else:
        session_args = ["--session-id", session_id]
    argv = [
        claude_bin,
        "--print",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--restricted",
        "--tools",
        ",".join(READ_ONLY_TOOLS),
        "--allowedTools",
        ",".join(READ_ONLY_TOOLS),
        "--disallowedTools",
        ",".join(DENIED_TOOLS),
        "--permission-mode",
        "dontAsk",
        "--permission-prompts",
        "none",
        "--json-schema",
        json_schema,
        "--append-system-prompt",
        system_prompt,
        "--max-budget-usd",
        f"{max_budget_usd:.2f}",
        *session_args,
    ]
    if model:
        argv.extend(["--model", model])
    if effort:
        if effort not in EFFORT_LEVELS:
            raise ValueError(f"unknown effort level: {effort}")
        argv.extend(["--effort", effort])
    return argv


@dataclass
class CliOutcome:
    """What happened when the CLI was run."""

    status: str  # "completed" | "timeout" | "cancelled" | "not_found"
    returncode: int | None
    stderr_tail: str
    state: StreamState = field(default_factory=StreamState)


def build_env(base: dict[str, str], drop: tuple[str, ...]) -> dict[str, str]:
    """Copy the environment without the variables listed in ``drop``."""
    env = dict(base)
    for name in drop:
        env.pop(name, None)
    return env


async def _terminate(proc: asyncio.subprocess.Process) -> None:
    """Stop the CLI process group: SIGTERM, then SIGKILL after a grace period."""
    if proc.returncode is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        await asyncio.wait_for(proc.wait(), timeout=5)
    except asyncio.TimeoutError:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except ProcessLookupError:
            return
        await proc.wait()


async def run_claude(
    argv: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    prompt: str,
    timeout: float,
    on_progress: Any = None,
) -> CliOutcome:
    """Run the CLI, stream its output, and enforce a timeout.

    Cancelling the calling task terminates the child process group before the
    ``CancelledError`` propagates.
    """
    parser = StreamParser(on_progress=on_progress)
    stderr_chunks: deque[bytes] = deque()
    stderr_bytes = 0

    try:
        proc = await asyncio.create_subprocess_exec(
            *argv,
            cwd=str(cwd),
            env=env,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            start_new_session=True,
            limit=STREAM_LINE_LIMIT,
        )
    except FileNotFoundError:
        return CliOutcome(status="not_found", returncode=None, stderr_tail="")

    async def write_prompt() -> None:
        assert proc.stdin is not None
        try:
            proc.stdin.write(prompt.encode("utf-8"))
            await proc.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            try:
                proc.stdin.close()
            except Exception:  # noqa: BLE001 - closing a dead pipe is harmless
                pass

    async def pump_stdout() -> None:
        assert proc.stdout is not None
        while True:
            line = await proc.stdout.readline()
            if not line:
                break
            parser.feed(line)

    async def pump_stderr() -> None:
        nonlocal stderr_bytes
        assert proc.stderr is not None
        while True:
            chunk = await proc.stderr.read(4096)
            if not chunk:
                break
            stderr_chunks.append(chunk)
            stderr_bytes += len(chunk)
            while stderr_bytes > STDERR_TAIL_BYTES and stderr_chunks:
                stderr_bytes -= len(stderr_chunks.popleft())

    def stderr_tail() -> str:
        return b"".join(stderr_chunks).decode("utf-8", errors="replace")[-STDERR_TAIL_BYTES:]

    try:
        await asyncio.wait_for(
            asyncio.gather(write_prompt(), pump_stdout(), pump_stderr(), proc.wait()),
            timeout=timeout,
        )
    except asyncio.TimeoutError:
        await _terminate(proc)
        return CliOutcome(status="timeout", returncode=proc.returncode, stderr_tail=stderr_tail(), state=parser.state)
    except asyncio.CancelledError:
        await _terminate(proc)
        raise

    return CliOutcome(
        status="completed",
        returncode=proc.returncode,
        stderr_tail=stderr_tail(),
        state=parser.state,
    )


def dump_schema(schema: dict[str, Any]) -> str:
    """Serialise a JSON schema for ``--json-schema`` (compact, UTF-8 safe)."""
    return json.dumps(schema, ensure_ascii=False, separators=(",", ":"))
