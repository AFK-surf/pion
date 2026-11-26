/-
Soundness models for Wave AA3 (canonical drop functions,
`compiler/src/core/qbe.pion`; regression tests `aa3_*` in
`compiler/src/core/backend_test.pion` and Part 4 of
`tests/e2e/p89_unit_enum/run_e2e.sh`).

An object's payload is a map from byte offsets to 64-bit slot words (`0` is
the null pointer). A drop body is a list of slot instructions; running it
yields the ordered list of objects handed to `pion_rc_dec`. `pion_rc_dec`
returns immediately on `NULL` (`runtime/pion_rt.c`), so a call on `0` has no
observable effect and contributes nothing to the trace.

  1. `struct_drop_slots_equiv` — the removed per-type
     `$pion_drop_struct_<S>` (null-guarded `pion_rc_dec` of every RC field `k`
     at offset `8k`, in field order) and the canonical
     `$pion_drop_slots_<key>` registered with the same RC field indices
     (`qbe_register_slot_drop`: sorted, de-duplicated, null-guarded, offset
     `8k`) perform exactly the same ordered `pion_rc_dec` sequence.
  2. `niche_enum_drop_slots_equiv` — the removed tagless niche
     `$pion_drop_enum_<E>` (unguarded `pion_rc_dec` at
     `payload_offset + 8k`) and the canonical helper over the slots
     `payload_offset / 8 + k` agree for every 8-aligned `payload_offset`
     (it is `0` for niche enums).
  3. `slot_drop_alias_count` — the trace drops an object once per slot that
     holds it: two slots aliasing one object decrement it twice.
  4. `slot_key_injective` — the decimal-mask key names exactly one sorted
     slot set, so registering a key once and reusing its body for every
     later struct / niche enum / generic instance with that key is sound.
  5. `zero_rc_tagged_enum_null_drop_equiv` — a tagged enum drop that reads
     the tag and dispatches only over variants with RC slots is observably
     equal to `drop_fn = NULL` when no variant has an RC slot;
     `rc_tagged_enum_drop_needed` shows the converse: one RC variant makes
     the drop observable, so it must be kept.
  6. `suffix_injective` — the emitted `$pion_drop_slots_<suffix>`
     (`qbe_slot_drop_suffix`): decimal mask for `max ≤ 30`, `x_` + 4-digit hex
     chunks for `31 ≤ max ≤ 127`, `w_<idx>` beyond, as code-point strings.
     Each namespace is injective (`decKey_inj`, `hexKey_eq_sets`), the three
     are pairwise disjoint (`namespaces_disjoint`), and with the table's
     one-index-per-set contract (`table_index_contract`) two registered sets
     share a symbol iff they are equal.

The models cover the emitted drop bodies and the runtime's destroy step;
the correspondence with the Pion sources is checked by the regression tests
above.
-/
import Std

namespace PionWaveAA3Drops

/-- Payload memory: byte offset ↦ 64-bit slot word (`0` = null). -/
abbrev Mem := Nat → Nat

/-- Effect of `pion_rc_dec(v)`: a no-op on `NULL`, otherwise one decrement. -/
def rcDec (v : Nat) : List Nat := if v = 0 then [] else [v]

/-- One emitted slot instruction. -/
inductive Instr where
  /-- `load off; jnz v != 0 → call $pion_rc_dec(v)` -/
  | guardedDec (off : Nat)
  /-- `load off; call $pion_rc_dec(v)` (no null guard) -/
  | dec (off : Nat)

def Instr.run (m : Mem) : Instr → List Nat
  | .guardedDec off => if m off ≠ 0 then rcDec (m off) else []
  | .dec off => rcDec (m off)

/-- Ordered `pion_rc_dec` trace of a straight-line drop body. -/
def runBody (m : Mem) (b : List Instr) : List Nat := b.flatMap (Instr.run m)

theorem guarded_eq_dec (m : Mem) (off : Nat) :
    Instr.run m (.guardedDec off) = Instr.run m (.dec off) := by
  simp only [Instr.run, rcDec]
  split <;> simp_all

/-! ## Slot-set canonicalisation (`qbe_sort_unique_slots`) -/

/-- Sorted insertion (`out.push(v)` followed by the bubble-down loop). -/
def insertSorted (v : Nat) : List Nat → List Nat
  | [] => [v]
  | x :: xs => if v ≤ x then v :: x :: xs else x :: insertSorted v xs

/-- One step of `qbe_sort_unique_slots`: skip duplicates, insert sorted. -/
def insertDedup (out : List Nat) (v : Nat) : List Nat :=
  if v ∈ out then out else insertSorted v out

def sortUnique (slots : List Nat) : List Nat := slots.foldl insertDedup []

/-- Strictly increasing slot list (the field order of RC slots). -/
abbrev StrictSorted (l : List Nat) : Prop := l.Pairwise (· < ·)

theorem insertSorted_append (v : Nat) :
    ∀ out : List Nat, (∀ a ∈ out, a < v) → insertSorted v out = out ++ [v]
  | [], _ => rfl
  | x :: xs, h => by
    have hx : x < v := h x (by simp)
    have ih := insertSorted_append v xs (fun a ha => h a (by simp [ha]))
    simp [insertSorted, Nat.not_le.mpr hx, ih]

theorem foldl_insertDedup_sorted :
    ∀ (l acc : List Nat), StrictSorted l → (∀ a ∈ acc, ∀ b ∈ l, a < b) →
      l.foldl insertDedup acc = acc ++ l
  | [], acc, _, _ => by simp
  | v :: vs, acc, hs, hlt => by
    have hv : ∀ a ∈ acc, a < v := fun a ha => hlt a ha v (by simp)
    have hnot : v ∉ acc := fun hm => Nat.lt_irrefl v (hv v hm)
    have hstep : insertDedup acc v = acc ++ [v] := by
      simp only [insertDedup, hnot, ↓reduceIte]
      exact insertSorted_append v acc hv
    have hs' := List.pairwise_cons.mp hs
    simp only [List.foldl_cons, hstep]
    rw [foldl_insertDedup_sorted vs (acc ++ [v]) hs'.2]
    · simp
    · intro a ha b hb
      rcases List.mem_append.mp ha with ha | ha
      · exact hlt a ha b (by simp [hb])
      · simp at ha
        subst ha
        exact hs'.1 b hb

/-- Field-order RC slots are already canonical. -/
theorem sortUnique_of_sorted (l : List Nat) (h : StrictSorted l) : sortUnique l = l := by
  unfold sortUnique
  rw [foldl_insertDedup_sorted l [] h (by simp)]
  simp

/-! ## 1–2. Per-type drops vs the canonical slot helper -/

/-- Removed `$pion_drop_struct_<S>`: RC fields in field order, offset `8k`. -/
def perTypeStructBody (slots : List Nat) : List Instr :=
  slots.map (fun k => .guardedDec (8 * k))

/-- Removed tagless niche `$pion_drop_enum_<E>`: offset `payload_offset + 8k`. -/
def nicheEnumBody (payloadOffset : Nat) (slots : List Nat) : List Instr :=
  slots.map (fun k => .dec (payloadOffset + 8 * k))

/-- `$pion_drop_slots_<key>` as `qbe_emit_helper_drops` emits it. -/
def slotHelperBody (slots : List Nat) : List Instr :=
  (sortUnique slots).map (fun k => .guardedDec (8 * k))

/-- The trace of the canonical helper: every non-null slot word, in slot order. -/
theorem slotHelper_trace (m : Mem) (slots : List Nat) :
    runBody m (slotHelperBody slots) = (sortUnique slots).flatMap (fun k => rcDec (m (8 * k))) := by
  simp only [runBody, slotHelperBody, List.flatMap_map]
  congr 1
  funext k
  exact guarded_eq_dec m (8 * k)

theorem struct_drop_slots_equiv (m : Mem) (slots : List Nat) (h : StrictSorted slots) :
    runBody m (perTypeStructBody slots) = runBody m (slotHelperBody slots) := by
  simp only [runBody, perTypeStructBody, slotHelperBody, sortUnique_of_sorted slots h]

theorem map_add_strictSorted (c : Nat) (l : List Nat) (h : StrictSorted l) :
    StrictSorted (l.map (c + ·)) := by
  simp only [StrictSorted, List.pairwise_map]
  exact h.imp (fun hab => by omega)

/-- The niche payload slot index `payload_offset / 8 + k` addresses the same
    byte offset as the removed tagless drop. -/
theorem niche_offset (po k : Nat) (h : po % 8 = 0) : 8 * (po / 8 + k) = po + 8 * k := by
  omega

theorem niche_enum_drop_slots_equiv (m : Mem) (po : Nat) (slots : List Nat)
    (hpo : po % 8 = 0) (h : StrictSorted slots) :
    runBody m (nicheEnumBody po slots) = runBody m (slotHelperBody (slots.map (po / 8 + ·))) := by
  rw [slotHelper_trace, sortUnique_of_sorted _ (map_add_strictSorted _ _ h)]
  simp only [runBody, nicheEnumBody, List.flatMap_map, Instr.run]
  congr 1
  funext k
  rw [niche_offset po k hpo]

/-- Niche enums use `payload_offset = 0`: the helper slots are the field indices. -/
theorem niche_enum_drop_slots_equiv_zero (m : Mem) (slots : List Nat) (h : StrictSorted slots) :
    runBody m (nicheEnumBody 0 slots) = runBody m (slotHelperBody slots) := by
  have := niche_enum_drop_slots_equiv m 0 slots (by decide) h
  simp only [Nat.zero_div, Nat.zero_add, List.map_id_fun', id] at this
  simpa using this

/-! ## 3. Aliased slots are decremented once per slot -/

theorem count_rcDec (v w : Nat) (hv : v ≠ 0) :
    (rcDec w).count v = if w = v then 1 else 0 := by
  unfold rcDec
  by_cases hw : w = 0
  · subst hw
    simp [Ne.symm hv]
  · by_cases hwv : w = v
    · subst hwv; simp [hw]
    · simp [hw, hwv]

theorem count_flatMap_rcDec (v : Nat) (hv : v ≠ 0) (f : Nat → Nat) :
    ∀ l : List Nat, (l.flatMap (fun k => rcDec (f k))).count v = (l.filter (fun k => f k = v)).length
  | [] => by simp
  | k :: ks => by
    rw [List.flatMap_cons, List.count_append, count_rcDec v (f k) hv,
      count_flatMap_rcDec v hv f ks, List.filter_cons]
    by_cases h : f k = v <;> simp [h] <;> omega

theorem slot_drop_alias_count (m : Mem) (slots : List Nat) (v : Nat) (hv : v ≠ 0) :
    (runBody m (slotHelperBody slots)).count v =
      ((sortUnique slots).filter (fun k => m (8 * k) = v)).length := by
  rw [slotHelper_trace]
  exact count_flatMap_rcDec v hv (fun k => m (8 * k)) _

/-- Two distinct slots holding one object: both are decremented. -/
theorem slot_drop_alias_twice (m : Mem) (i j v : Nat) (hij : i < j) (hv : v ≠ 0)
    (hi : m (8 * i) = v) (hj : m (8 * j) = v) :
    (runBody m (slotHelperBody [i, j])).count v = 2 := by
  have hs : StrictSorted [i, j] := by simp [StrictSorted, hij]
  rw [slot_drop_alias_count m [i, j] v hv, sortUnique_of_sorted _ hs]
  simp [hi, hj]

/-! ## 4. The decimal-mask key names one slot set (`qbe_slots_canonical_key`) -/

def slotMask (l : List Nat) : Nat := l.foldl (fun acc k => acc ||| 2 ^ k) 0

theorem testBit_foldl_mask (i : Nat) :
    ∀ (l : List Nat) (acc : Nat),
      (l.foldl (fun acc k => acc ||| 2 ^ k) acc).testBit i = (acc.testBit i || decide (i ∈ l))
  | [], acc => by simp
  | k :: ks, acc => by
    rw [List.foldl_cons, testBit_foldl_mask i ks, Nat.testBit_or, Nat.testBit_two_pow]
    by_cases h : k = i
    · subst h; simp
    · have : i ≠ k := fun e => h e.symm
      simp [h, this]

theorem testBit_slotMask (l : List Nat) (i : Nat) : (slotMask l).testBit i = decide (i ∈ l) := by
  unfold slotMask
  rw [testBit_foldl_mask]
  simp

theorem strictSorted_ext :
    ∀ (a b : List Nat), StrictSorted a → StrictSorted b → (∀ x, x ∈ a ↔ x ∈ b) → a = b
  | [], [], _, _, _ => rfl
  | [], y :: _, _, _, h => absurd ((h y).mpr (by simp)) (by simp)
  | x :: _, [], _, _, h => absurd ((h x).mp (by simp)) (by simp)
  | x :: xs, y :: ys, ha, hb, h => by
    have ha' := List.pairwise_cons.mp ha
    have hb' := List.pairwise_cons.mp hb
    have hxy : x = y := by
      have hx : x ∈ y :: ys := (h x).mp (by simp)
      have hy : y ∈ x :: xs := (h y).mpr (by simp)
      rcases List.mem_cons.mp hx with hx | hx
      · exact hx
      rcases List.mem_cons.mp hy with hy | hy
      · exact hy.symm
      have h1 := hb'.1 x hx
      have h2 := ha'.1 y hy
      omega
    subst hxy
    congr 1
    apply strictSorted_ext xs ys ha'.2 hb'.2
    intro z
    constructor
    · intro hz
      have hz' := (h z).mp (by simp [hz])
      rcases List.mem_cons.mp hz' with e | e
      · subst e; exact absurd (ha'.1 _ hz) (Nat.lt_irrefl _)
      · exact e
    · intro hz
      have hz' := (h z).mpr (by simp [hz])
      rcases List.mem_cons.mp hz' with e | e
      · subst e; exact absurd (hb'.1 _ hz) (Nat.lt_irrefl _)
      · exact e

/-- Equal keys mean equal canonical slot lists, hence equal helper bodies. -/
theorem slot_key_injective (a b : List Nat) (ha : StrictSorted a) (hb : StrictSorted b)
    (hk : slotMask a = slotMask b) : a = b := by
  apply strictSorted_ext a b ha hb
  intro x
  have := congrArg (fun n => n.testBit x) hk
  simp only [testBit_slotMask] at this
  exact ⟨fun h => by simpa [h] using this, fun h => by simpa [h] using this.symm⟩

theorem slot_key_shared_body (a b : List Nat) (ha : StrictSorted a) (hb : StrictSorted b)
    (hk : slotMask a = slotMask b) (m : Mem) :
    runBody m (slotHelperBody a) = runBody m (slotHelperBody b) := by
  rw [slot_key_injective a b ha hb hk]

/-! ## 5. RC-free tagged enums: a null drop function -/

/-- `$pion_drop_enum_<E>`: read the tag at offset 0, then for each variant
    `vi < n` with RC slots, `if tag == vi` drop slots `8 + 8k` and return. -/
def taggedEnumDrop (rcSlots : Nat → List Nat) (m : Mem) : Nat → List Nat
  | 0 => []
  | n + 1 =>
    let earlier := taggedEnumDrop rcSlots m n
    if rcSlots n = [] then earlier
    else if m 0 = n then (rcSlots n).flatMap (fun k => rcDec (m (8 + 8 * k)))
    else earlier

/-- What the runtime's destroy step does with an object's `drop_fn` before
    freeing it: nothing for `NULL`, the drop body's trace otherwise. -/
def destroyEffect (dropFn : Option (Mem → List Nat)) (m : Mem) : List Nat :=
  match dropFn with
  | none => []
  | some f => f m

theorem taggedEnumDrop_nil (rcSlots : Nat → List Nat) (hz : ∀ v, rcSlots v = []) (m : Mem) :
    ∀ n, taggedEnumDrop rcSlots m n = []
  | 0 => rfl
  | n + 1 => by
    simp only [taggedEnumDrop, hz n, ↓reduceIte]
    exact taggedEnumDrop_nil rcSlots hz m n

theorem zero_rc_tagged_enum_null_drop_equiv (rcSlots : Nat → List Nat)
    (hz : ∀ v, rcSlots v = []) (n : Nat) (m : Mem) :
    destroyEffect (some (fun m => taggedEnumDrop rcSlots m n)) m = destroyEffect none m := by
  simp only [destroyEffect]
  exact taggedEnumDrop_nil rcSlots hz m n

/-- Negative control: a single RC variant holding a live object makes the
    per-type drop observable, so `drop_fn = NULL` would leak it. -/
theorem rc_tagged_enum_drop_needed (rcSlots : Nat → List Nat) (vi k n : Nat)
    (hvi : vi < n) (hk : rcSlots vi = [k]) :
    ∃ m : Mem, destroyEffect (some (fun m => taggedEnumDrop rcSlots m n)) m ≠ destroyEffect none m := by
  refine ⟨fun off => if off = 0 then vi else 1, ?_⟩
  simp only [destroyEffect]
  -- Only the variant `vi` matches the tag; later variants fall back to earlier results.
  have key : ∀ j, vi < j → taggedEnumDrop rcSlots (fun off => if off = 0 then vi else 1) j = [1] := by
    intro j hj
    induction j with
    | zero => omega
    | succ j ih =>
      by_cases hjv : j = vi
      · subst hjv
        simp [taggedEnumDrop, hk, rcDec]
      · have hlt : vi < j := by omega
        have hne : ¬ vi = j := fun e => hjv e.symm
        by_cases hr : rcSlots j = []
        · simp [taggedEnumDrop, hr, ih hlt]
        · simp [taggedEnumDrop, hr, hne, ih hlt]
  rw [key n hvi]
  simp

/-! ## 6. The emitted symbol suffix (`qbe_slot_drop_suffix`)

Characters are modelled by their code points. The suffix of a canonical slot
set `S` (strictly sorted, non-empty) registered at table index `idx` is
  * `max S ≤ 30`: the decimal digits of `slotMask S`;
  * `31 ≤ max S ≤ 127`: `x_` followed by `max S / 16 + 1` zero-padded 4-digit
    lowercase hex chunks, highest chunk first, chunk `i` holding bit `j` iff
    `16 i + j ∈ S`;
  * `max S > 127`: `w_` followed by the decimal digits of `idx`.
`suffix_injective`: two registered sets get the same symbol iff they are the
same set (the table gives distinct sets distinct indices). -/

/-- Most-significant-first decimal digits (`Int::to_string` on `n ≥ 0`). -/
def decDigits (n : Nat) : List Nat :=
  if n < 10 then [n] else decDigits (n / 10) ++ [n % 10]
termination_by n
decreasing_by omega

theorem decDigits_ne_nil (n : Nat) : decDigits n ≠ [] := by
  unfold decDigits
  split <;> simp

theorem decDigits_lt (n : Nat) : ∀ d ∈ decDigits n, d < 10 := by
  induction n using Nat.strongRecOn with
  | _ n ih =>
    unfold decDigits
    split
    · intro d hd; simp at hd; omega
    · intro d hd
      rcases List.mem_append.mp hd with h | h
      · exact ih (n / 10) (by omega) d h
      · simp at h; omega

theorem decDigits_inj : ∀ a b : Nat, decDigits a = decDigits b → a = b := by
  intro a
  induction a using Nat.strongRecOn with
  | _ a ih =>
    intro b h
    unfold decDigits at h
    by_cases ha : a < 10 <;> by_cases hb : b < 10 <;> simp only [ha, hb, ↓reduceIte] at h
    · simpa using h
    · have hl := congrArg List.length h
      have := decDigits_ne_nil (b / 10)
      cases hd : decDigits (b / 10) with
      | nil => exact absurd hd this
      | cons _ _ => simp [hd] at hl
    · have hl := congrArg List.length h
      have := decDigits_ne_nil (a / 10)
      cases hd : decDigits (a / 10) with
      | nil => exact absurd hd this
      | cons _ _ => simp [hd] at hl
    · have hlast := List.append_inj' h rfl
      have hq := ih (a / 10) (by omega) (b / 10) hlast.1
      have hr : a % 10 = b % 10 := by simpa using hlast.2
      omega

def digitChar (d : Nat) : Nat := 48 + d
def hexChar (h : Nat) : Nat := if h < 10 then 48 + h else 87 + h

def decKey (n : Nat) : List Nat := (decDigits n).map digitChar

theorem map_digitChar_inj : ∀ a b : List Nat, a.map digitChar = b.map digitChar → a = b
  | [], [], _ => rfl
  | [], _ :: _, h => by simp at h
  | _ :: _, [], h => by simp at h
  | x :: xs, y :: ys, h => by
    simp only [List.map_cons, List.cons.injEq, digitChar] at h
    rw [map_digitChar_inj xs ys h.2]
    congr 1
    omega

theorem decKey_inj (a b : Nat) (h : decKey a = decKey b) : a = b :=
  decDigits_inj a b (map_digitChar_inj _ _ h)

theorem decKey_digits (n : Nat) : ∀ c ∈ decKey n, 48 ≤ c ∧ c < 58 := by
  intro c hc
  simp only [decKey, List.mem_map] at hc
  obtain ⟨d, hd, rfl⟩ := hc
  have := decDigits_lt n d hd
  simp only [digitChar]; omega

/-- One 16-bit chunk as four lowercase hex digits. -/
def hex4 (v : Nat) : List Nat :=
  [hexChar (v / 4096 % 16), hexChar (v / 256 % 16), hexChar (v / 16 % 16), hexChar (v % 16)]

theorem hexChar_inj (a b : Nat) (ha : a < 16) (hb : b < 16) (h : hexChar a = hexChar b) : a = b := by
  unfold hexChar at h
  split at h <;> split at h <;> omega

theorem hex4_inj (a b : Nat) (ha : a < 65536) (hb : b < 65536) (h : hex4 a = hex4 b) : a = b := by
  simp only [hex4, List.cons.injEq, and_true] at h
  obtain ⟨h1, h2, h3, h4⟩ := h
  have e1 := hexChar_inj _ _ (by omega) (by omega) h1
  have e2 := hexChar_inj _ _ (by omega) (by omega) h2
  have e3 := hexChar_inj _ _ (by omega) (by omega) h3
  have e4 := hexChar_inj _ _ (by omega) (by omega) h4
  omega

theorem flatMap_hex4_inj (f g : Nat → Nat) (hf : ∀ i, f i < 65536) (hg : ∀ i, g i < 65536) :
    ∀ l : List Nat, l.flatMap (fun i => hex4 (f i)) = l.flatMap (fun i => hex4 (g i)) →
      ∀ i ∈ l, f i = g i
  | [], _ => by simp
  | k :: ks, h => by
    simp only [List.flatMap_cons] at h
    have hs := List.append_inj h (by simp [hex4])
    intro i hi
    rcases List.mem_cons.mp hi with e | e
    · subst e; exact hex4_inj _ _ (hf i) (hg i) hs.1
    · exact flatMap_hex4_inj f g hf hg ks hs.2 i e

/-- Low-bit positions of the slots in chunk `i`. -/
def chunkBits (S : List Nat) (i : Nat) : List Nat :=
  S.filterMap (fun x => if x / 16 = i then some (x % 16) else none)

def chunk (S : List Nat) (i : Nat) : Nat := slotMask (chunkBits S i)

theorem foldl_mask_lt (n : Nat) :
    ∀ (l : List Nat) (acc : Nat), acc < 2 ^ n → (∀ k ∈ l, k < n) →
      l.foldl (fun acc k => acc ||| 2 ^ k) acc < 2 ^ n
  | [], acc, h, _ => by simpa using h
  | k :: ks, acc, h, hk => by
    rw [List.foldl_cons]
    apply foldl_mask_lt n ks
    · exact Nat.or_lt_two_pow h (Nat.pow_lt_pow_right (by decide) (hk k (by simp)))
    · intro x hx; exact hk x (by simp [hx])

theorem chunk_lt (S : List Nat) (i : Nat) : chunk S i < 65536 := by
  have : chunk S i < 2 ^ 16 := by
    unfold chunk slotMask
    apply foldl_mask_lt 16 _ 0 (by decide)
    intro k hk
    simp only [chunkBits, List.mem_filterMap] at hk
    obtain ⟨x, _, hx⟩ := hk
    split at hx
    · simp at hx; omega
    · simp at hx
  simpa using this

theorem testBit_chunk (S : List Nat) (i j : Nat) (hj : j < 16) :
    (chunk S i).testBit j = decide (16 * i + j ∈ S) := by
  unfold chunk
  rw [testBit_slotMask]
  congr 1
  apply propext
  simp only [chunkBits, List.mem_filterMap]
  constructor
  · rintro ⟨x, hx, hxe⟩
    split at hxe
    · simp at hxe
      have : x = 16 * i + j := by omega
      subst this; exact hx
    · simp at hxe
  · intro h
    exact ⟨16 * i + j, h, by simp; omega⟩

/-- `x_` + `n` chunks, highest first. -/
def hexKey (S : List Nat) (n : Nat) : List Nat :=
  120 :: 95 :: ((List.range n).reverse.flatMap (fun i => hex4 (chunk S i)))

theorem flatMap_hex4_length (f : Nat → Nat) :
    ∀ l : List Nat, (l.flatMap (fun i => hex4 (f i))).length = 4 * l.length
  | [] => by simp
  | k :: ks => by
    rw [List.flatMap_cons, List.length_append, flatMap_hex4_length f ks]
    simp [hex4]; omega

theorem hexKey_length (S : List Nat) (n : Nat) : (hexKey S n).length = 2 + 4 * n := by
  unfold hexKey
  rw [List.length_cons, List.length_cons, flatMap_hex4_length]
  simp; omega

theorem hexKey_mem (a b : List Nat) (na nb : Nat) (h : hexKey a na = hexKey b nb) :
    ∀ x ∈ a, x < 16 * na → x ∈ b := by
  have hn : na = nb := by
    have := congrArg List.length h
    rw [hexKey_length, hexKey_length] at this
    omega
  subst hn
  simp only [hexKey, List.cons.injEq, true_and] at h
  have hc := flatMap_hex4_inj (chunk a) (chunk b) (chunk_lt a) (chunk_lt b) _ h
  intro x hx hxa
  have hi : x / 16 ∈ (List.range na).reverse := by simp; omega
  have e := hc _ hi
  have ta := testBit_chunk a (x / 16) (x % 16) (by omega)
  have tb := testBit_chunk b (x / 16) (x % 16) (by omega)
  have hx' : 16 * (x / 16) + x % 16 = x := by omega
  rw [hx'] at ta tb
  rw [e, tb] at ta
  simpa [hx] using ta

def wKey (idx : Nat) : List Nat := 119 :: 95 :: decKey idx

/-- Largest slot of a set (`sorted[sorted.length() - 1]`). -/
def maxSlot (S : List Nat) : Nat := S.foldr max 0

theorem le_maxSlot : ∀ (S : List Nat), ∀ x ∈ S, x ≤ maxSlot S
  | [], x, h => by simp at h
  | y :: ys, x, h => by
    have ih := le_maxSlot ys
    simp only [maxSlot, List.foldr_cons] at ih ⊢
    rcases List.mem_cons.mp h with e | e
    · subst e; omega
    · have := ih x e; omega

def suffix (S : List Nat) (idx : Nat) : List Nat :=
  if maxSlot S ≤ 30 then decKey (slotMask S)
  else if maxSlot S ≤ 127 then hexKey S (maxSlot S / 16 + 1)
  else wKey idx

/-- The three namespaces never share a symbol: decimal keys start with a
    digit, hex keys with `x`, wide keys with `w`. -/
theorem namespaces_disjoint (m : Nat) (S : List Nat) (n idx : Nat) :
    decKey m ≠ hexKey S n ∧ decKey m ≠ wKey idx ∧ hexKey S n ≠ wKey idx := by
  have hd : ∀ c ∈ decKey m, 48 ≤ c ∧ c < 58 := decKey_digits m
  refine ⟨fun h => ?_, fun h => ?_, fun h => ?_⟩
  · have := hd 120 (by rw [h]; simp [hexKey]); omega
  · have := hd 119 (by rw [h]; simp [wKey]); omega
  · simp [hexKey, wKey] at h

theorem dec_ne_hex (m : Nat) (S : List Nat) (n : Nat) : decKey m ≠ hexKey S n :=
  (namespaces_disjoint m S n 0).1

theorem dec_ne_w (m idx : Nat) : decKey m ≠ wKey idx :=
  (namespaces_disjoint m [] 0 idx).2.1

theorem hex_ne_w (S : List Nat) (n idx : Nat) : hexKey S n ≠ wKey idx :=
  (namespaces_disjoint 0 S n idx).2.2

theorem hexKey_eq_sets (a b : List Nat) (ha : StrictSorted a) (hb : StrictSorted b)
    (h : hexKey a (maxSlot a / 16 + 1) = hexKey b (maxSlot b / 16 + 1)) : a = b := by
  have ba : ∀ x ∈ a, x < 16 * (maxSlot a / 16 + 1) := fun x hx => by
    have := le_maxSlot a x hx; omega
  have bb : ∀ x ∈ b, x < 16 * (maxSlot b / 16 + 1) := fun x hx => by
    have := le_maxSlot b x hx; omega
  apply strictSorted_ext a b ha hb
  intro x
  exact ⟨fun hx => hexKey_mem a b _ _ h x hx (ba x hx),
    fun hx => hexKey_mem b a _ _ h.symm x hx (bb x hx)⟩

/-- Distinct registered sets get distinct symbols, equal sets the same one.
    `hidx` is the helper table's contract: one index per distinct set. -/
theorem suffix_injective (a b : List Nat) (ia ib : Nat) (ha : StrictSorted a) (hb : StrictSorted b)
    (hidx : ia = ib ↔ a = b) : suffix a ia = suffix b ib ↔ a = b := by
  constructor
  · intro h
    unfold suffix at h
    by_cases a1 : maxSlot a ≤ 30 <;> by_cases b1 : maxSlot b ≤ 30 <;>
      by_cases a2 : maxSlot a ≤ 127 <;> by_cases b2 : maxSlot b ≤ 127 <;>
      simp only [a1, b1, a2, b2, ↓reduceIte] at h
    all_goals first
      | omega
      | exact slot_key_injective a b ha hb (decKey_inj _ _ h)
      | exact hexKey_eq_sets a b ha hb h
      | exact hidx.mp (decKey_inj _ _ (List.cons.inj (List.cons.inj h).2).2)
      | exact (dec_ne_hex _ _ _ h).elim
      | exact (dec_ne_hex _ _ _ h.symm).elim
      | exact (dec_ne_w _ _ h).elim
      | exact (dec_ne_w _ _ h.symm).elim
      | exact (hex_ne_w _ _ _ h).elim
      | exact (hex_ne_w _ _ _ h.symm).elim
  · intro h
    subst h
    have := hidx.mpr rfl
    subst this
    rfl

/-- The registration table (`slot_drop_keys` / `slot_drop_specs`) holds each
    set once, so its index map satisfies `suffix_injective`'s contract. -/
theorem nodup_getElem_inj :
    ∀ (tbl : List (List Nat)), tbl.Nodup → ∀ (i j : Nat) (hi : i < tbl.length) (hj : j < tbl.length),
      tbl[i] = tbl[j] → i = j
  | [], _, _, _, hi, _, _ => by simp at hi
  | x :: xs, hnd, i, j, hi, hj, h => by
    have hnd' := List.nodup_cons.mp hnd
    cases i with
    | zero =>
      cases j with
      | zero => rfl
      | succ j =>
        simp only [List.getElem_cons_zero, List.getElem_cons_succ] at h
        exact absurd (by rw [h]; simp : x ∈ xs) hnd'.1
    | succ i =>
      cases j with
      | zero =>
        simp only [List.getElem_cons_zero, List.getElem_cons_succ] at h
        exact absurd (by rw [← h]; simp : x ∈ xs) hnd'.1
      | succ j =>
        simp only [List.getElem_cons_succ] at h
        have := nodup_getElem_inj xs hnd'.2 i j (by simp at hi; omega) (by simp at hj; omega) h
        omega

theorem table_index_contract (tbl : List (List Nat)) (hnd : tbl.Nodup) (i j : Nat)
    (hi : i < tbl.length) (hj : j < tbl.length) : i = j ↔ tbl[i] = tbl[j] := by
  constructor
  · intro h; subst h; rfl
  · intro h; exact nodup_getElem_inj tbl hnd i j hi hj h

end PionWaveAA3Drops
