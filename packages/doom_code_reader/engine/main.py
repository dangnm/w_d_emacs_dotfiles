"""Command-line entry point: ``python3 -m engine --socket PATH --state-dir DIR``."""

from __future__ import annotations

import argparse
import asyncio
import logging
import signal
import sys
from pathlib import Path

from engine.cache import ExplanationCache
from engine.claude.cli import ClaudeInfo, locate_claude, probe_claude
from engine.claude.session import SessionStore
from engine.config import ENGINE_VERSION, EngineConfig
from engine.orchestrator import Orchestrator
from engine.requests import RequestRegistry
from engine.server import EngineServer


def parse_args(argv: list[str] | None = None) -> tuple[EngineConfig, str]:
    parser = argparse.ArgumentParser(prog="engine", description="Doom Code Reader engine")
    parser.add_argument("--socket", required=True, type=Path, help="UNIX socket path to listen on")
    parser.add_argument("--state-dir", required=True, type=Path, help="directory for cache, sessions and logs")
    parser.add_argument("--claude-bin", default=None, help="path to the claude CLI (default: auto-detect)")
    parser.add_argument("--drop-env", action="append", default=[], metavar="VAR",
                        help="remove VAR from the environment passed to claude (repeatable)")
    parser.add_argument("--idle-timeout", type=float, default=1800.0,
                        help="exit after this many idle seconds with no clients (default: 1800)")
    parser.add_argument("--max-budget-usd", type=float, default=1.0,
                        help="spending cap passed to each claude call (default: 1.0)")
    parser.add_argument("--model", default=None, help="default model alias or name for claude")
    parser.add_argument("--effort", default="low", choices=["low", "medium", "high", "xhigh", "max"],
                        help="reasoning effort for each claude call (default: low; faster and cheaper)")
    parser.add_argument("--log-level", default="INFO", choices=["DEBUG", "INFO", "WARNING", "ERROR"])
    args = parser.parse_args(argv)

    config = EngineConfig(
        socket_path=args.socket.expanduser(),
        state_dir=args.state_dir.expanduser(),
        claude_bin=args.claude_bin,
        drop_env=tuple(args.drop_env),
        idle_timeout_s=args.idle_timeout,
        max_budget_usd=args.max_budget_usd,
        claude_model=args.model,
        claude_effort=args.effort,
    )
    return config, args.log_level


def _configure_logging(config: EngineConfig, level: str) -> None:
    config.state_dir.mkdir(parents=True, exist_ok=True)
    handler = logging.FileHandler(config.log_file, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.handlers[:] = [handler]
    root.setLevel(getattr(logging, level))


async def serve(config: EngineConfig) -> None:
    """Build the object graph, start listening, and serve until stopped."""
    claude_path = locate_claude(config.claude_bin)
    claude_info: ClaudeInfo = await asyncio.to_thread(probe_claude, claude_path)
    if claude_info.error or not claude_info.flags_ok:
        logging.getLogger(__name__).warning("claude check: %s", claude_info.error or claude_info.missing_flags)

    registry = RequestRegistry()
    sessions = SessionStore(config.sessions_file)
    cache = ExplanationCache(config.cache_dir)
    orchestrator = Orchestrator(config, sessions, cache, registry)
    server = EngineServer(config, orchestrator, registry, claude_info)

    await server.start()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, server.request_stop, f"signal {sig.name}")
    await server.serve()


def main(argv: list[str] | None = None) -> int:
    config, level = parse_args(argv)
    _configure_logging(config, level)
    logging.getLogger(__name__).info("engine %s starting", ENGINE_VERSION)
    try:
        asyncio.run(serve(config))
    except RuntimeError as exc:
        print(f"engine: {exc}", file=sys.stderr)
        return 1
    return 0
