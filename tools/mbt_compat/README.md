# mbt_compat

Pure-Pion package that reproduces MoonBit language and core-library semantics
that plain Pion code would silently get wrong after a MoonBit → Pion translation.
Reference behaviour is `moon run --target wasm-gc`.

| Module | MoonBit behaviour | API |
|---|---|---|
| `src/utf16.pion` | strings are UTF-16: `length`, `s[i]`, `s[a:b]`, `exact_view`; `for i, ch in s` counts scalars; `to_lower` is ASCII-only; `String` compares by UTF-16 length first | `utf16_len`, `utf16_code_unit_at`, `utf16_units`, `utf16_slice`, `utf16_slice_from`, `utf16_exact_view`, `utf16_get_view`, `utf16_to_utf8_off`, `utf8_to_utf16_off`, `utf8_to_scalar_off`, `scalar_to_utf8_off`, `utf16_to_scalar_off`, `scalar_to_utf16_off`, `str_compare`, `scalar_len`, `str_iter_scalar_indexed`, `str_scalars`, `str_has_prefix`, `str_has_suffix`, `str_to_lower`, `str_to_upper` |
| `src/ordered_map.pion` | `Map` iterates in insertion order (re-insert after remove moves to the end); any `Hash + Eq` key | `OrderedMap[K, V]` (`set`, `get`, `get_or_default`, `remove`, `contains`, `size`, `is_empty`, `clear`, `each`, `eachi`, `keys`, `values`, `to_array`), `ordered_map_new` / `ordered_map_from_array` (`MapKey` keys), `OrderedMap::new_by(hash, eq)` (any key), `ordered_map_to_map` / `ordered_map_from_map` (Pion `Map` boundary), `hash_mix`, `hash_combine`, `hash_string` |
| `src/array_view.pion` | a view captures the array's buffer at creation; after a reallocating push the array and the view diverge | `ArrayBuf[T]` (MoonBit growth policy: 0 → 8, then ×2; literal capacity = length), `ArrayView[T]` (`view` clamps, `exact_view` panics, `to_owned`), `array_slice_clamp` (`xs[a:b]` as a copy) |
| `src/double_fmt.pion` | shortest round-trip digits, ECMAScript layout: `1.5e-7`, `-0.0` → `0`, `NaN`, `1e20` → `100000000000000000000` | `double_to_string` |
| `src/checked_div.pion` | Wasm `div`/`rem`: zero divisor traps, signed `MIN / -1` traps, `MIN % -1 == 0` | `div_checked_{i32,i64,u32,u64,byte}`, `mod_checked_*`, `trap_div_zero`, `trap_rem_zero`, `trap_div_overflow` |
| `src/collections.pion` | `Array` / `Option` helpers and assertions; `sort_by` reproduces MoonBit's (unstable) algorithm so ties end in the same order | `arr_map`, `arr_mapi`, `arr_filter`, `arr_each`, `arr_eachi`, `arr_fold`, `arr_last`, `arr_insert`, `arr_remove`, `arr_append`, `arr_sort_by`, `opt_map`, `opt_unwrap`, `opt_or`, `opt_is_empty`, `assert_eq_by`, `assert_true`, `assert_false` |

MoonBit aborts and traps become Pion panics whose message starts with
`abort:`, `index out of bounds`, `divide by zero`, `remainder by zero` or
`divide result unrepresentable`.

`utf16_len` / `utf16_code_unit_at` on strings of 64+ bytes use a small
process-wide index cache (last 4 strings, behind a `Mutex`, keyed by data
address + length while holding the string), so the translated loop
`for i = 0; i < utf16_len(s); i = i + 1 { utf16_code_unit_at(s, i) }` is linear
instead of quadratic.

From another package, construct `MapKey`-keyed maps with `ordered_map_new()` /
`ordered_map_from_array()`: pionc 0.1.0 checks the trait bound of an imported
static method (`OrderedMap::new`) against the caller's package and reports
`E_TRAIT_NOT_IMPLEMENTED`.

## Verification

```sh
pionc fmt --check tools/mbt_compat
pionc check --json tools/mbt_compat
pionc test --json tools/mbt_compat
python3 tools/mbt_compat/oracle/run_oracle.py --pionc <pionc under test>   # also $PIONC; needs moon (wasm-gc), node
```

`oracle/run_oracle.py` runs every case of `oracle/moon_probe` (MoonBit) and
`oracle/pion_probe` (the same program written against this package) on
`moon run --target wasm-gc`, `pionc run` and `pionc run --target wasm32`, and
requires identical outcome class (ok / panic kind), trace and executed
assertion ids, plus the frozen per-case expectation. Crashes, timeouts, raw
Wasm traps on the Pion side and empty runs are hard failures. A negative
self-test then mutates the Pion probe (dropped assertion, swallowed panic,
bypassed helper) and requires each mutant to be reported red with its
expected failure category; an infrastructure error never counts as a detection. The harness
also prints hot-path micro-benchmarks.
