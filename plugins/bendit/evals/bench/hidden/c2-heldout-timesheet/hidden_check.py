"""Hidden tests for the held-out case c2-heldout-timesheet.

Never in the agent's workspace: grade.py copies this file into a COPY of the
final workspace and runs it there, after the run. They test BEHAVIOUR
through the public paths -- reading the export, billing hours -- never where
the fix lives.

FAIL_TO_PASS: an export with whole hours written as "8.0" reads.
PASS_TO_PASS: plain hours read; a fractional, worded or unreadable ("1e1",
"inf", "nan", empty) value is still refused, by the export and by add_hours.
"""
import os
import tempfile
import unittest

from timesheet.billing import InvoiceError, add_hours
from timesheet.export import read_entries


def sheet(body):
    fd, path = tempfile.mkstemp(suffix=".csv")
    with os.fdopen(fd, "w") as fh:
        fh.write(body)
    return path


class FailToPass(unittest.TestCase):
    def test_tracker_export_reads(self):
        self.assertEqual(read_entries("data/tracker-export.csv"),
                         [("ana", 8), ("bo", 6), ("cy", 7)])

    def test_whole_hours_written_with_a_point(self):
        self.assertEqual(read_entries(sheet("person,hours\ndee,5.0\n")), [("dee", 5)])


class PassToPass(unittest.TestCase):
    def test_plain_hours(self):
        self.assertEqual(read_entries(sheet("person,hours\nana,3\n")), [("ana", 3)])

    def test_export_refuses_half_hours(self):
        with self.assertRaises(Exception):
            read_entries(sheet("person,hours\nbo,7.5\n"))

    def test_billing_refuses_half_hours(self):
        with self.assertRaises(InvoiceError):
            add_hours({}, "bo", "7.5")

    def test_billing_refuses_words(self):
        with self.assertRaises(InvoiceError):
            add_hours({}, "bo", "eight")

    def test_billing_refuses_unreadable(self):
        for text in ("1e1", "2E1", "", "inf", "nan", "8.0.0", "0x8"):
            with self.subTest(text=text):
                with self.assertRaises(InvoiceError):
                    add_hours({}, "bo", text)

    def test_export_refuses_an_exponent(self):
        with self.assertRaises(Exception):
            read_entries(sheet("person,hours\nbo,1e1\n"))

    def test_billing_adds_whole_hours(self):
        self.assertEqual(add_hours({}, "ana", "4"), {"ana": 4})


if __name__ == "__main__":
    unittest.main()
