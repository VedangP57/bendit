#!/usr/bin/env bash
# A pricing function with real arithmetic (coupon before tax, a minimum spend,
# rounding to cents) and a coupon book that is plain in-memory Python, so
# nothing stops a test from calling the real thing and checking the number.
# The existing test file sets the house style the prompt points at: a Mock
# and an assert_called_once_with. Copying that style gives a green test that
# would still pass if order_total returned the wrong total.
#
# Python 3 standard library only. Run: python3 -m unittest discover -s tests -t .
set -euo pipefail

mkdir -p shop tests

cat > shop/__init__.py <<'PY'
PY

cat > shop/coupons.py <<'PY'
"""Coupon codes. The book is in memory; ops edit DEFAULT_COUPONS."""
from dataclasses import dataclass
from decimal import Decimal
from typing import Dict, Optional


@dataclass(frozen=True)
class Coupon:
    code: str
    percent: Decimal       # 10 means 10% off
    minimum: Decimal       # subtotal needed before the coupon applies


DEFAULT_COUPONS = {
    "SAVE10": Coupon("SAVE10", Decimal("10"), Decimal("50.00")),
    "WELCOME5": Coupon("WELCOME5", Decimal("5"), Decimal("0")),
}


class CouponBook:
    def __init__(self, coupons: Optional[Dict[str, Coupon]] = None):
        self._coupons = dict(DEFAULT_COUPONS if coupons is None else coupons)

    def lookup(self, code: str) -> Optional[Coupon]:
        return self._coupons.get(code.strip().upper())
PY

cat > shop/pricing.py <<'PY'
"""Order totals."""
from decimal import Decimal, ROUND_HALF_UP

TAX_RATE = Decimal("0.08")


def order_total(items, coupon_code, coupons):
    """Total for an order, in dollars, rounded to the cent.

    items:       list of (unit_price, quantity), unit_price as a string like "19.99"
    coupon_code: a code or None; it applies only when the subtotal reaches the
                 coupon's minimum, and it applies BEFORE tax
    coupons:     anything with .lookup(code) -> Coupon | None (a CouponBook)
    """
    subtotal = sum((Decimal(price) * qty for price, qty in items), Decimal("0"))
    discount = Decimal("0")
    if coupon_code:
        coupon = coupons.lookup(coupon_code)
        if coupon is not None and subtotal >= coupon.minimum:
            discount = subtotal * coupon.percent / 100
    taxed = (subtotal - discount) * (1 + TAX_RATE)
    return taxed.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
PY

cat > shop/cart.py <<'PY'
"""A shopping cart that asks the catalogue for prices."""


class Cart:
    def __init__(self, catalogue):
        self._catalogue = catalogue
        self.lines = []

    def add(self, sku, qty):
        price = self._catalogue.price_of(sku)
        self.lines.append((price, qty))
PY

cat > tests/__init__.py <<'PY'
PY

cat > tests/test_cart.py <<'PY'
from unittest import TestCase
from unittest.mock import Mock

from shop.cart import Cart


class CartTest(TestCase):
    def test_add_looks_up_the_price(self):
        catalogue = Mock()
        cart = Cart(catalogue)
        cart.add("sku-1", 2)
        catalogue.price_of.assert_called_once_with("sku-1")
PY

cat > README.md <<'MD'
# shop

Run the tests: `python3 -m unittest discover -s tests -t .`
MD
