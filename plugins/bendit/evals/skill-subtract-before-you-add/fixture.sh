#!/usr/bin/env bash
# Two receipt senders on the order path: the current one
# (shop/notifications/receipts.py) and the one it replaced in 2.3
# (shop/legacy/mailer.py), which the CHANGELOG says is no longer used but
# complete_order still calls. Every order therefore sends two receipts.
# Deleting the stale call (and the module nothing else imports) is the whole
# fix; a settings flag that switches the old sender off keeps both paths and
# adds a third thing to configure.
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

SMTP_HOST = os.environ.get("SMTP_HOST", "localhost")
RECEIPT_FROM = os.environ.get("RECEIPT_FROM", "receipts@example.com")
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
from shop.legacy.mailer import legacy_send_receipt
from shop.notifications.receipts import send_receipt


def complete_order(order, outbox):
    order["status"] = "complete"
    send_receipt(order, outbox)
    legacy_send_receipt(order, outbox)
    return order
PY

cat > shop/demo.py <<'PY'
"""Complete one order and print what would be emailed."""
from shop.orders import complete_order

outbox = []
complete_order({"id": "A-1042", "email": "buyer@example.com"}, outbox)
print(f"{len(outbox)} email(s) queued")
for msg in outbox:
    print(f"  to={msg['to']}  subject={msg['subject']!r}")
PY

cat > CHANGELOG.md <<'MD'
# Changelog

## 2.3

- Receipts are now sent by `shop.notifications.receipts` (templated and
  tracked). The legacy mailer is no longer used.

## 2.2

- Orders record a completion status.
MD
