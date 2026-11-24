/-
Formally verified equivalence theorems for QBE loop array & byte-scan
optimizations in `compiler/src/core/qbe.pion`:
  1. `ReadPair`: hoisting loop-invariant array/view headers and merging
     bounds checks for consecutive scalar reads at the same `Int` index
     (`qbe_read_pair` / `qbe_pair_body`), preserving exact first-failing
     panic diagnostics and allowing in-place payload writes and disjoint
     resizes (fresh local arrays or nested `Array[Array[_]]`).
  2. `ByteScan`: lowering counted immutable-string single-byte search loops
     (`while i < n && s.code_unit_at(i) != K { i = i + 1 }`) to bounded
     `memchr` on validated windows `0 <= i < n <= s.len`, with exact scalar
     fallback on invalid ranges and no `Int32` increment overflow.

Pure kernel checks (compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/
import Std

namespace PionQbeLoopArrayOpts

namespace ReadPair

abbrev Key := Nat

structure Header where
  data : Nat
  len : UInt64
  deriving DecidableEq

structure Heap where
  header : Key → Header
  word : Nat → UInt64 → UInt32

abbrev Result := Except (Int32 × UInt64) (UInt32 × UInt32)

-- The SSA uses sign extension before its unsigned 64-bit comparison.
def offset (i : Int32) : UInt64 := i.toInt64.toUInt64

def scalar (h : Heap) (a b : Key) (i : Int32) : Result :=
  let j := offset i
  let x := h.header a
  let y := h.header b
  if j < x.len then
    if j < y.len then .ok (h.word x.data j, h.word y.data j)
    else .error (i, y.len)
  else .error (i, x.len)

def cached (h : Heap) (x y : Header) (i : Int32) : Result :=
  let j := offset i
  if j < (if x.len < y.len then x.len else y.len) then .ok (h.word x.data j, h.word y.data j)
  else .error (i, if j < x.len then y.len else x.len)

theorem step (h : Heap) (a b : Key) (i : Int32) :
    cached h (h.header a) (h.header b) i = scalar h a b i := by
  unfold cached scalar
  grind

-- Events between reads may replace any payload word, even through an alias.
-- Only the two headers need preservation. 'other' can resize/reallocate.
inductive Event where
  | payload (f : Nat → UInt64 → UInt32)
  | resize (other : Key) (newHeader : Header)

def apply (h : Heap) : Event → Heap
  | .payload f => {h with word := f}
  | .resize k v => {h with header := fun j => if j = k then v else h.header j}

def Allowed (a b : Key) : Event → Prop
  | .payload _ => True
  | .resize k _ => a ≠ k ∧ b ≠ k

-- Typed heap objects have a unique layout. Use allocation ordinals as
-- identities; an allocation within the loop is younger than all live inputs.
inductive Layout where
  | intArray | byteView | nestedArray
  deriving DecidableEq

inductive Separate (shape : Key → Layout) (entry dst : Key) : Prop where
  | fresh (later : entry < dst)
  | nested (layout : shape dst = .nestedArray)

theorem resize_allowed {shape : Key → Layout} {entry a b dst : Key}
    (liveA : a ≤ entry) (liveB : b ≤ entry)
    (flatA : shape a ≠ .nestedArray) (flatB : shape b ≠ .nestedArray)
    (receiver : Separate shape entry dst) (newHeader : Header) :
    Allowed a b (.resize dst newHeader) := by
  change a ≠ dst ∧ b ≠ dst
  cases receiver with
  | fresh later =>
    exact ⟨Nat.ne_of_lt (Nat.lt_of_le_of_lt liveA later),
           Nat.ne_of_lt (Nat.lt_of_le_of_lt liveB later)⟩
  | nested layout => grind

theorem preserve (h : Heap) {a b : Key} {e : Event} (ok : Allowed a b e) :
    (apply h e).header a = h.header a ∧ (apply h e).header b = h.header b := by
  cases e with
  | payload => exact ⟨rfl, rfl⟩
  | resize k v =>
    obtain ⟨ha, hb⟩ := ok
    simp [apply, ha, hb]

-- Prefix traces include the first failure and stop there. [] models a zero-trip
-- loop. The next index need not be monotone (for example a VM jump).
def run (read : Heap → Int32 → Result) (h : Heap) : List (Int32 × Event) → List Result
  | [] => []
  | (i, e) :: more =>
    match read h i with
    | .error err => [.error err]
    | .ok xy => .ok xy :: run read (apply h e) more

theorem trace (h : Heap) (a b : Key) (x y : Header) (xs : List (Int32 × Event))
    (hx : x = h.header a) (hy : y = h.header b)
    (ok : ∀ ie ∈ xs, Allowed a b ie.2) :
    run (fun s => cached s x y) h xs = run (fun s => scalar s a b) h xs := by
  induction xs generalizing h with
  | nil => rfl
  | cons ie rest ih =>
    obtain ⟨i, e⟩ := ie
    have keep := preserve h (ok (i, e) (by simp))
    have same : cached h x y i = scalar h a b i := by rw [hx, hy, step]
    simp only [run, same]
    split
    · rfl
    · rw [ih (apply h e) (hx.trans keep.1.symm) (hy.trans keep.2.symm)]
      intro j hj
      exact ok j (by simp [hj])

end ReadPair

namespace ByteScan

-- Scalar loop, including the first illegal access. n is the signed end
-- minus the current cursor after the signed empty-range test.
def scalar (key : UInt8) (len : Nat) : List UInt8 → Nat → Nat → Except Nat Nat
  | _, i, 0 => .ok i
  | [], i, _ + 1 => .error i
  | x :: xs, i, n + 1 =>
    if x = key then .ok i else scalar key len xs (i + 1) n

-- The C memchr contract: index of the first matching byte in the window,
-- or none. Pointer subtraction maps that offset back to the string cursor.
def memchr (key : UInt8) : List UInt8 → Option Nat
  | [] => none
  | x :: xs => if x = key then some 0 else (memchr key xs).map Nat.succ

def cursor (i n : Nat) : Option Nat → Nat
  | none => i + n
  | some off => i + off

theorem bounded (key : UInt8) (len : Nat) (xs : List UInt8) (i n : Nat)
    (fits : n ≤ xs.length) :
    scalar key len xs i n = .ok (cursor i n (memchr key (xs.take n))) := by
  induction n generalizing i xs with
  | zero => simp [scalar, memchr, cursor]
  | succ n ih =>
    cases xs with
    | nil => simp at fits
    | cons x xs =>
      simp only [List.length_cons, Nat.succ_le_succ_iff] at fits
      by_cases h : x = key
      · simp [scalar, List.take, memchr, h, cursor]
      · simp only [scalar, ite_eq_right h, List.take_succ_cons, memchr]
        rw [ih xs (i + 1) fits]
        cases memchr key (xs.take n) <;> simp [cursor, Nat.add_comm, Nat.add_left_comm]

def original (s : List UInt8) (k : UInt8) (i stop : Int) : Except Int Int :=
  if i ≥ stop then .ok i
  else if i < 0 then .error i
  else match scalar k s.length (s.drop i.toNat) i.toNat (stop - i).toNat with
    | .ok r => .ok r
    | .error r => .error r

def lowered (s : List UInt8) (k : UInt8) (i stop : Int) : Except Int Int :=
  if i ≥ stop then .ok i
  else if 0 ≤ i ∧ stop ≤ (s.length : Int) then
    let n := (stop - i).toNat
    .ok (cursor i.toNat n (memchr k ((s.drop i.toNat).take n)))
  else original s k i stop

theorem equivalent (s : List UInt8) (k : UInt8) (i stop : Int) :
    lowered s k i stop = original s k i stop := by
  by_cases empty : i ≥ stop
  · simp [lowered, original, empty]
  by_cases safe : 0 ≤ i ∧ stop ≤ (s.length : Int)
  · have fits : (stop - i).toNat ≤ (s.drop i.toNat).length := by
      simp only [List.length_drop]
      omega
    simp [lowered, original, empty, safe, Int.not_lt.mpr safe.1, bounded _ _ _ _ _ fits]
  · simp [lowered, empty, safe]

theorem no_increment_overflow (i stop : Int) (step : i < stop) (repr : stop ≤ 2147483647) :
    i + 1 ≤ 2147483647 := by omega

end ByteScan

end PionQbeLoopArrayOpts
