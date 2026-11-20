# t09_ring_parser — incremental binary frame parser over a fixed ring buffer

Frames: `0xAA` magic, 1 length byte `len` (valid 0..=8), `len` payload bytes, 1 checksum byte
(`sum(payload) & 0xFF`). Bytes arrive in chunks and are pushed into a **16-byte ring buffer**; after every
chunk the parser consumes as many complete frames as possible:

- a non-magic byte at the head is discarded and counted in `skipped`;
- `len > 8`: count `bad_length`, drop the magic byte, resync;
- incomplete frame: wait for more input;
- checksum mismatch: count `bad_checksum`, drop the magic byte, resync; otherwise emit the payload and drop the frame.
- pushing into a full ring counts `overflow` (never happens with this input; checked by the tests).

`main` feeds the fixed 33-byte stream in chunks of 5 bytes and prints each payload as `frame <hex>`
(`frame -` for an empty payload), then `ok=.. bad_checksum=.. bad_length=.. skipped=.. pending=..` where
`pending` is the number of bytes left in the ring (a truncated trailing frame). Tests check that 1-byte and
16-byte chunking give identical results.
