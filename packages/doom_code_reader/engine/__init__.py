"""Doom Code Reader engine: a Python daemon that answers code-explanation
requests from the Emacs frontend by driving the Claude Code CLI.

See PROTOCOL.md in the package root for the wire contract.
"""

from .config import ENGINE_VERSION, PROTOCOL_VERSION

__all__ = ["ENGINE_VERSION", "PROTOCOL_VERSION"]
