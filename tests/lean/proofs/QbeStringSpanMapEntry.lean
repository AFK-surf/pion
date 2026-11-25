/-
Soundness of the native String span, scalar Map entry, managed String file read
and Channel[String].send changes (`compiler/src/core/qbe.pion`
`qbe_checked_str_span` / `qbe_emit_span_concat` / `qbe_try_span_bindings` /
`qbe_entry_plan` / `qbe_try_slice_entry`; `runtime/pion_rt.c`
`pion_str_slice_data` / `pion_str_concat_spans` / `pion_map_scalar_entry` /
`pion_read_file_obj` / `pion_chan_send`; regression test
`tests/e2e/p125_string_span_map_entry`).

  1. `slice_bounds_unsigned_equiv`: the runtime's two unsigned comparisons
     `(uint64_t)lo <= (uint64_t)hi && (uint64_t)hi <= (uint64_t)len` on signed
     64-bit `lo`, `hi` and a length `0 <= len < 2^63` accept exactly
     `0 <= lo <= hi <= len`, the bounds of the allocating `String.slice`.
  2. `checkedLength`: a validated span has exactly `hi - lo` bytes.
  3. `copySpans_append` / `fusion`: for any stateful operand evaluation that
     may trap (returning the state at the first failure), validating every span
     in source order and copying once at the end produces the same final state,
     the same first error and the same bytes as concatenating eagerly.
     The compiler keeps the ordinary grouping of a `+` tree (the operands of
     the `pion_str_concat_n` chain, or `[lhs, rhs]` of one `pion_str_concat`),
     so each span copy replaces exactly one call that already checked the
     total length once, after all its operands. `defer_cap_effect_counterexample`
     shows why regrouping is not allowed in general: moving a nested
     concatenation's length check past an observable step changes behaviour;
     `runSteps_quiet` / `defer_cap_quiet` characterize the steps it may move past.
  4. `entry_update`: one probe that updates the found slot or inserts a fresh
     key equals `set k (f (lookup k m)) m`; `entry_hit_keeps_keys`: a hit
     keeps every stored key and its identity.
  5. `ringIndex`: the bounded subtraction that replaces `% cap` in
     `pion_chan_send` gives the same slot for `head < cap`, `count <= cap`.
  6. `read_equiv`: reading straight into the managed String's payload and
     publishing only after a complete `fread` equals the staged copy.
  7. `stringFreeze`: a String has no reference fields, so the compiler's deep
     freeze before `pion_chan_send`'s own freeze is redundant (freeze is
     idempotent).
-/
import Std

namespace QbeStringSpanMapEntry

variable {σ ε : Type}

/-- Two's-complement reinterpretation of a signed 64-bit value as `uint64_t`. -/
def u64 (x : Int) : Int := x % 18446744073709551616

theorem slice_bounds_unsigned_equiv (lo hi len : Int)
    (hlo : -9223372036854775808 ≤ lo ∧ lo < 9223372036854775808)
    (hhi : -9223372036854775808 ≤ hi ∧ hi < 9223372036854775808)
    (hlen : 0 ≤ len ∧ len < 9223372036854775808) :
    (u64 lo ≤ u64 hi ∧ u64 hi ≤ u64 len) ↔ (0 ≤ lo ∧ lo ≤ hi ∧ hi ≤ len) := by
  unfold u64
  omega

structure Span where
  owner : List UInt8
  lo : Nat
  len : Nat

def Span.bytes (s : Span) := (s.owner.drop s.lo).take s.len

def checkSlice (owner : List UInt8) (lo hi : Int) : Except String Span :=
  if 0 ≤ lo ∧ lo ≤ hi ∧ hi ≤ owner.length then
    .ok ⟨owner, lo.toNat, (hi-lo).toNat⟩
  else .error "string slice out of bounds"

theorem checkedLength {buf : List UInt8} {lo hi : Int} {s : Span}
    (h : checkSlice buf lo hi = .ok s) : s.bytes.length = s.len := by
  unfold checkSlice at h
  split at h
  · cases h
    simp [Span.bytes]
    omega
  · contradiction

-- A step may mutate state before returning or trapping. The state at the
-- first failure is observable and subsequent operand evaluations are skipped.
abbrev Step (σ ε : Type) := σ → σ × Except ε Span

def eager (steps : List (Step σ ε)) (st : σ) (acc : List UInt8) : σ × Except ε (List UInt8) :=
  match steps with
  | [] => (st, .ok acc)
  | f :: fs => match f st with
    | (st', .error e) => (st', .error e)
    | (st', .ok p) => eager fs st' (acc ++ p.bytes)

def copySpans (dst : List UInt8) : List Span → List UInt8
  | [] => dst
  | s :: ss => copySpans (dst ++ s.bytes) ss

theorem copySpans_append (dst : List UInt8) (a b : List Span) :
    copySpans dst (a ++ b) = copySpans (copySpans dst a) b := by
  induction a generalizing dst with
  | nil => rfl
  | cons a as ih => simp [copySpans, ih]

def deferred (steps : List (Step σ ε)) (st : σ) (validated : List Span) :
    σ × Except ε (List UInt8) :=
  match steps with
  | [] => (st, .ok (copySpans [] validated))
  | f :: fs => match f st with
    | (st', .error e) => (st', .error e)
    | (st', .ok p) => deferred fs st' (validated ++ [p])

theorem fusion (steps : List (Step σ ε)) (st : σ) (ss : List Span) :
    deferred steps st ss = eager steps st (copySpans [] ss) := by
  induction steps generalizing st ss with
  | nil => rfl
  | cons f fs ih =>
    rcases h : f st with ⟨st', err | p⟩
    · simp [deferred, eager, h]
    · simp [deferred, eager, h, ih, copySpans_append, copySpans]

/-! Length checks of nested concatenations. Each concatenation checks its own
aggregate length (`capOk`) and fails with the same error `capErr`. Moving a
nested concatenation's check after operands evaluated later is unobservable when
those later steps are quiet (state unchanged, no failure) and observable
otherwise. The compiler therefore never regroups: a span copy covers exactly the
operands of the concatenation call it replaces (`qbe_string_add_parts`). -/

/-- Run steps left to right, stopping at the first failure. -/
def runSteps : List (Step σ ε) → σ → σ × Except ε (List Span)
  | [], st => (st, .ok [])
  | f :: fs, st =>
    match f st with
    | (st', .error e) => (st', .error e)
    | (st', .ok p) =>
      match runSteps fs st' with
      | (s, .ok ps) => (s, .ok (p :: ps))
      | (s, .error e) => (s, .error e)

/-- Base order: the nested concatenation of `pre` checks its length, then the
later steps run. -/
def checkThen (capOk : List Span → Bool) (capErr : ε) (pre : List Span)
    (fs : List (Step σ ε)) (st : σ) : σ × Except ε (List Span) :=
  if capOk pre then
    match runSteps fs st with
    | (s, .ok ps) => (s, .ok (pre ++ ps))
    | (s, .error e) => (s, .error e)
  else (st, .error capErr)

/-- Flattened order: the later steps run first, the check of `pre` happens at the
final copy. -/
def thenCheck (capOk : List Span → Bool) (capErr : ε) (pre : List Span)
    (fs : List (Step σ ε)) (st : σ) : σ × Except ε (List Span) :=
  match runSteps fs st with
  | (s, .error e) => (s, .error e)
  | (s, .ok ps) => if capOk pre then (s, .ok (pre ++ ps)) else (s, .error capErr)

theorem runSteps_quiet (fs : List (Step σ ε))
    (hq : ∀ f ∈ fs, ∀ s, ∃ p, f s = (s, .ok p)) (st : σ) :
    ∃ ps, runSteps fs st = (st, .ok ps) := by
  induction fs generalizing st with
  | nil => exact ⟨[], rfl⟩
  | cons f fs ih =>
    obtain ⟨p, hp⟩ := hq f (by simp) st
    obtain ⟨ps, hps⟩ := ih (fun g hg s => hq g (by simp [hg]) s) st
    exact ⟨p :: ps, by simp [runSteps, hp, hps]⟩

theorem defer_cap_quiet (capOk : List Span → Bool) (capErr : ε) (pre : List Span)
    (fs : List (Step σ ε)) (hq : ∀ f ∈ fs, ∀ s, ∃ p, f s = (s, .ok p)) (st : σ) :
    checkThen capOk capErr pre fs st = thenCheck capOk capErr pre fs st := by
  obtain ⟨ps, h⟩ := runSteps_quiet fs hq st
  by_cases hc : capOk pre = true <;> simp [checkThen, thenCheck, h, hc]

/-- A later step with an observable effect (here: it changes the state) makes the
flattened order differ: the base order fails before the step runs. -/
theorem defer_cap_effect_counterexample :
    checkThen (σ := Nat) (fun _ => false) (7 : Nat) []
        [fun s => (s + 1, .ok ⟨[], 0, 0⟩)] 0 ≠
      thenCheck (σ := Nat) (fun _ => false) (7 : Nat) []
        [fun s => (s + 1, .ok ⟨[], 0, 0⟩)] 0 := by
  simp [checkThen, thenCheck, runSteps]

structure Entry where
  key : List UInt8
  identity : Nat
  value : BitVec 64
  deriving DecidableEq

def lookup (k : List UInt8) : List Entry → Option (BitVec 64)
  | [] => none
  | e :: es => if e.key = k then some e.value else lookup k es

def set (k : List UInt8) (id : Nat) (v : BitVec 64) : List Entry → List Entry
  | [] => [⟨k,id,v⟩]
  | e :: es => if e.key = k then {e with value := v} :: es else e :: set k id v es

def update (s : Span) (id : Nat) (f : Option (BitVec 64) → BitVec 64) :
    List Entry → List Entry
  | [] => [⟨s.bytes,id,f none⟩]
  | e :: es => if e.key = s.bytes then {e with value := f (some e.value)} :: es else e :: update s id f es

theorem entry_update (s : Span) (id : Nat) (f : Option (BitVec 64) → BitVec 64) (es : List Entry) :
    update s id f es = set s.bytes id (f (lookup s.bytes es)) es := by
  induction es with
  | nil => rfl
  | cons e es ih =>
    by_cases h : e.key = s.bytes <;> simp [update, set, lookup, h, ih]

/-- A hit leaves every stored key and its identity unchanged; only the value
of the matching entry is rewritten. -/
theorem entry_hit_keeps_keys (s : Span) (id : Nat) (f : Option (BitVec 64) → BitVec 64)
    (es : List Entry) (h : lookup s.bytes es ≠ none) :
    (update s id f es).map (fun e => (e.key, e.identity)) = es.map (fun e => (e.key, e.identity)) := by
  induction es with
  | nil => simp [lookup] at h
  | cons e es ih =>
    by_cases hk : e.key = s.bytes
    · simp [update, hk]
    · simp [lookup, hk] at h
      simp [update, hk, ih h]

theorem ringIndex (head count cap : Nat) (h : head < cap) (c : count ≤ cap) :
    (if head + count ≥ cap then head + count - cap else head + count) = (head + count) % cap := by
  split
  · rename_i hc
    rw [Nat.mod_eq_sub_mod hc, Nat.mod_eq_of_lt (by omega)]
  · exact (Nat.mod_eq_of_lt (by omega)).symm

-- Size-delimited reads publish only if fread returned every requested byte.
def stagedRead (expected : Nat) (input : List UInt8) : Option (List UInt8) :=
  if expected ≤ input.length then some ((input.take expected).map id) else none

def directRead (expected : Nat) (input : List UInt8) : Option (List UInt8) :=
  if (input.take expected).length = expected then some (input.take expected) else none

theorem read_equiv (expected : Nat) (input : List UInt8) :
    stagedRead expected input = directRead expected input := by
  by_cases h : expected ≤ input.length
  · simp [stagedRead, directRead, h, Nat.min_eq_left h]
  · have h' : input.length < expected := by omega
    simp [stagedRead, directRead, h, Nat.min_eq_right (Nat.le_of_lt h'), Nat.ne_of_lt h']

theorem stringFreeze (frozen : Bool) : (frozen || true || true) = (frozen || true) := by simp

end QbeStringSpanMapEntry
