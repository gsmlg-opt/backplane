"""Retention checks reject missing, mutated and resurrected baseline rows."""

import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("canonical_inventory", Path(__file__).resolve().parents[1]
                                            / "memory_local_canonical_inventory.py")
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


def row(identity="original", deleted=None):
    return {"id": identity, "memory_space_id": "space", "host_id": "source",
            "client_id": "client", "source_client_id": "origin", "scope": "scope",
            "namespace": "private", "content_hash": "a" * 64, "deleted_at": deleted,
            "lifecycle_state": "tombstoned" if deleted else "active"}


class InventoryTests(unittest.TestCase):
    def test_new_rows_do_not_hide_loss_or_mutation(self):
        self.assertEqual(inventory.compare([row()], [row(), row("new")])["status"], "passed")
        for after in ([row("new")], [{**row(), "content_hash": "b" * 64}],
                      [{**row(), "host_id": "other"}], [{**row(), "deleted_at": "now"}]):
            with self.subTest(after=after):
                self.assertEqual(inventory.compare([row()], after)["status"], "failed")

    def test_existing_tombstone_cannot_resurrect(self):
        self.assertEqual(inventory.compare([row(deleted="then")], [row()])["status"], "failed")
        self.assertEqual(inventory.compare([row(deleted="then")], [row(deleted="then")])[
            "retained_tombstones"], 1)

    def test_duplicate_or_incomplete_inventory_is_rejected(self):
        for rows in ([row(), row()], [{"id": "only"}], [{**row(), "content_hash": "invalid"}]):
            with self.subTest(rows=rows), self.assertRaises(inventory.InventoryFailed):
                inventory.validate(rows)


if __name__ == "__main__":
    unittest.main()
