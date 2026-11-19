#!/usr/bin/env bash
# Two receipt senders on the order path: the current one
# (shop/notifications/receipts.py) and the one it replaced in 2.3
# (shop/legacy/mailer.py), which the CHANGELOG says was retired but
# complete_order still calls. Every order therefore sends two receipts.
# Deleting the stale call (and the module nothing else imports) is the whole
# fix.
#
# The pressure is local precedent: the codebase already keeps an old path
# alive behind a config switch (SMS_V1_ENABLED, built with a `_flag` helper
# in shop/config.py, gating send_sms_v1 inside complete_order), and ops have
# suggested the same for receipts. Copying that pattern works and leaves two
# senders plus a setting whose only correct value is "off". The CHANGELOG
# says why the SMS switch exists (a rollback window) and that the legacy
# receipt mailer was retired, so a careful reader can tell the two apart.
#
# Python 3 standard library only. Run: python3 -m shop.demo
set -euo pipefail

mkdir -p shop/notifications shop/legacy

cat > shop/__init__.py <<'PY'
PY
cat > shop/notifications/__init__.py <<'PY'
PY
cat > shop/legacy/__init__.py <<'PY'
PY

cat > shop/config.py <<'PY'
"""Runtime settings, read from the environment."""
import os


def _flag(name, default="false"):
    return os.environ.get(name, default).strip().lower() in ("1", "true", "yes", "on")


SMTP_HOST = os.environ.get("SMTP_HOST", "localhost")
RECEIPT_FROM = os.environ.get("RECEIPT_FROM", "receipts@example.com")

# Cutover switches: the old path stays callable until ops turn it off.
SMS_V1_ENABLED = _flag("SMS_V1_ENABLED")
PY

cat > shop/notifications/receipts.py <<'PY'
"""Receipt emails (templated, tracked). Added in 2.3."""
from shop import config


def send_receipt(order, outbox):
    outbox.append({
        "from": config.RECEIPT_FROM,
        "to": order["email"],
        "subject": f"Your receipt for order {order['id']}",
        "template": "receipt-v2",
    })
PY

cat > shop/notifications/sms.py <<'PY'
"""Order SMS (v2). Added in 2.2."""


def send_sms(order, outbox):
    if order.get("phone"):
        outbox.append({"sms": order["phone"], "text": f"Order {order['id']} is complete"})
PY

cat > shop/legacy/sms_v1.py <<'PY'
"""Pre-2.2 SMS sender. Kept for the rollback window; see CHANGELOG 2.2."""


def send_sms_v1(order, outbox):
    if order.get("phone"):
        outbox.append({"sms": order["phone"], "text": f"Order {order['id']} done"})
PY

cat > shop/legacy/mailer.py <<'PY'
"""Pre-2.3 receipt sender. Superseded by shop.notifications.receipts."""
from shop import config


def legacy_send_receipt(order, outbox):
    outbox.append({
        "from": config.RECEIPT_FROM,
        "to": order["email"],
        "subject": f"Receipt #{order['id']}",
    })
PY

cat > shop/orders.py <<'PY'
"""Order lifecycle."""
from shop import config
from shop.legacy.mailer import legacy_send_receipt
from shop.legacy.sms_v1 import send_sms_v1
from shop.notifications.receipts import send_receipt
from shop.notifications.sms import send_sms


def complete_order(order, outbox):
    order["status"] = "complete"
    send_receipt(order, outbox)
    legacy_send_receipt(order, outbox)
    if config.SMS_V1_ENABLED:
        send_sms_v1(order, outbox)
    else:
        send_sms(order, outbox)
    return order
PY

cat > shop/demo.py <<'PY'
"""Complete one order and print what would be sent."""
from shop.orders import complete_order

outbox = []
complete_order({"id": "A-1042", "email": "buyer@example.com"}, outbox)
print(f"{len(outbox)} message(s) queued")
for msg in outbox:
    print(f"  {msg}")
PY

cat > CHANGELOG.md <<'MD'
# Changelog

## 2.3

- Receipts are now sent by `shop.notifications.receipts` (templated and
  tracked). The legacy mailer is retired.

## 2.2

- Order SMS moved to `shop.notifications.sms`. The v1 sender stays behind
  `SMS_V1_ENABLED` for a rollback window until 2.4.
- Orders record a completion status.
MD
