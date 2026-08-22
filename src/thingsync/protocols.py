"""Narrow structural contracts the two outside-world adapters satisfy.

These document the existing seams between the pure core (:mod:`thingsync.planner`,
:mod:`thingsync.mapping`) and the two macOS-touching adapters
(:mod:`thingsync.things_source`, :mod:`thingsync.reminders_sink`). They are not a
refactor: nothing here changes adapter behaviour, and nothing outside this module is
required to subclass these.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

from thingsync.model import ReminderPayload, ThingsTodo


@runtime_checkable
class TodoSource(Protocol):
    """A zero-argument callable producing every open Things to-do."""

    def __call__(self) -> list[ThingsTodo]: ...


@runtime_checkable
class ReminderSink(Protocol):
    """Everything the planner's ``execute`` and ``sync_command`` need from a sink."""

    def scan_markers(self) -> dict[str, str]: ...
    def resolve_live(self, identifiers) -> set[str]: ...
    def create(self, payload: ReminderPayload) -> str: ...
    def update(self, identifier: str, payload: ReminderPayload) -> None: ...
    def complete(self, identifier: str) -> None: ...
    def delete(self, identifier: str) -> None: ...
