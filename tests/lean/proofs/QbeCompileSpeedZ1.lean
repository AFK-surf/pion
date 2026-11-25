/-
Soundness models for the Opt-Track Z1 compile-speed rewrites (regression test
`tests/e2e/p129_compile_speed_z1`). Each namespace models one source
transformation; the Pion-side mapping is checked at the call sites, and the
compiler itself is cross-checked by byte-identical artefacts and the
self-hosting fixed point.

  1. `BinaryFrames` — `check_binary_chain` (`compiler/src/core/types.pion`) and
     `qbe_emit_binary_chain` (`compiler/src/core/qbe.pion`) keep one stack of
     `CheckBinaryFrame` / `QbeBinaryFrame` records instead of 6 / 12 parallel
     arrays pushed and popped in lock step. `check_trace` / `emit_trace`: the
     column projection of the frame stack follows the same trace for every
     push / write-top / pop sequence; `read_eq`: top-of-stack reads agree;
     `forget_unused`: dropping the never-read `f_slot` column commutes with
     every transition.
  2. `BinaryGuard` — `qbe_emit_binary_chain` only allocates and fills a
     `QbeArgGuards` for the left operand when it is owned, the block is live
     and the right operand may leave early (`is_mut_slot = false` at this call
     site); otherwise it shares a read-only empty guard set. `lazy_guard`: the
     held slots are the same as with the old unconditional `qbe_guard_val`;
     `same_emission`: the hold / right operand / release effect sequence is
     unchanged.
  3. `BodyScan` — `irc_process_ssa` (`compiler/src/core/inline_rc.pion`)
     replaces the byte-by-byte three-flag scanner `irc_scan_body_flags` by a
     substring search for `$pion_rc_` and, in release mode without RC
     markers, `irc_body_has_call` (`index_of("call")` skip plus a
     non-identifier suffix test). `scan_eq`: every run of the old scanner
     computes the consumer's decision (the `_hdr` bit had no reader);
     `indexed_eq`: skipping to the first `call` literal keeps the predicate.
  4. `BodyLines` — `irc_body_lines` splits an ASCII body with `split("\n")`,
     dropping the trailing empty field, instead of `irc_split_lines_range`
     (non-ASCII bodies keep the old path). `partition_eq`: both produce the
     same lines, including consecutive and trailing LFs.
  5. `DriverTarget` — `drv_build_targets` and the `build` / `run` commands
     (`compiler/src/cli/main.pion`) reuse the target the command already
     picked instead of re-running host detection. `same_target` /
     `repeated`: picking again from an already picked target is idempotent
     (given stable options, environment and host probe within one command).
-/

namespace QbeCompileSpeedZ1

namespace BinaryFrames

universe u v
variable {Field : Type u} {Val : Field → Type v}
abbrev Row (Val : Field → Type v) := (f : Field) → Val f
abbrev Cols (Val : Field → Type v) := (f : Field) → List (Val f)

/-- Top at the head models last-index access in the Pion growable arrays. -/
def project (rs : List (Row Val)) : Cols Val := fun f => rs.map (· f)

def modifyHead {α : Type v} (g : α → α) : List α → List α
  | [] => []
  | a :: as => g a :: as

inductive Action (Val : Field → Type v) where
  | push (r : Row Val)
  | writeTop (g : (f : Field) → Val f → Val f)
  | pop

def stepRows (rs : List (Row Val)) : Action Val → List (Row Val)
  | .push r => r :: rs
  | .writeTop g => modifyHead (fun r f => g f (r f)) rs
  | .pop => rs.tail

def stepCols (cs : Cols Val) : Action Val → Cols Val
  | .push r => fun f => r f :: cs f
  | .writeTop g => fun f => modifyHead (g f) (cs f)
  | .pop => fun f => (cs f).tail

theorem step_eq (rs : List (Row Val)) (op : Action Val) :
    stepCols (project rs) op = project (stepRows rs op) := by
  cases op <;> cases rs <;> rfl

theorem trace_eq (ops : List (Action Val)) (rs : List (Row Val)) :
    ops.foldl stepCols (project rs) = project (ops.foldl stepRows rs) := by
  induction ops generalizing rs with
  | nil => rfl
  | cons op rest ih =>
    simp only [List.foldl_cons, step_eq]
    exact ih _

theorem read_eq (rs : List (Row Val)) (f : Field) :
    (project rs f).head? = rs.head?.map (· f) := by cases rs <;> rfl

/-- Fields of the two actual machines. Span, child ASTs, temporary labels and
    mutable guards retain their original values, including reference identity. -/
inductive CheckField | state | op | lhs | rhs | span | operandTy
inductive EmitField | state | op | lhs | rhs | span | left | borrow | borrowField
  | shortLabel | endLabel | guards

theorem check_trace {V : CheckField → Type v} (ops : List (Action V)) :
    ops.foldl stepCols (project []) = project (ops.foldl stepRows []) := trace_eq ops []

theorem emit_trace {V : EmitField → Type v} (ops : List (Action V)) :
    ops.foldl stepCols (project []) = project (ops.foldl stepRows []) := trace_eq ops []

/-- The old f_slot column had no reads and only push/pop writes. Projecting
    out any independently updated unused column commutes with every transition. -/
theorem forget_unused {V : EmitField → Type v} {Slot : Type v}
    (update : List Slot → List Slot) (op : Action V) (rs : List (Row V)) (ss : List Slot) :
    (stepCols (project rs) op, update ss).1 = project (stepRows rs op) := step_eq rs op

end BinaryFrames

namespace BinaryGuard
/-- The binary-expression caller always supplies is_mut_slot=false. For that
    branch qbe_guard_val appends exactly one held slot when all tests pass. -/
inductive Effect | hold | storeZero | markZero deriving DecidableEq

def oldSlots (exits terminated needsRc borrowed : Bool) : List Unit :=
  if !exits || terminated then []
  else if !needsRc then []
  else if !borrowed then [()] else []

def newSlots (exits terminated needsRc borrowed : Bool) : List Unit :=
  if !borrowed && !terminated && exits then
    oldSlots true terminated needsRc borrowed
  else []

def release (slots : List Unit) (rhsTerm : Bool) : List Effect :=
  slots.flatMap fun _ => if rhsTerm then [.markZero] else [.storeZero, .markZero]

def observable (slots : List Unit) (rhs : List Effect) (rhsTerm : Bool) : List Effect :=
  slots.map (fun _ => .hold) ++ rhs ++ release slots rhsTerm

theorem lazy_guard (e t n b : Bool) : newSlots e t n b = oldSlots e t n b := by
  cases e <;> cases t <;> cases n <;> cases b <;> rfl

theorem same_emission (e t n b rhsTerm : Bool) (rhs : List Effect) :
    observable (newSlots e t n b) rhs rhsTerm = observable (oldSlots e t n b) rhs rhsTerm := by
  rw [lazy_guard]

end BinaryGuard

namespace BodyScan

abbrev Bytes := List Nat
def rcAt : Bytes → Bool
  | 36::112::105::111::110::95::114::99::95::_ => true
  | _ => false
def lit : Bytes → Bool
  | 99::97::108::108::_ => true
  | _ => false
def ident (x : Nat) : Bool :=
  (97 ≤ x && x ≤ 122) || (65 ≤ x && x ≤ 90) || (48 ≤ x && x ≤ 57) ||
    x == 95 || x == 46 || x == 36
def callAt : Bytes → Bool
  | 99::97::108::108::x::_ => !ident x
  | _ => false

def anyPos (p : Bytes → Bool) : Bytes → Bool
  | [] => false
  | x::xs => p (x::xs) || anyPos p xs

-- State relevant to the consumer: RC is sufficient in either mode. A
-- qualified call alone also causes processing in release. Header is unused.
def decision (release rc call : Bool) (xs : Bytes) : Bool :=
  rc || anyPos rcAt xs || (release && (call || anyPos callAt xs))

-- Every execution of the old three-bit scanner projects to this relation.
-- Allowing another header skip after the first one is harmless and gives a
-- stronger invariant. The separator following 'call' is left unread.
inductive Scan : Bytes → Bool → Bool → Bool → Bool → Prop
  | done (m r c) : Scan [] m r c (r || (m && c))
  | byte (x xs m r c z) (skipRC : rcAt (x::xs) = false ∨ r = true)
      (skipCall : callAt (x::xs) = false ∨ c = true)
      (tail : Scan xs m r c z) : Scan (x::xs) m r c z
  | rc (xs m r c z) (tail : Scan xs m true c z) :
      Scan (36::112::105::111::110::95::114::99::95::xs) m r c z
  | header (xs m r c z) (tail : Scan xs m r c z) : Scan (95::104::100::114::xs) m r c z
  | call (x xs m r c z) (sep : ident x = false) (tail : Scan (x::xs) m r true z) :
      Scan (99::97::108::108::x::xs) m r c z
  | allFound (xs m) : Scan xs m true true true

theorem scan_eq {xs m r c z} (h : Scan xs m r c z) : z = decision m r c xs := by
  induction h with
  | done => simp [decision,anyPos]
  | byte x xs m r c z hr hc _ ih =>
    rw [ih]
    rcases hr with hr|hr <;> rcases hc with hc|hc <;>
      cases m <;> simp [decision,anyPos,hr,hc]
  | rc _ _ _ _ _ _ ih => simpa [decision,anyPos,rcAt] using ih
  | header _ _ _ _ _ _ ih => simpa [decision,anyPos,rcAt,callAt] using ih
  | call x xs m r c z hsep _ ih =>
    cases m <;> simpa [decision,anyPos,rcAt,callAt,hsep] using ih
  | allFound => simp [decision]

-- The runtime index search discards all suffixes before the first 'call'.
-- A strict suffix ending in the four letters alone never qualifies.
def suffixes : Bytes → List Bytes
  | [] => []
  | x::xs => (x::xs)::suffixes xs

theorem any_suffixes (p : Bytes → Bool) (xs : Bytes) :
    (suffixes xs).any p = anyPos p xs := by
  induction xs with
  | nil => rfl
  | cons x xs ih => simp [suffixes,anyPos,ih]

theorem literal_required (xs : Bytes) (h : lit xs = false) : callAt xs = false := by
  unfold callAt
  split
  next => simp [lit] at h
  next => rfl

theorem indexed (ss : List Bytes) :
    (ss.dropWhile (fun s => !lit s)).any callAt = ss.any callAt := by
  induction ss with
  | nil => rfl
  | cons s ss ih =>
    cases h : lit s <;> simp [h, List.dropWhile, ih, literal_required] <;>
      simp [literal_required s h]

theorem indexed_eq (xs : Bytes) :
    ((suffixes xs).dropWhile (fun s => !lit s)).any callAt = anyPos callAt xs := by
  rw [indexed,any_suffixes]

end BodyScan

namespace BodyLines

abbrev Bytes := List Nat
-- Both routines have the identical non-ASCII fallback. On ASCII input a
-- slice contains exactly its code units; represent the current slice reversed.
def old (rev : Bytes) : Bytes → List Bytes
  | [] => if rev.isEmpty then [] else [rev.reverse]
  | x::xs => if x == 10 then rev.reverse :: old [] xs else old (x::rev) xs

def splitLF (rev : Bytes) : Bytes → List Bytes
  | [] => [rev.reverse]
  | x::xs => if x == 10 then rev.reverse :: splitLF [] xs else splitLF (x::rev) xs

-- A delimiter or empty body leaves an empty last field. In all other cases
-- the old scanner emits the last field without requiring a delimiter.
def trailing (empty : Bool) : Bytes → Bool
  | [] => empty
  | x::xs => trailing (x == 10) xs

theorem split_inv (xs rev : Bytes) :
    splitLF rev xs = old rev xs ++ (if trailing rev.isEmpty xs then [[]] else []) := by
  induction xs generalizing rev with
  | nil => cases rev <;> simp [splitLF, old, trailing]
  | cons x xs ih =>
    by_cases h : x == 10
    · simpa [splitLF,old,trailing,h] using congrArg (List.cons rev.reverse) (ih [])
    · simpa [splitLF,old,trailing,h] using ih (x::rev)

def fast (xs : Bytes) :=
  if trailing true xs then (splitLF [] xs).dropLast else splitLF [] xs

theorem partition_eq (xs : Bytes) : fast xs = old [] xs := by
  unfold fast
  rw [split_inv]
  cases h : trailing true xs <;> simp [h]

end BodyLines

namespace DriverTarget
def pick (over env host : String) : String :=
  if over != "" then over else if env != "" then env else host

def forwarded (over env host : String) := pick (pick over env host) env host

theorem same_target (over env host : String) : forwarded over env host = pick over env host := by
  unfold forwarded pick
  by_cases ho : over = "" <;> by_cases he : env = "" <;> simp [ho, he]

def nested (env host : String) : Nat → String → String
  | 0, s => s
  | n + 1, s => nested env host n (pick s env host)

theorem repeated (n : Nat) (over env host : String) :
    nested env host n (pick over env host) = pick over env host := by
  induction n with
  | zero => rfl
  | succ k ih =>
    change nested env host k (pick (pick over env host) env host) = pick over env host
    rw [show pick (pick over env host) env host = pick over env host from same_target ..]
    exact ih

end DriverTarget

end QbeCompileSpeedZ1
