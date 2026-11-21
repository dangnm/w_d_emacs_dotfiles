"""Bookkeeping for in-flight explain requests.

Rules enforced here:

* One active request per explanation view. A newer request for the same view
  cancels the older one with reason ``superseded``, so late results can never
  overwrite newer ones.
* Each request remembers its owning connection. If that connection closes, its
  requests are cancelled.
* Cancellation records a reason before cancelling the asyncio task, so the
  handler can report why it stopped.
"""

from __future__ import annotations

import asyncio
import time
from dataclasses import dataclass, field
from typing import Any

REASON_CLIENT = "client"
REASON_SUPERSEDED = "superseded"
REASON_SHUTDOWN = "shutdown"


@dataclass
class ActiveRequest:
    id: str
    view: str
    task: str
    owner: object
    phase: str = "queued"
    started_at: float = field(default_factory=time.monotonic)
    handle: asyncio.Task | None = None
    cancel_reason: str | None = None


class DuplicateRequest(Exception):
    """A request id is already in use."""


class RequestRegistry:
    def __init__(self) -> None:
        self._active: dict[str, ActiveRequest] = {}
        self._latest_by_view: dict[str, str] = {}

    def __len__(self) -> int:
        return len(self._active)

    def register(self, request_id: str, view: str, task: str, owner: object) -> None:
        """Record a new request, superseding any active one for the same view."""
        if request_id in self._active:
            raise DuplicateRequest(request_id)
        previous_id = self._latest_by_view.get(view)
        if previous_id is not None and previous_id in self._active:
            self.cancel(previous_id, REASON_SUPERSEDED)
        self._active[request_id] = ActiveRequest(id=request_id, view=view, task=task, owner=owner)
        self._latest_by_view[view] = request_id

    def attach(self, request_id: str, handle: asyncio.Task) -> None:
        """Remember the running task. Called from inside the task, so it has started.

        Only started tasks are ever cancelled. A task cancelled before it starts
        would never run its ``finally`` and would leak its registry entry.
        """
        active = self._active.get(request_id)
        if active is not None:
            active.handle = handle

    def set_phase(self, request_id: str, phase: str) -> None:
        active = self._active.get(request_id)
        if active is not None:
            active.phase = phase

    def is_latest(self, request_id: str) -> bool:
        active = self._active.get(request_id)
        return active is not None and self._latest_by_view.get(active.view) == request_id

    def cancel(self, request_id: str, reason: str) -> bool:
        """Cancel an active request. Returns ``False`` if it is not active."""
        active = self._active.get(request_id)
        if active is None:
            return False
        if active.cancel_reason is None:
            active.cancel_reason = reason
        if active.handle is not None and not active.handle.done():
            active.handle.cancel()
        return True

    def cancel_reason(self, request_id: str) -> str | None:
        active = self._active.get(request_id)
        return active.cancel_reason if active else None

    def cancel_owned_by(self, owner: object, reason: str) -> None:
        for request_id, active in list(self._active.items()):
            if active.owner is owner:
                self.cancel(request_id, reason)

    def cancel_all(self, reason: str) -> None:
        for request_id in list(self._active):
            self.cancel(request_id, reason)

    def finish(self, request_id: str) -> None:
        active = self._active.pop(request_id, None)
        if active is not None and self._latest_by_view.get(active.view) == request_id:
            del self._latest_by_view[active.view]

    def snapshot(self) -> list[dict[str, Any]]:
        now = time.monotonic()
        return [
            {
                "id": a.id,
                "view": a.view,
                "task": a.task,
                "phase": a.phase,
                "elapsed_ms": int((now - a.started_at) * 1000),
            }
            for a in self._active.values()
        ]
