"""Run from ops/monitor: python3 -m unittest discover -p "test_*.py""""
import importlib.util
import pathlib
import unittest

spec = importlib.util.spec_from_file_location(
    "faircoin_monitor", pathlib.Path(__file__).with_name("faircoin-monitor.py"))
mon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mon)

REF_NEXT, GENESIS_NEXT = "aa" * 32, "bb" * 32


class ClassifyChainAnswer(unittest.TestCase):
    def test_same_chain(self):
        self.assertEqual(mon.classify_chain_answer([REF_NEXT, "cc" * 32], REF_NEXT, GENESIS_NEXT), "same")

    def test_same_chain_mixed_with_relayed_blocks(self):
        # 2026-11-16 false alarm: a syncing peer put the blocks it was relaying
        # ahead of our answer in the same inv message.
        hashes = ["dd" * 32, "ee" * 32, REF_NEXT, "cc" * 32]
        self.assertEqual(mon.classify_chain_answer(hashes, REF_NEXT, GENESIS_NEXT), "same")

    def test_fork_falls_back_to_genesis(self):
        self.assertEqual(mon.classify_chain_answer([GENESIS_NEXT, "cc" * 32], REF_NEXT, GENESIS_NEXT), "fork")

    def test_unknown_is_not_a_fork(self):
        self.assertEqual(mon.classify_chain_answer(["dd" * 32, "ee" * 32], REF_NEXT, GENESIS_NEXT), "unknown")


if __name__ == "__main__":
    unittest.main()
