# t05_json_patch — nested config merge (RFC 7386 merge patch) + validation with Result chains

Parse a JSON base config and six JSON merge patches, apply each patch to the base independently
(RFC 7386: an object patch merges recursively, a `null` member deletes the key, anything else replaces),
then validate the merged config. Each language uses what its **standard library** offers:
m2 `std/json` (in this repo), Go `encoding/json`, MoonBit `moonbitlang/core/json`; Rust's standard library
has no JSON, so the Rust version carries its own small recursive-descent parser (no crates).

Validation (first failure wins, in this order), messages exactly:

1. root object (`root: expected object`)
2. `server` object — `server: missing` / `server: expected object`
3. `server.host` non-empty string — `server.host: missing` / `server.host: expected string`
4. `server.port` integer in 1..65535 — `server.port: <n> out of range 1..65535` (plus missing / `expected int`)
5. `server.tls` bool (missing / `expected bool`)
6. `limits.max_conn` integer > 0 — `limits.max_conn: must be > 0` (plus `limits` object, missing / `expected int`)
7. `log.level` one of `debug|info|warn|error` — `log.level: invalid value <v>` (plus `log` object, missing / `expected string`)

Canonical output: compact JSON, object keys sorted in byte order, integers only.
`main` prints `base: <canonical>` then, per patch, `patch<i> ok: <canonical>`,
`patch<i> invalid: <message>` or `patch<i> parse error` (parser error texts differ per library, so only the fact is printed).
