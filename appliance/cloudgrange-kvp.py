#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — minimal writer for the Hyper-V KVP guest-to-host pool (/var/lib/hyperv/.kvp_pool_1).
# hv_kvp_daemon (linux-cloud-tools) serves this pool to the host, where it appears in
# Msvm_KvpExchangeComponent.GuestExchangeItems and is readable only by Hyper-V administrators.
# Record format (hv_kvp_daemon.c): fixed 512-byte key + 2048-byte value, NUL padded.
#
#   cloudgrange-kvp.py set KEY      value is read from stdin (never from argv)
#   cloudgrange-kvp.py delete KEY [KEY...]
#   cloudgrange-kvp.py keys         prints key names only, never values
import fcntl
import os
import sys

POOL = "/var/lib/hyperv/.kvp_pool_1"
KEY_SIZE, VALUE_SIZE = 512, 2048
RECORD = KEY_SIZE + VALUE_SIZE


def read_records(fd):
    os.lseek(fd, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(fd, 1 << 16)
        if not chunk:
            break
        chunks.append(chunk)
    data = b"".join(chunks)
    records = []
    for offset in range(0, len(data) - len(data) % RECORD, RECORD):
        key = data[offset:offset + KEY_SIZE].split(b"\0", 1)[0]
        value = data[offset + KEY_SIZE:offset + RECORD].split(b"\0", 1)[0]
        if key:
            records.append([key, value])
    return records, len(data)


def write_records(fd, records, old_length):
    payload = b"".join(k.ljust(KEY_SIZE, b"\0") + v.ljust(VALUE_SIZE, b"\0") for k, v in records)
    os.lseek(fd, 0, os.SEEK_SET)
    # Overwrite the whole previous length first, so a removed value does not linger in the file's blocks.
    os.write(fd, payload + b"\0" * max(0, old_length - len(payload)))
    os.fsync(fd)
    os.ftruncate(fd, len(payload))
    os.fsync(fd)


def main(argv):
    if len(argv) < 2 or argv[1] not in ("set", "delete", "keys"):
        print(__doc__ or "usage: cloudgrange-kvp.py set KEY | delete KEY... | keys", file=sys.stderr)
        return 2
    op = argv[1]
    os.makedirs(os.path.dirname(POOL), mode=0o700, exist_ok=True)
    fd = os.open(POOL, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        # fcntl record locks: the same locking hv_kvp_daemon uses on the pool files.
        fcntl.lockf(fd, fcntl.LOCK_EX)
        records, old_length = read_records(fd)
        if op == "keys":
            for key, _ in records:
                print(key.decode("utf-8", "replace"))
            return 0
        if op == "set":
            if len(argv) != 3:
                print("usage: cloudgrange-kvp.py set KEY  (value on stdin)", file=sys.stderr)
                return 2
            key = argv[2].encode("utf-8")
            value = sys.stdin.buffer.read()
            if len(key) >= KEY_SIZE or len(value) >= VALUE_SIZE:
                print("key or value too large for a KVP record", file=sys.stderr)
                return 1
            records = [r for r in records if r[0] != key] + [[key, value]]
        else:
            remove = {k.encode("utf-8") for k in argv[2:]}
            records = [r for r in records if r[0] not in remove]
        write_records(fd, records, old_length)
        return 0
    finally:
        os.close(fd)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
