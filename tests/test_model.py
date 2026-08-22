from datetime import date

from thingsync.model import ReminderPayload


def payload(**overrides):
    base = dict(title="t", notes="n", url="things:///show?id=U1")
    base.update(overrides)
    return ReminderPayload(**base)


def test_identical_payloads_hash_alike():
    assert payload().content_hash() == payload().content_hash()


def test_every_mirrored_field_changes_the_hash():
    baseline = payload().content_hash()

    assert payload(title="other").content_hash() != baseline
    assert payload(notes="other").content_hash() != baseline
    assert payload(url="things:///show?id=U2").content_hash() != baseline
    assert payload(due_date=date(2026, 8, 25)).content_hash() != baseline
    assert payload(start_date=date(2026, 8, 25)).content_hash() != baseline


def test_due_and_start_dates_are_not_interchangeable_in_the_hash():
    on_due = payload(due_date=date(2026, 8, 25)).content_hash()
    on_start = payload(start_date=date(2026, 8, 25)).content_hash()

    assert on_due != on_start
