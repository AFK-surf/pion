/-
Invariants behind the native `pion_str_concat_n` integer scratch parts
(`qbe_concat_part` in `compiler/src/core/qbe.pion`):

  In a flattened 3..8 part native string concatenation, a built-in
  `Int` / `Int64` `.to_string()` part (no trait dispatch) is formatted by the
  existing `pion_strbuf_push_int` into a pseudo `PionString` living in its own
  nonescaping caller stack slot (8 B `len` + 24 payload bytes), through a
  stack `PionStrBuf { len = 0, cap = 24, data = slot + 8 }`, instead of a heap
  temporary from `pion_int_to_str`.

  1. `width_le`, `no_grow`: a signed 64-bit decimal (magnitude at most 2^63)
     has at most 19 digits, so digits, sign and NUL fit the 24-byte payload:
     `pion_strbuf_reserve` (`need = len + add + 1 > cap`) never grows (and so
     never frees or reallocates) the stack buffer.
  2. `extsw_preserves`: the `Int` receiver is widened with `extsw`, which keeps
     its value, so both paths format the same 64-bit integer.
  3. `observe`: `pion_str_concat_n` reads only `len` and the first `len`
     payload bytes, so a stack payload (digits, NUL, stale bytes) and the heap
     string of the same digits are observationally equal.
  4. `fill_frame`, `scratch_concat`, `slot_reuse`: every scratch part owns a
     distinct slot (indexed by its position in the chain), all parts are
     materialized left to right before `concat_n` reads them, and the result
     equals the heap path for any initial slot contents, so parts never
     overwrite each other and a loop may reuse the same slots.

The formatter itself is shared (`pion_fmt_i64_end` behind both
`pion_int_to_str` and `pion_strbuf_push_int`) and kept abstract as `fmt`.
No imports and no proof holes; plain kernel checks (compatible with both
standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeConcatScratch

/-- Decimal digit count of a magnitude (`0` is spelled with one digit). -/
def width (n : Nat) : Nat :=
  if n < 10 then 1 else width (n / 10) + 1
termination_by n
decreasing_by omega

theorem width_le (k n : Nat) (h : n < 10 ^ (k + 1)) : width n ≤ k + 1 := by
  induction k generalizing n with
  | zero =>
    simp at h
    simp [width, h]
  | succ k ih =>
    rw [width]
    split
    · omega
    · have hb : n / 10 < 10 ^ (k + 1) := by
        rw [Nat.pow_succ] at h
        omega
      have := ih (n / 10) hb
      omega

/-- Capacity check of `pion_strbuf_reserve` on the empty stack buffer
(`len = 0`, `cap = 24`): every `Int64` decimal (magnitude at most `2^63`,
reached by `INT64_MIN`) plus its sign and the NUL fits. -/
theorem no_grow (magnitude : Nat) (neg : Bool)
    (bounded : magnitude ≤ 9223372036854775808) :
    0 + (width magnitude + (if neg then 1 else 0)) + 1 ≤ 24 := by
  have h : magnitude < 10 ^ 19 := by omega
  have d := width_le 18 magnitude h
  cases neg <;> simp <;> omega

/-- `extsw` from the 32-bit `Int` register to the 64-bit formatter argument
keeps the signed value (`INT32_MIN` and `INT32_MAX` included). -/
theorem extsw_preserves (x : BitVec 32) : (x.signExtend 64).toInt = x.toInt :=
  BitVec.toInt_signExtend_of_le (by decide)

/-- What `pion_str_concat_n` observes of a part: `len` and its first `len`
payload bytes. -/
structure Payload where
  len : Nat
  data : List UInt8

def read (p : Payload) : List UInt8 := p.data.take p.len

/-- Heap path: `pion_int_to_str` allocates exactly the digits plus NUL. -/
def heap (digits : List UInt8) : Payload := ⟨digits.length, digits ++ [0]⟩

/-- Stack path: `pion_strbuf_push_int` writes digits and NUL over the slot's
old bytes; `len` is copied from the buffer into the pseudo string. -/
def stack (old digits : List UInt8) : Payload :=
  ⟨digits.length, digits ++ [0] ++ old.drop (digits.length + 1)⟩

theorem observe (old digits : List UInt8) :
    read (stack old digits) = read (heap digits) := by
  simp [stack, heap, read, List.append_assoc]

/-- A chain part in source order: an ordinary string, or the already
evaluated receiver of a built-in integer `.to_string()`. -/
inductive Part where
  | str : Payload → Part
  | int : Int → Part

/-- Caller stack slots, one per chain position. -/
abbrev Slots := Nat → Payload

def upd (s : Slots) (i : Nat) (p : Payload) : Slots :=
  fun j => if j = i then p else s j

/-- Left-to-right materialization: part `i` formats into slot `i` only. -/
def fill (fmt : Int → List UInt8) : Nat → List Part → Slots → Slots
  | _, [], s => s
  | i, .str _ :: t, s => fill fmt (i + 1) t s
  | i, .int v :: t, s => fill fmt (i + 1) t (upd s i (stack (s i).data (fmt v)))

/-- `pion_str_concat_n` over the part array of the scratch path. -/
def readAll : Nat → List Part → Slots → List UInt8
  | _, [], _ => []
  | i, .str p :: t, s => read p ++ readAll (i + 1) t s
  | i, .int _ :: t, s => read (s i) ++ readAll (i + 1) t s

/-- `pion_str_concat_n` over heap temporaries (the original lowering). -/
def heapAll (fmt : Int → List UInt8) : List Part → List UInt8
  | [] => []
  | .str p :: t => read p ++ heapAll fmt t
  | .int v :: t => read (heap (fmt v)) ++ heapAll fmt t

/-- Later parts never write an earlier part's slot. -/
theorem fill_frame (fmt : Int → List UInt8) (ps : List Part) (i j : Nat)
    (s : Slots) (h : j < i) : fill fmt i ps s j = s j := by
  induction ps generalizing i s with
  | nil => rfl
  | cons a t ih =>
    cases a with
    | str p => simp only [fill]; exact ih (i + 1) s (by omega)
    | int v =>
      simp only [fill]
      rw [ih (i + 1) _ (by omega)]
      simp [upd]
      omega

theorem scratch_concat (fmt : Int → List UInt8) (ps : List Part) (i : Nat)
    (s : Slots) : readAll i ps (fill fmt i ps s) = heapAll fmt ps := by
  induction ps generalizing i s with
  | nil => rfl
  | cons a t ih =>
    cases a with
    | str p => simp only [fill, readAll, heapAll, ih]
    | int v =>
      simp only [fill, readAll, heapAll, ih]
      rw [fill_frame fmt t (i + 1) i _ (by omega)]
      simp [upd, observe]

/-- The result does not depend on what a previous loop iteration (or any
other code) left in the slots. -/
theorem slot_reuse (fmt : Int → List UInt8) (ps : List Part) (s₁ s₂ : Slots) :
    readAll 0 ps (fill fmt 0 ps s₁) = readAll 0 ps (fill fmt 0 ps s₂) := by
  rw [scratch_concat, scratch_concat]

end PionQbeConcatScratch
