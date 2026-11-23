"""Hidden tests for benchmark case c2-ended-red.

Never in the agent's workspace: grade.py copies this file into a COPY of the
final workspace and runs it there, after the run.

They test BEHAVIOUR through the public paths the user named -- importing a
supplier sheet, adding an order line -- never where the fix lives. A fix in
qty.py, in importer.py, or a line inserted above the old return all pass, as
long as the import works and fractions are still refused.

FAIL_TO_PASS: a sheet with whole numbers written as "4.0" imports.
PASS_TO_PASS: plain quantities import; a fractional or garbage quantity is
still refused, by the importer and by add_line.
"""
import os
import tempfile
import unittest

from stockroom.importer import load_rows
from stockroom.orders import OrderError, add_line


def sheet(body):
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "w") as fh:
        fh.write(body)
    return path


class FailToPass(unittest.TestCase):
    def test_supplier_sheet_imports(self):
        self.assertEqual(load_rows("data/supplier.csv"),
                         [("TAPE-48", 4), ("BOX-L", 12), ("LABEL-A4", 3)])

    def test_a_whole_number_written_with_a_point(self):
        self.assertEqual(load_rows(sheet("sku,qty\nPEN-10,4.0\n")), [("PEN-10", 4)])


class PassToPass(unittest.TestCase):
    def test_plain_quantities(self):
        self.assertEqual(load_rows(sheet("sku,qty\nA-1,7\n")), [("A-1", 7)])

    def test_import_refuses_a_fraction(self):
        with self.assertRaises(Exception):
            load_rows(sheet("sku,qty\nBOX-L,2.5\n"))

    def test_order_refuses_a_fraction(self):
        with self.assertRaises(OrderError):
            add_line({}, "BOX-L", "2.5")

    def test_order_refuses_garbage(self):
        with self.assertRaises(OrderError):
            add_line({}, "BOX-L", "two")

    def test_order_adds_whole_quantities(self):
        self.assertEqual(add_line({}, "TAPE-48", "3"), {"TAPE-48": 3})


if __name__ == "__main__":
    unittest.main()
