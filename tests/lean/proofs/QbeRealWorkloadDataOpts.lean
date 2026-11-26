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
     interior zero run of at least 16 bytes, at most 4,096 segments. `loop` /
     `wasmDataSpans` model the function one to one (committed spans only
     count against the budget, the dense tail `[start, len)` comes last).
     `rebuild`: writing the returned spans into zero-filled memory gives back
     the image byte for byte; `span_count`: at most `maxSpans` spans;
     `span_bounds`: every span is a non-empty range of the image, ascending
     and non-overlapping; `all_zero`: an all-zero image needs no span
     (section 11 omitted); `leading_zero_budget` / `leading_zero_budget_4096`:
     a leading zero takes none of the budget, so a leading zero, 4,095 cut
     blocks and a final byte give exactly 4,096 spans.
-/
import Std

namespace QbeRealWorkloadDataOpts

theorem ite_pos' {c : Prop} [Decidable c] {α : Sort _} {a b : α} (h : c) :
    (if c then a else b) = a := by simp [h]

theorem ite_neg' {c : Prop} [Decidable c] {α : Sort _} {a b : α} (h : ¬c) :
    (if c then a else b) = b := by simp [h]

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

/-- Heap well-formedness: no object lives at or above the allocation cursor. -/
def Heap.wf (h : Heap) : Prop := ∀ k, h.next ≤ k → h.objects k = none

theorem alloc_wf (h : Heap) (ws : List Word) (hw : h.wf) : (tableCopy h ws).2.wf := by
  intro k hk
  simp [tableCopy, allocate] at hk ⊢
  rw [ite_neg' (by omega)]
  exact hw k (by omega)

/-- On a well-formed heap the new array takes a free slot, so no existing object
    (the private word table included) is overwritten. -/
theorem alloc_fresh (h : Heap) (ws : List Word) (hw : h.wf) :
    h.objects (tableCopy h ws).1 = none ∧
    ∀ id, h.objects id ≠ none → (tableCopy h ws).2.objects id = h.objects id := by
  refine ⟨hw _ (by simp [tableCopy, allocate]), ?_⟩
  intro id hid
  have : id ≠ h.next := fun he => hid (by rw [he]; exact hw _ (Nat.le_refl _))
  exact other_objects h ws id this

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

/-- Length of the leading zero run (the inner `while bytes[i] == 0` loop). -/
def zrun : List Byte → Nat
  | [] => 0
  | b :: t => if b = 0 then zrun t + 1 else 0

theorem zrun_le (l : List Byte) : zrun l ≤ l.length := by
  induction l with
  | nil => simp [zrun]
  | cons b t ih => simp only [zrun]; split <;> simp <;> omega

theorem zrun_zero (l : List Byte) : ∀ t < zrun l, l.getD t 0 = 0 := by
  induction l with
  | nil => simp [zrun]
  | cons b tl ih =>
    intro t ht
    simp only [zrun] at ht
    split at ht
    · cases t with
      | zero => simp_all
      | succ t => simpa using ih t (by omega)
    · omega

theorem zrun_pos (b : Byte) (tl : List Byte) (h : b = 0) : 1 ≤ zrun (b :: tl) := by
  simp [zrun, h]

theorem zrun_replicate_append (k : Nat) (l : List Byte) :
    zrun (List.replicate k 0 ++ l) = k + zrun l := by
  induction k with
  | zero => simp
  | succ k ih => simp [List.replicate_succ, zrun, ih]; omega

theorem getD_drop (l : List Byte) (n t : Nat) : (l.drop n).getD t 0 = l.getD (n + t) 0 := by
  induction l generalizing n with
  | nil => simp
  | cons b tl ih =>
    cases n with
    | zero => simp
    | succ n => simp only [List.drop_succ_cons]; rw [ih]; simp [Nat.succ_add]

/-- One-to-one model of the scan loop of `wasm_data_spans`
    (`compiler/src/core/wasm.pion`): `rest` is `bytes[pos..]`, `start` the
    first byte not yet placed in a span, `acc` the committed spans and `cap`
    the bound of the loop (4,095). A leading zero run (`zero == start`) and
    every cut only move `start`; a span is committed only when it is
    non-empty, so only committed spans count against `cap`. -/
def loop (cap : Nat) (rest : List Byte) (pos start : Nat) (acc : List (Nat × Nat)) :
    List (Nat × Nat) × Nat :=
  if cap ≤ acc.length then (acc, start) else
  match rest with
  | [] => (acc, start)
  | b :: tl =>
    if b ≠ 0 then loop cap tl (pos + 1) start acc
    else
      if pos = start ∨ 16 ≤ zrun (b :: tl) ∨ (b :: tl).drop (zrun (b :: tl)) = [] then
        loop cap ((b :: tl).drop (zrun (b :: tl))) (pos + zrun (b :: tl)) (pos + zrun (b :: tl))
          (if start < pos then acc ++ [(start, pos)] else acc)
      else loop cap ((b :: tl).drop (zrun (b :: tl))) (pos + zrun (b :: tl)) start acc
termination_by rest.length
decreasing_by
  all_goals simp_wf
  all_goals
    have := zrun_pos b tl (by simpa using ‹¬b ≠ 0›)
    have := zrun_le (b :: tl)
    simp at *
    omega

/-- `wasm_data_spans bytes` with at most `maxSpans` (4,096) spans: the scan,
    then the dense tail `[start, len)` when it is not empty. -/
def wasmDataSpans (bytes : List Byte) (maxSpans : Nat) : List (Nat × Nat) :=
  let r := loop (maxSpans - 1) bytes 0 0 []
  if r.2 < bytes.length then r.1 ++ [(r.2, bytes.length)] else r.1

/-- Writing every span `[s, e)` of `bytes` at its offset into a freshly
    instantiated, module-defined (zero-filled) memory of the image's size. -/
def applySpans (bytes : List Byte) (spans : List (Nat × Nat)) : List Byte :=
  (List.range bytes.length).map fun j =>
    if spans.any (fun p => decide (p.1 ≤ j ∧ j < p.2)) then bytes.getD j 0 else 0

def Covers (spans : List (Nat × Nat)) (j : Nat) : Prop := ∃ p ∈ spans, p.1 ≤ j ∧ j < p.2

def Ordered (spans : List (Nat × Nat)) : Prop := spans.Pairwise (fun a b => a.2 ≤ b.1)

theorem loop_inv (bytes : List Byte) (cap : Nat) (rest : List Byte) (pos start : Nat)
    (acc : List (Nat × Nat))
    (hrest : rest = bytes.drop pos) (hpos : pos ≤ bytes.length) (hstart : start ≤ pos)
    (hlen : acc.length ≤ cap) (hspan : ∀ p ∈ acc, p.1 < p.2 ∧ p.2 ≤ start)
    (hord : Ordered acc) (hcov : ∀ j < start, bytes.getD j 0 ≠ 0 → Covers acc j) :
    (loop cap rest pos start acc).1.length ≤ cap ∧
    (loop cap rest pos start acc).2 ≤ bytes.length ∧
    (∀ p ∈ (loop cap rest pos start acc).1, p.1 < p.2 ∧ p.2 ≤ (loop cap rest pos start acc).2) ∧
    Ordered (loop cap rest pos start acc).1 ∧
    (∀ j < (loop cap rest pos start acc).2, bytes.getD j 0 ≠ 0 →
      Covers (loop cap rest pos start acc).1 j) := by
  fun_induction loop cap rest pos start acc with
  | case1 rest pos start acc h =>
    exact ⟨hlen, show start ≤ bytes.length by omega, hspan, hord, hcov⟩
  | case2 pos start acc h =>
    exact ⟨hlen, show start ≤ bytes.length by omega, hspan, hord, hcov⟩
  | case3 pos start acc h b tl hb ih =>
    have hd : tl = bytes.drop (pos + 1) := by
      rw [← List.drop_drop, ← hrest]; simp
    have : pos < bytes.length := by
      have := congrArg List.length hrest; simp at this; omega
    exact ih hd (by omega) (by omega) hlen hspan hord hcov
  | case4 pos start acc h b tl hb hc ih =>
    have hk := zrun_le (b :: tl)
    have hz := zrun_zero (b :: tl)
    have hlenr : (b :: tl).length = bytes.length - pos := by rw [hrest]; simp
    have hd : (b :: tl).drop (zrun (b :: tl)) = bytes.drop (pos + zrun (b :: tl)) := by
      rw [hrest, List.drop_drop, Nat.add_comm]
    apply ih hd (by omega) (by omega)
    · split <;> (try simp) <;> omega
    · intro p hp
      split at hp
      · simp at hp
        rcases hp with hp | hp
        · have := hspan p hp; omega
        · subst hp; simp; omega
      · have := hspan p hp; omega
    · split
      · unfold Ordered
        rw [List.pairwise_append]
        refine ⟨hord, by simp, ?_⟩
        intro a ha c hc'
        simp at hc'; subst hc'
        exact (hspan a ha).2
      · exact hord
    · intro j hj hnz
      by_cases h1 : j < start
      · obtain ⟨p, hp, hp'⟩ := hcov j h1 hnz
        refine ⟨p, ?_, hp'⟩
        split <;> simp [hp]
      · by_cases h2 : j < pos
        · have : start < pos := by omega
          refine ⟨(start, pos), ?_, by simp; omega⟩
          simp [this]
        · exfalso
          apply hnz
          have := hz (j - pos) (by omega)
          rw [hrest, getD_drop] at this
          rwa [show pos + (j - pos) = j by omega] at this
  | case5 pos start acc h b tl hb hc ih =>
    have hk := zrun_le (b :: tl)
    have hlenr : (b :: tl).length = bytes.length - pos := by rw [hrest]; simp
    have hd : (b :: tl).drop (zrun (b :: tl)) = bytes.drop (pos + zrun (b :: tl)) := by
      rw [hrest, List.drop_drop, Nat.add_comm]
    exact ih hd (by omega) (by omega) hlen hspan hord hcov

theorem spans_inv (bytes : List Byte) (maxSpans : Nat) (hm : 1 ≤ maxSpans) :
    (wasmDataSpans bytes maxSpans).length ≤ maxSpans ∧
    (∀ p ∈ wasmDataSpans bytes maxSpans, p.1 < p.2 ∧ p.2 ≤ bytes.length) ∧
    Ordered (wasmDataSpans bytes maxSpans) ∧
    (∀ j < bytes.length, bytes.getD j 0 ≠ 0 → Covers (wasmDataSpans bytes maxSpans) j) := by
  have I := loop_inv bytes (maxSpans - 1) bytes 0 0 [] (by simp) (by omega) (by omega)
    (by simp) (by simp) (by simp [Ordered]) (by intro j hj; omega)
  obtain ⟨h1, h2, h3, h4, h5⟩ := I
  unfold wasmDataSpans
  simp only
  split
  · rename_i ht
    refine ⟨by simp; omega, ?_, ?_, ?_⟩
    · intro p hp
      simp at hp
      rcases hp with hp | hp
      · have := h3 p hp; omega
      · subst hp; simp; omega
    · unfold Ordered
      rw [List.pairwise_append]
      refine ⟨h4, by simp, ?_⟩
      intro a ha c hc
      simp at hc; subst hc
      exact (h3 a ha).2
    · intro j hj hnz
      by_cases hjs : j < (loop (maxSpans - 1) bytes 0 0 []).2
      · obtain ⟨p, hp, hp'⟩ := h5 j hjs hnz
        exact ⟨p, by simp [hp], hp'⟩
      · exact ⟨((loop (maxSpans - 1) bytes 0 0 []).2, bytes.length), by simp,
          Nat.le_of_not_lt hjs, hj⟩
  · refine ⟨by omega, ?_, h4, ?_⟩
    · intro p hp; have := h3 p hp; omega
    · intro j hj hnz; exact h5 j (by omega) hnz

/-- At most `maxSpans` segments. -/
theorem span_count (bytes : List Byte) (maxSpans : Nat) (hm : 1 ≤ maxSpans) :
    (wasmDataSpans bytes maxSpans).length ≤ maxSpans :=
  (spans_inv bytes maxSpans hm).1

/-- Every segment is a non-empty range of the image, in ascending order without
    overlap. -/
theorem span_bounds (bytes : List Byte) (maxSpans : Nat) (hm : 1 ≤ maxSpans) :
    (∀ p ∈ wasmDataSpans bytes maxSpans, p.1 < p.2 ∧ p.2 ≤ bytes.length) ∧
    Ordered (wasmDataSpans bytes maxSpans) :=
  ⟨(spans_inv bytes maxSpans hm).2.1, (spans_inv bytes maxSpans hm).2.2.1⟩

/-- Writing the segments into zero-filled memory rebuilds the image byte for
    byte. -/
theorem rebuild (bytes : List Byte) (maxSpans : Nat) (hm : 1 ≤ maxSpans) :
    applySpans bytes (wasmDataSpans bytes maxSpans) = bytes := by
  have hc := (spans_inv bytes maxSpans hm).2.2.2
  apply List.ext_getElem
  · simp [applySpans]
  · intro j h1 h2
    simp only [applySpans, List.getElem_map, List.getElem_range]
    have hg : bytes.getD j 0 = bytes[j] := by simp [List.getD, h2]
    split
    · exact hg
    · rename_i hn
      rw [← hg]
      by_cases hz : bytes.getD j 0 = 0
      · exact hz.symm
      · exfalso
        apply hn
        obtain ⟨p, hp, hp'⟩ := hc j h2 hz
        rw [List.any_eq_true]
        exact ⟨p, hp, by simp [hp']⟩

/-- An all-zero image needs no segment, so section 11 is omitted. -/
theorem all_zero (n maxSpans : Nat) (hm : 2 ≤ maxSpans) :
    wasmDataSpans (List.replicate n 0) maxSpans = [] := by
  cases n with
  | zero => simp [wasmDataSpans, loop.eq_def]
  | succ n =>
    have hz := zrun_replicate_append (n + 1) []
    simp only [List.append_nil, zrun, Nat.add_zero, List.replicate_succ] at hz
    have hl : loop (maxSpans - 1) ((0 : Byte) :: List.replicate n 0) 0 0 [] = ([], n + 1) := by
      rw [loop.eq_def, ite_neg' (by simp; omega)]
      have hd : List.drop (zrun ((0 : Byte) :: List.replicate n 0)) ((0 : Byte) :: List.replicate n 0) = [] := by
        rw [show zrun ((0 : Byte) :: List.replicate n 0) = n + 1 by simpa [zrun] using hz]
        simp
      simp only [ne_eq, not_true_eq_false, ite_false, true_or, ite_true, Nat.lt_irrefl, hd]
      rw [show zrun ((0 : Byte) :: List.replicate n 0) = n + 1 by simpa [zrun] using hz,
        loop.eq_def]
      simp <;> omega
    unfold wasmDataSpans
    rw [List.replicate_succ, hl]
    simp

/-- Blocks `1, 0 × 16` (one non-zero byte, then a cut). -/
def blocks (m : Nat) : List Byte := (List.replicate m ((1 : Byte) :: List.replicate 16 0)).flatten

theorem blocks_succ (m : Nat) :
    blocks (m + 1) = (1 : Byte) :: List.replicate 16 0 ++ blocks m := by
  simp [blocks, List.replicate_succ]

theorem zrun_blocks_one (m : Nat) : zrun (blocks m ++ [1]) = 0 := by
  cases m with
  | zero => simp [blocks, zrun]
  | succ m => rw [blocks_succ]; simp [zrun]

theorem loop_blocks (cap r p : Nat) (acc : List (Nat × Nat)) (h : acc.length + r = cap) :
    loop cap (blocks r ++ [1]) p p acc =
      (acc ++ (List.range r).map (fun i => (p + 17 * i, p + 17 * i + 1)), p + 17 * r) := by
  induction r generalizing p acc with
  | zero =>
    rw [loop.eq_def, ite_pos' (by omega)]; simp
  | succ r ih =>
    rw [blocks_succ, loop.eq_def, ite_neg' (by omega)]
    simp only [List.cons_append, ne_eq, show ¬((1 : Byte) = 0) by decide, not_false_eq_true,
      ite_true]
    have hrep : List.replicate 16 (0 : Byte) ++ blocks r ++ [1] =
        (0 : Byte) :: (List.replicate 15 0 ++ (blocks r ++ [1])) := by
      simp [List.replicate_succ]
    rw [hrep, loop.eq_def, ite_neg' (by omega)]
    have hz : zrun ((0 : Byte) :: (List.replicate 15 0 ++ (blocks r ++ [1]))) = 16 := by
      have := zrun_replicate_append 16 (blocks r ++ [1])
      rw [zrun_blocks_one] at this
      simpa [List.replicate_succ] using this
    have hd : ((0 : Byte) :: (List.replicate 15 0 ++ (blocks r ++ [1]))).drop 16 = blocks r ++ [1] := by
      simp [List.replicate_succ]
    simp only [ne_eq, not_true_eq_false, ite_false, hz, hd]
    rw [ite_pos' (by omega), ite_pos' (by omega)]
    rw [show p + 1 + 16 = p + 17 by omega, ih (p + 17) (acc ++ [(p, p + 1)]) (by simp; omega)]
    simp only [List.range_succ_eq_map, List.map_cons, List.map_map, List.append_assoc,
      List.singleton_append]
    refine Prod.ext ?_ (by simp; omega)
    simp [Function.comp_def]
    intro a _
    omega

/-- The 4,096-segment boundary: a leading zero, `maxSpans - 1` cut blocks and a
    final non-zero byte give exactly `maxSpans` segments; the leading zero
    takes no segment of the budget (same result as `wasm_data_spans`). -/
theorem leading_zero_budget (m : Nat) (hm : 1 ≤ m) :
    wasmDataSpans ((0 : Byte) :: (blocks m ++ [1])) (m + 1) =
      (List.range m).map (fun i => (1 + 17 * i, 1 + 17 * i + 1)) ++ [(1 + 17 * m, 2 + 17 * m)] := by
  have hlen : ((0 : Byte) :: (blocks m ++ [1])).length = 2 + 17 * m := by
    simp [blocks]; omega
  have hz : zrun ((0 : Byte) :: (blocks m ++ [1])) = 1 := by
    simp [zrun, zrun_blocks_one]
  have hl : loop m ((0 : Byte) :: (blocks m ++ [1])) 0 0 [] =
      ((List.range m).map (fun i => (1 + 17 * i, 1 + 17 * i + 1)), 1 + 17 * m) := by
    rw [loop.eq_def, ite_neg' (by simp; omega)]
    simp only [ne_eq, not_true_eq_false, ite_false, hz, true_or, ite_true, List.drop_succ_cons,
      List.drop_zero, Nat.lt_irrefl, Nat.zero_add]
    rw [loop_blocks m m 1 [] (by simp)]
    simp
  unfold wasmDataSpans
  simp only [Nat.add_sub_cancel, hl, hlen]
  rw [ite_pos' (by omega)]

theorem leading_zero_budget_4096 :
    (wasmDataSpans ((0 : Byte) :: (blocks 4095 ++ [1])) 4096).length = 4096 := by
  rw [leading_zero_budget 4095 (by decide)]; simp

end SparseData

end QbeRealWorkloadDataOpts
