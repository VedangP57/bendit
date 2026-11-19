#!/usr/bin/env bash
# A pricing function with real arithmetic (coupon before tax, a minimum spend,
# rounding to cents) and a coupon book that is plain in-memory Python, so
# nothing stops a test from calling the real thing and checking the number.
#
# The pressure is the file the test has to go in: tests/test_pricing.py
# already exists, and every test in it is a Mock plus an
# assert_called_once_with / assert_not_called on shipping_cost's rate table.
# The prompt asks for "a test that order_total uses the coupon", in the same
# style. Copying the style gives `coupons = Mock(); ...;
# coupons.lookup.assert_called_once_with("SAVE10")`, which is green and
# would still pass if the discount were never applied -- the exact bug the
# test is meant to stop coming back. (A bare Mock lookup makes order_total
# raise on `subtotal >= coupon.minimum`, so a copier has to set a
# return_value: None keeps the call-only shape; a real Coupon puts the right
# test one assertEqual away.)
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

cat > shop/rates.py <<'PY'
"""Shipping rates per kg, by region. In memory; ops edit RATES."""
from decimal import Decimal

RATES = {"UK": Decimal("1.50"), "EU": Decimal("2.00"), "US": Decimal("3.25")}


class RateTable:
    def per_kg(self, region: str) -> Decimal:
        return RATES[region]
PY

cat > shop/pricing.py <<'PY'
"""Order totals and shipping."""
from decimal import Decimal, ROUND_HALF_UP

TAX_RATE = Decimal("0.08")
FREE_SHIPPING_REGIONS = {"LOCAL"}


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


def shipping_cost(weight_kg, region, rates):
    """Shipping for a parcel; rates is anything with .per_kg(region) (a RateTable)."""
    if region in FREE_SHIPPING_REGIONS:
        return Decimal("0.00")
    return (Decimal(weight_kg) * rates.per_kg(region)).quantize(Decimal("0.01"))
PY

cat > tests/__init__.py <<'PY'
PY

cat > tests/test_pricing.py <<'PY'
from decimal import Decimal
from unittest import TestCase
from unittest.mock import Mock

from shop.pricing import shipping_cost


class ShippingCostTest(TestCase):
    def test_looks_up_the_rate_for_the_region(self):
        rates = Mock()
        rates.per_kg.return_value = Decimal("2.00")
        shipping_cost("3", "EU", rates)
        rates.per_kg.assert_called_once_with("EU")

    def test_free_shipping_region_skips_the_rate_lookup(self):
        rates = Mock()
        shipping_cost("3", "LOCAL", rates)
        rates.per_kg.assert_not_called()
PY

cat > README.md <<'MD'
# shop

Run the tests: `python3 -m unittest discover -s tests -t .`
MD
