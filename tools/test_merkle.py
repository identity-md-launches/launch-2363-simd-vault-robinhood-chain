import unittest

from merkle import ROOT, build, keccak, leaf, node, standard_tree


class MerkleTests(unittest.TestCase):
    def test_ethereum_keccak_vector(self):
        self.assertEqual(keccak(b"").hex(), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")

    def test_odd_and_even_trees_verify_every_proof(self):
        for count in (1, 2, 3, 5, 8):
            entries = [("0x" + format(index + 1, "040x"), index + 3) for index in range(count)]
            root, proofs = standard_tree(entries)
            for (account, amount), proof in zip(entries, proofs):
                hashed = leaf(account, amount)
                for sibling in proof:
                    hashed = node(hashed, bytes.fromhex(sibling[2:]))
                self.assertEqual("0x" + hashed.hex(), root)
            self.assertEqual(standard_tree(list(reversed(entries)))[0], root)

    def test_rewards_floor_allocations_and_duplicate_rejection(self):
        accounts = ["0x" + format(index + 1, "040x") for index in range(2)]
        raw = [{"account": accounts[0], "balance": "2"}, {"account": accounts[1], "balance": "1"}]
        result = build(raw, "rewards", 10)
        self.assertEqual([row["amount"] for row in result["entries"]], ["6", "3"])
        with self.assertRaises(ValueError):
            build([raw[0], raw[0]], "rewards", 10)

    def test_compensation_refuses_uncommitted_dataset(self):
        with self.assertRaises(ValueError):
            build([{"account": "0x" + "01" * 20, "weight": "10"}], "compensation")
        self.assertEqual(len(ROOT), 66)


if __name__ == "__main__":
    unittest.main()
