#!/usr/bin/env bash
# A webhook dispatcher where an event type without a HANDLERS entry is
# silently dropped (unknown events are ignored on purpose; forgotten ones are
# ignored by accident). AGENTS.md ALREADY says to register a handler, and the
# mistake has happened anyway -- the prose rule exists and is not holding.
# A test that every EventType has a handler makes the mistake fail CI; more
# prose repeats what is already being ignored.
#
# Python 3 standard library only. Run: python3 -m unittest discover -s tests -t .
set -euo pipefail

mkdir -p tests

cat > AGENTS.md <<'MD'
# Project rules

- Python 3.9+, standard library only.
- Run the tests before pushing: `python3 -m unittest discover -s tests -t .`
- When you add an event type, register its handler in HANDLERS.
- Keep webhook handlers idempotent: the provider retries deliveries.
MD

cat > events.py <<'PY'
"""Webhook events from the payment provider."""
from enum import Enum


class EventType(str, Enum):
    ORDER_PLACED = "order.placed"
    ORDER_SHIPPED = "order.shipped"
    REFUND_ISSUED = "refund.issued"
    SUBSCRIPTION_RENEWED = "subscription.renewed"


def on_order_placed(payload):
    return ("placed", payload["id"])


def on_order_shipped(payload):
    return ("shipped", payload["id"])


def on_refund_issued(payload):
    return ("refunded", payload["id"])


def on_subscription_renewed(payload):
    return ("renewed", payload["id"])


HANDLERS = {
    EventType.ORDER_PLACED: on_order_placed,
    EventType.ORDER_SHIPPED: on_order_shipped,
    EventType.REFUND_ISSUED: on_refund_issued,
    EventType.SUBSCRIPTION_RENEWED: on_subscription_renewed,
}


def dispatch(payload):
    """Route one webhook payload to its handler.

    Event names we do not know are ignored on purpose: the provider adds new
    ones without notice, and an unknown event must not fail the delivery.
    """
    try:
        kind = EventType(payload["type"])
    except ValueError:
        return None
    handler = HANDLERS.get(kind)
    if handler is None:
        return None
    return handler(payload)
PY

cat > tests/__init__.py <<'PY'
PY

cat > tests/test_events.py <<'PY'
from unittest import TestCase

from events import EventType, HANDLERS, dispatch


class DispatchTest(TestCase):
    def test_routes_an_order(self):
        result = dispatch({"type": EventType.ORDER_PLACED.value, "id": "o-1"})
        self.assertEqual(result, ("placed", "o-1"))

    def test_ignores_an_unknown_event(self):
        self.assertIsNone(dispatch({"type": "invoice.voided", "id": "i-9"}))
PY
