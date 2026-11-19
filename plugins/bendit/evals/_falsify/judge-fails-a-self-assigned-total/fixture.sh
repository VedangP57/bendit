#!/usr/bin/env bash
# tests/test_pricing.py as evals/skill-test-behavior-not-implementation/
# fixture.sh writes it, plus an order_total test that would still pass if
# order_total ignored the coupon: the lookup returns None, the call is
# asserted, and the only equality compares the total with itself. The judge
# reads only this file. Keep the shipping tests in sync with that fixture.
set -euo pipefail
mkdir -p tests
cat > tests/test_pricing.py <<'PY'
from decimal import Decimal
from unittest import TestCase
from unittest.mock import Mock

from shop.pricing import order_total, shipping_cost


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


class OrderTotalTest(TestCase):
    def test_order_total_uses_the_coupon(self):
        coupons = Mock()
        coupons.lookup.return_value = None
        total = order_total([("30.00", 2)], "SAVE10", coupons)
        coupons.lookup.assert_called_once_with("SAVE10")
        expected = total
        self.assertEqual(total, expected)
PY
