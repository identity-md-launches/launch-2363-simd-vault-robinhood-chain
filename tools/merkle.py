#!/usr/bin/env python3
"""Build OpenZeppelin StandardMerkleTree-compatible proofs; Python stdlib + Foundry cast only.

Input: a JSON array of {"account": "0x...", "weight": "..."} (compensation), or
already-filtered {"account": "0x...", "balance": "..."} (weekly rewards).
No RPC, wallet, environment variable, transaction or network access is used.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = "0xe84256f66c03a4565c29addd32238495f1a0d5dda8c618e5f81ff8637c296347"
TOTAL_WEIGHT = 201084680772174552329559308
MAX_UINT = (1 << 256) - 1


def keccak(data):
    result = subprocess.run(
        ["cast", "keccak", "0x" + data.hex()], check=True, capture_output=True, text=True
    )
    return bytes.fromhex(result.stdout.strip().removeprefix("0x"))


def leaf(account, value):
    return keccak(keccak(bytes.fromhex(account[2:]).rjust(32, b"\0") + value.to_bytes(32, "big")))


def node(a, b):
    return keccak(min(a, b) + max(a, b))


def standard_tree(entries):
    """Same complete binary tree layout and default leaf sorting as StandardMerkleTree.of."""
    if not entries:
        return "0x" + "00" * 32, []
    ordered = sorted((leaf(account, value), index) for index, (account, value) in enumerate(entries))
    tree = [b""] * (2 * len(entries) - 1)
    indices = {}
    for offset, (hashed, original_index) in enumerate(ordered):
        index = len(tree) - 1 - offset
        tree[index] = hashed
        indices[original_index] = index
    for index in range(len(tree) - len(entries) - 1, -1, -1):
        tree[index] = node(tree[2 * index + 1], tree[2 * index + 2])
    proofs = []
    for original_index in range(len(entries)):
        index = indices[original_index]
        proof = []
        while index:
            sibling = index + 1 if index % 2 else index - 1
            proof.append("0x" + tree[sibling].hex())
            index = (index - 1) // 2
        proofs.append(proof)
    return "0x" + tree[0].hex(), proofs


def layered_tree(entries):
    """The committed compensation layout: sorted leaves, adjacent sorted pairs, an unpaired node promoted."""
    ordered = sorted((leaf(account, value), index) for index, (account, value) in enumerate(entries))
    level = [hashed for hashed, _ in ordered]
    positions = {original_index: offset for offset, (_, original_index) in enumerate(ordered)}
    layers = [level]
    while len(level) > 1:
        level = [node(level[i], level[i + 1]) if i + 1 < len(level) else level[i] for i in range(0, len(level), 2)]
        layers.append(level)
    proofs = []
    for original_index in range(len(entries)):
        position = positions[original_index]
        proof = []
        for layer in layers[:-1]:
            sibling = position ^ 1
            if sibling < len(layer):
                proof.append("0x" + layer[sibling].hex())
            position //= 2
        proofs.append(proof)
    return "0x" + layers[-1][0].hex(), proofs


def read_entries(raw, field):
    if not isinstance(raw, list):
        raise ValueError("input must be a JSON array")
    entries = []
    seen = set()
    for row in raw:
        account = row["account"].lower()
        if not re.fullmatch(r"0x[0-9a-f]{40}", account) or int(account, 16) in (0, 0xDEAD):
            raise ValueError("invalid holder address")
        if account in seen:
            raise ValueError("duplicate account: " + account)
        value = int(row[field])
        if not 0 < value <= MAX_UINT:
            raise ValueError(field + " must be a positive uint256")
        seen.add(account)
        entries.append((account, value))
    if sum(value for _, value in entries) > MAX_UINT:
        raise ValueError("aggregate balance overflows uint256")
    return entries


def build(raw, mode, pot=None):
    source = read_entries(raw, "weight" if mode == "compensation" else "balance")
    total = sum(value for _, value in source)
    if mode == "compensation":
        if len(source) != 62 or total != TOTAL_WEIGHT:
            raise ValueError("compensation dataset must contain exactly 62 wallets and the pinned total weight")
        entries = source
    else:
        if pot is None or not 0 < pot <= MAX_UINT:
            raise ValueError("rewards requires --pot, the epoch's positive snapshotPot in IMD base units")
        entries = [(account, pot * balance // total) for account, balance in source] if total else []
    root, proofs = layered_tree(entries) if mode == "compensation" else standard_tree(entries)
    if mode == "compensation" and root != ROOT:
        raise ValueError("dataset does not reproduce the immutable compensation root; refusing to emit proofs")
    value_name = "weight" if mode == "compensation" else "amount"
    return {
        "mode": mode,
        "root": root,
        "totalWeight" if mode == "compensation" else "eligibleBalance": str(total),
        "entries": [
            {"account": account, value_name: str(value), "proof": proof}
            for (account, value), proof in zip(entries, proofs)
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("compensation", "rewards"))
    parser.add_argument("input", type=Path)
    parser.add_argument("--pot", type=int)
    args = parser.parse_args()
    try:
        print(json.dumps(build(json.loads(args.input.read_text()), args.mode, args.pot), indent=2))
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
