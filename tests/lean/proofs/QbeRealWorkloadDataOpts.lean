/-
Soundness models for four static-data code-generation rules in
`compiler/src/core/qbe.pion` and `compiler/src/core/wasm.pion` (regression
tests in `compiler/src/core/backend_test.pion` ("p130 ...") and
`tests/e2e/p130_real_workload_data_opts`).

  1. `QuotedBytes` — `qbe_emit_bytes_data` writes every run of at least two
     bytes of a literal-only alphabet (`qbe_plain_data_byte`) as one quoted
     item `b "..."` and every other byte as a number `b N`.
     `literal_alphabet`: the alphabet is printable ASCII without `"`, `\`,
     `$`, `#` or `,`, so neither QBE nor the Wasm data reader enters an
     escape, a symbol or a new item inside the quotes. `pack_spec` /
     `same_static_bytes_and_length`: unpacking the items gives back exactly
     the input bytes (NUL, 255, quotes, backslashes and multibyte UTF-8
     included) and the terminating `b 0`.
  2. `LiteralWords` — an `Array` / `FixedArray` / `ImmArray[Int]` literal of at
     least 1,024 integer literals is materialised by `$pion_arr_copy` of a
     module-private stride-4 table instead of 1,024+ scalar stores.
     `roundtrip`: a 32-bit word survives the little-endian `w` directive.
     `neg_literal_word`: the 64-bit negation `(0L - v).to_int()` used for
     `-literal` has the same low 32 bits as the 32-bit negation (in
     particular for `-2147483648`). `array_equivalence`: the copied array has
     the same slots as the scalar initialisation. `fresh_objects` /
     `other_objects`: every evaluation yields a new object and leaves every
     other object (the private table included) untouched, so mutating one
     result is invisible to the next.
  3. `FlatRows` — an array of complete records whose fields are all string
     literals is written directly into the array slots
     (`qbe_flat_string_rows`). `sameHeap`: with immortal (interned literal)
     field pointers, the old evaluate-box / copy / drop path and the direct
     stores leave the same slots and reference counts, also when fields of
     different rows share one pointer.
  4. `SparseData` — `wasm_data_spans` emits the Wasm32 data image as active
     segments that skip the leading zero run, the trailing zero run and every
     interior zero run of at least 16 bytes, at most 4,096 segments.
     `encode_ok` / `region_equivalence`: on a freshly instantiated,
     module-defined (hence zero-filled) memory the segments recreate exactly
     the dense image, for any segment budget. `coalesce`: adjacent retained
     bytes may be merged into one segment.
-/
import Std

namespace QbeRealWorkloadDataOpts

namespace QuotedBytes

abbrev B := UInt8

def plain (b : B) : Bool :=
  b == 32 || b == 43 || (45 ≤ b && b ≤ 57) || b == 61 ||
  (65 ≤ b && b ≤ 90) || b == 95 || (97 ≤ b && b ≤ 122)

/-- QBE's quoted-data reader consumes these bytes literally in both native
    object writers and the Wasm reader: no escape, symbol or separator. -/
theorem literal_alphabet : ∀ b : B, plain b = true →
    32 ≤ b ∧ b < 127 ∧ b ≠ 34 ∧ b ≠ 92 ∧ b ≠ 36 ∧ b ≠ 35 ∧ b ≠ 44 := by
  decide +kernel

inductive Item where
  | number (b : B)
  | quoted (bytes : List B)
deriving Repr

def unpack : Item → List B
  | .number b => [b]
  | .quoted s => s

def valid : Item → Prop
  | .number _ => True
  | .quoted s => (∀ b ∈ s, plain b = true) ∧ 2 ≤ s.length

/-- The inner while loop consumes a maximal run, leaving its first delimiter
    for the outer loop. Input bytes model the output of `str_to_utf8_ints`
    (embedded NUL and every multibyte scalar included). -/
def scan : List B → List B × List B
  | [] => ([], [])
  | b :: bs => if plain b then
      let r := scan bs
      (b :: r.1, r.2)
    else ([], b :: bs)

theorem scan_spec (s : List B) :
    (scan s).1 ++ (scan s).2 = s ∧ (∀ b ∈ (scan s).1, plain b = true) := by
  induction s with
  | nil => simp [scan]
  | cons b bs ih =>
    cases h : plain b <;> simp_all [scan]

theorem suffix_len (s : List B) : (scan s).2.length ≤ s.length := by
  have h := congrArg List.length (scan_spec s).1
  simp only [List.length_append] at h
  omega

/-- `qbe_emit_bytes_data`: a quoted item starts only where two plain bytes
    follow each other. -/
def pack (raw : List B) : List Item :=
  match raw with
  | [] => []
  | [a] => [.number a]
  | a :: b :: tail =>
    if plain a && plain b then
      let r := scan tail
      .quoted (a :: b :: r.1) :: pack r.2
    else .number a :: pack (b :: tail)
termination_by raw.length
decreasing_by
  all_goals simp_wf
  all_goals have := suffix_len tail; omega

theorem pack_spec (raw : List B) :
    (pack raw).flatMap unpack = raw ∧ ∀ t ∈ pack raw, valid t := by
  fun_induction pack raw with
  | case1 => simp
  | case2 => simp [unpack, valid]
  | case3 a b tail h r ih =>
    have hrun := scan_spec tail
    have hb := Bool.and_eq_true_iff.mp h
    simp [r, unpack, valid, ih, hrun, hb]
    exact ⟨hrun.2, ih.2⟩
  | case4 a b tail h ih =>
    simp [unpack, valid, ih]
    exact ih.2

theorem same_static_bytes_and_length (raw : List B) :
    (pack raw ++ [Item.number 0]).flatMap unpack = raw ++ [0] ∧
    ((pack raw).flatMap unpack).length = raw.length := by
  simp [unpack, (pack_spec raw).1]

end QuotedBytes

namespace LiteralWords

abbrev Word := BitVec 32
abbrev Octets := Nat × Nat × Nat × Nat

/-- The little-endian bytes of a `w` data directive. -/
def encode (w : Word) : Octets :=
  (w.toNat % 256, w.toNat / 256 % 256, w.toNat / 65536 % 256, w.toNat / 16777216 % 256)

def decode (p : Octets) : Word :=
  BitVec.ofNat 32 (p.1 + 256 * p.2.1 + 65536 * p.2.2.1 + 16777216 * p.2.2.2)

theorem encode_bytes (w : Word) :
    (encode w).1 < 256 ∧ (encode w).2.1 < 256 ∧ (encode w).2.2.1 < 256 ∧ (encode w).2.2.2 < 256 := by
  simp only [encode]
  omega

theorem roundtrip (w : Word) : decode (encode w) = w := by
  apply BitVec.eq_of_toNat_eq
  have := w.isLt
  simp only [decode, encode, BitVec.toNat_ofNat]
  omega

/-- `-literal`: `(0L - v).to_int()` keeps the low 32 bits of the 64-bit
    negation; the former `0 - v.to_int()` negated after truncation. Both give
    the same word, `-2147483648` included. -/
theorem neg_literal_word (v : Int) :
    (0 - v) % 18446744073709551616 % 4294967296 = (0 - v % 4294967296) % 4294967296 := by
  omega

theorem int32_min_word : (0 - (2147483648 : Int)) % 18446744073709551616 % 4294967296 = 2147483648 := by
  decide

-- The operands have already passed the signed-literal check. Word models the
-- low 32 bits of both the scalar store and the static QBE word directive.
def stores (done : List Word) : List Word → List Word
  | [] => done.reverse
  | w :: ws => stores (w :: done) ws

theorem stores_spec (ws done : List Word) : stores done ws = done.reverse ++ ws := by
  induction ws generalizing done with
  | nil => simp [stores]
  | cons w ws ih => simp [stores, ih, List.append_assoc]

structure ArrayObject where
  length : Nat
  capacity : Nat
  stride : Nat
  ownsPointers : Bool
  slots : List Word

structure Heap where
  next : Nat
  objects : Nat → Option ArrayObject

def allocate (h : Heap) (slots : List Word) : Nat × Heap :=
  let obj : ArrayObject := ⟨slots.length, slots.length, 4, false, slots⟩
  (h.next, ⟨h.next + 1, fun id => if id == h.next then some obj else h.objects id⟩)

def scalar (h : Heap) (ws : List Word) := allocate h (stores [] ws)
def tableCopy (h : Heap) (ws : List Word) := allocate h ((ws.map encode).map decode)

theorem array_equivalence (h : Heap) (ws : List Word) : scalar h ws = tableCopy h ws := by
  simp [scalar, tableCopy, stores_spec, List.map_map, Function.comp_def, roundtrip]

theorem fresh_objects (h : Heap) (ws : List Word) :
    (tableCopy (tableCopy h ws).2 ws).1 ≠ (tableCopy h ws).1 := by
  simp [tableCopy, allocate]

theorem other_objects (h : Heap) (ws : List Word) (id : Nat) (ne : id ≠ h.next) :
    (tableCopy h ws).2.objects id = h.objects id := by
  simp [tableCopy, allocate, ne]

end LiteralWords

namespace FlatRows

/-- Pointer identities are those returned by the unchanged string interner.
    Multiple fields can contain exactly the same pointer, including cross-row
    aliases. -/
abbrev Ref := Nat
abbrev Row := List Ref

/-- The slots of the result array and the reference counts of all non-immortal
    objects are observable. A private, freshly allocated row box has no alias. -/
structure Heap where
  slots : List Ref
  counts : Ref → Nat

inductive CountOp where | inc | dec

def refOp (immortal : Ref → Bool) (op : CountOp) (p : Ref) (h : Heap) : Heap :=
  let changed := match op with
    | .inc => h.counts p + 1
    | .dec => h.counts p - 1
  if immortal p then h else
    { slots := h.slots, counts := fun q => if q = p then changed else h.counts q }

def refs (imm : Ref → Bool) (op : CountOp) (h : Heap) : Row → Heap
  | [] => h
  | p :: ps => refs imm op (refOp imm op p h) ps

theorem immortal_refs (imm : Ref → Bool) (op : CountOp) (h : Heap) (r : Row)
    (guard : ∀ p ∈ r, imm p = true) : refs imm op h r = h := by
  induction r generalizing h with
  | nil => rfl
  | cons p ps ih =>
    rw [refs, ih _ (fun q hq => guard q (by simp [hq]))]
    simp [refOp, guard p (by simp)]

structure Box where
  fields : Row

def store (h : Heap) (r : Row) : Heap := { h with slots := h.slots ++ r }

/-- The old path first evaluates all record expressions as distinct boxes.
    Each flat copy takes a reference to the fields, and dropping the
    unaliased temporary relinquishes its references and consumes the box. -/
def copyDrop (imm : Ref → Bool) (h : Heap) : List Box → Heap
  | [] => h
  | b :: bs =>
    let retained := refs imm .inc h b.fields
    let written := store retained b.fields
    copyDrop imm (refs imm .dec written b.fields) bs

def direct (h : Heap) : List Row → Heap
  | [] => h
  | row :: rs => direct (store h row) rs

theorem sameHeap (imm : Ref → Bool) (rows : List Row) (h : Heap)
    (guard : ∀ r ∈ rows, ∀ p ∈ r, imm p = true) :
    copyDrop imm h (rows.map Box.mk) = direct h rows := by
  induction rows generalizing h with
  | nil => rfl
  | cons r rs ih =>
    have hr := guard r (by simp)
    simp only [List.map_cons, copyDrop, direct, immortal_refs _ _ _ _ hr]
    exact ih _ (fun row hrow => guard row (by simp [hrow]))

end FlatRows

namespace SparseData

abbrev Byte := UInt8
inductive Run where
  | zero (len : Nat)
  | byte (b : Byte)

def dense : List Run → List Byte
  | [] => []
  | .zero n :: tail => List.replicate n 0 ++ dense tail
  | .byte b :: tail => b :: dense tail

def prepend (b : Byte) (rs : List Run) : List Run :=
  if b = 0 then
    match rs with
    | .zero n :: tail => .zero (n+1) :: tail
    | _ => .zero 1 :: rs
  else .byte b :: rs

theorem prepend_ok (b : Byte) (rs : List Run) :
    dense (prepend b rs) = b :: dense rs := by
  by_cases h : b = 0
  · subst b
    cases rs with
    | nil => rfl
    | cons r tail => cases r <;> simp [prepend, dense, List.replicate_succ]
  · simp [prepend, h, dense]

theorem scan_ok (xs : List Byte) : dense (xs.foldr prepend []) = xs := by
  induction xs with
  | nil => rfl
  | cons b bs ih => simp [prepend_ok, ih]

/-- Chunks advance the same cursor. A gap leaves the corresponding range of
    a freshly instantiated module-defined memory at its initial zero value. -/
inductive Chunk where
  | put (bytes : List Byte)
  | gap (count : Nat)

def initialized : List Chunk → List Byte
  | [] => []
  | .put bs :: cs => bs ++ initialized cs
  | .gap n :: cs => List.replicate n 0 ++ initialized cs

/-- `wasm_data_spans`: `lead` holds until the first byte is placed, so a
    leading zero run of any length is skipped (it only moves the first
    segment's offset), as are the trailing run and interior runs of at least
    16 bytes while the segment budget lasts. -/
def encode (budget : Nat) (lead : Bool) : List Run → List Chunk
  | [] => []
  | .byte b :: rs => .put [b] :: encode budget false rs
  | .zero n :: rs =>
    if budget > 0 && (lead || n ≥ 16 || rs.isEmpty) then
      .gap n :: encode (budget-1) false rs
    else .put (List.replicate n 0) :: encode budget false rs

theorem encode_ok (rs : List Run) (budget : Nat) (lead : Bool) :
    initialized (encode budget lead rs) = dense rs := by
  induction rs generalizing budget lead with
  | nil => rfl
  | cons r rs ih =>
    cases r with
    | byte b => simp [encode, initialized, dense, ih]
    | zero n => simp only [encode, dense]; split <;> simp [initialized, ih]

/-- Coalescing adjacent writes into a single active segment preserves both
    cursor advancement and bytes, including any deliberately retained zeros. -/
theorem coalesce (a b : List Byte) (cs : List Chunk) :
    initialized (.put a :: .put b :: cs) = initialized (.put (a ++ b) :: cs) := by
  simp [initialized, List.append_assoc]

theorem region_equivalence (before bytes after : List Byte) (budget : Nat) :
    before ++ initialized (encode budget true (bytes.foldr prepend [])) ++ after =
    before ++ bytes ++ after := by rw [encode_ok, scan_ok]

end SparseData

end QbeRealWorkloadDataOpts
