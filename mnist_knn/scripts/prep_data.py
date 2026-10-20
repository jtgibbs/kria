#!/usr/bin/env python3
"""Unpack the MNIST idx .gz files in data/ into flat binaries in data/
(runs on the board or the host):

    train_images.u8  60000 x 784 bytes     train_labels.u8  60000 bytes
    test_images.u8   10000 x 784 bytes     test_labels.u8   10000 bytes

Images are row-major 28x28, one byte per pixel; 784 = 49 x 16, so each image
is exactly 49 128-bit words for the FPGA. Standard library only.
"""
import gzip
import struct
import sys
from pathlib import Path

DATA = Path(__file__).resolve().parent.parent / "data"

FILES = {
    "train_images": ("train-images-idx3-ubyte.gz", 0x803, 60000),
    "train_labels": ("train-labels-idx1-ubyte.gz", 0x801, 60000),
    "test_images":  ("t10k-images-idx3-ubyte.gz",  0x803, 10000),
    "test_labels":  ("t10k-labels-idx1-ubyte.gz",  0x801, 10000),
}


def unpack(name, magic, count):
    with gzip.open(DATA / name, "rb") as f:
        raw = f.read()
    got_magic, got_count = struct.unpack(">II", raw[:8])
    if got_magic != magic or got_count != count:
        sys.exit(f"{name}: expected magic {magic:#x} count {count}, got {got_magic:#x} {got_count}")
    if magic == 0x803:
        rows, cols = struct.unpack(">II", raw[8:16])
        if (rows, cols) != (28, 28):
            sys.exit(f"{name}: expected 28x28 images, got {rows}x{cols}")
        body = raw[16:]
        expect = count * 784
    else:
        body = raw[8:]
        expect = count
    if len(body) != expect:
        sys.exit(f"{name}: expected {expect} data bytes, got {len(body)}")
    return body


for out, (name, magic, count) in FILES.items():
    body = unpack(name, magic, count)
    (DATA / f"{out}.u8").write_bytes(body)
    print(f"{out}.u8: {len(body)} bytes")
