#!/usr/bin/env python3
"""Pack SigLIP 2's tokenizer.json into the small binary file SightTokenizer reads.

usage: export_see_tokens.py tokenizer.json OUT.bin
Layout, little-endian UInt32: magic, single count, merge count, then (scalar, id) pairs, then (left, right, merged) triples in rank order.
"""
import json, struct, sys
model = json.load(open(sys.argv[1], encoding="utf8"))["model"]
vocab, merges = model["vocab"], model["merges"]
singles = [(ord(t), i) for t, i in vocab.items() if len(t) == 1]
triples = []
for left, right in merges:
    if left in vocab and right in vocab and left + right in vocab:
        triples.append((vocab[left], vocab[right], vocab[left + right]))
assert vocab["<0x00>"] + 0x41 == vocab["<0x41>"]
with open(sys.argv[2], "wb") as f:
    f.write(struct.pack("<III", 0x50585331, len(singles), len(triples)))
    for pair in singles: f.write(struct.pack("<II", *pair))
    for triple in triples: f.write(struct.pack("<III", *triple))
print(len(singles), "singles", len(triples), "merges of", len(merges), "first byte token", vocab["<0x00>"])
