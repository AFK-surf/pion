/-
Soundness models for three QBE code-generation rules in
`compiler/src/core/qbe.pion` (regression tests in
`compiler/src/core/backend_test.pion` ("x1 ...") and
`tests/e2e/p126_ecosystem_unbox_fixed_len`).

  1. `VariantReturn` — an immediately consumed `Result` / `Option` returned by
     an inlined (also cross-file) callee is delivered through tag / payload
     slots instead of a heap envelope (`qbe_inline_body_into_opt_res_slots`).
     `release_after_acquire` / `slot_roundtrip`: the private single-owner
     envelope's retain / release of the payload cancel and its tag / payload
     round-trip through the slots. `all_exits`: for every body shape (tail,
     early `return`, effects on aliased state, data-dependent branches,
     aborts) the boxed and slot forms hand the handler the same variant and
     state. `call_equivalence`: argument evaluation that leaves the caller
     early (`?` in an argument) sees only the already evaluated prefix in both
     forms. `lexical_boundary`: with the lookup floor at the callee's first
     scope (`g.lookup_scope_floor = inl_scope_base`, also for plain inlined
     calls in `qbe_try_inline_fn_call`) caller-local bindings never capture a
     name of the callee body.
  2. `TupleProjection` — `let (a, b, ...) = f(...)` of a short (2–5 field)
     all-primitive tuple returned by an inlined callee whose body is `let`s
     followed by a tuple literal: the fields are written in source order into
     a private fixed-size stack buffer (`alloc8`) instead of a
     `pion_alloc`ed box. `simulation` relates the buffer evaluation to the
     list evaluation; `fields_preserved` / `arity`: reading the buffer back
     yields exactly the evaluated fields; `destructure`: the heap and stack
     paths give the same bound fields and state, including abrupt exits.
  3. `FixedLiteral` — an immutable local alias `let xs = T` of a package
     `FixedArray` / `ImmArray` literal global `T` (not shadowed by a local)
     carries the literal length as `counted_len`, so its bounds checks use the
     immediate. `alias_write` / `shadow` / `run_prefix`: element writes
     through any alias, rebinding other slots and arbitrary effects keep the
     length fact; `hoist`: replacing the header length load by the immediate
     yields the same continuation result.

The correspondence between these models and the matched Pion AST / emitted QBE
is covered by the unit and end-to-end tests above; the models do not cover the
whole front end, QBE or the register allocator.
-/
import Std

namespace PionQbeEcosystemUnboxFixedLen

/-! ## 1. Scalar `Result` / `Option` slots -/


namespace VariantReturn

abbrev Address := Nat
abbrev Counts := Address → Nat
inductive Value where
  | scalar (bits : Nat)
  | ref (address : Address)
  | absent
  deriving DecidableEq, Repr

inductive Tag where | ok | err | some | none deriving DecidableEq, Repr
structure Variant where
  tag : Tag
  payload : Value

structure State where
  counts : Counts
  trace : List Nat
  memory : Address → Value

def bump (v : Value) (s : State) : State :=
  match v with
  | .ref a => {s with counts := fun b => if a = b then s.counts b + 1 else s.counts b}
  | _ => s

def drop (v : Value) (s : State) : State :=
  match v with
  | .ref a => {s with counts := fun b => if a = b then s.counts b - 1 else s.counts b}
  | _ => s

theorem release_after_acquire (v : Value) (s : State) : drop v (bump v s) = s := by
  cases v with
  | ref a =>
    cases s
    simp only [drop, bump, State.mk.injEq, and_true]
    funext b
    by_cases h : a = b <;> simp [h]
  | scalar => rfl
  | absent => rfl

-- A private, single-owner envelope has a distinct address space from program
-- values. The handler only receives the active tag and its payload.
structure Box where
  contents : Variant
structure Slots where
  success : Bool
  optional : Bool
  payload : Value

def pack (v : Variant) : Slots :=
  ⟨match v.tag with | .ok | .some => true | _ => false,
   match v.tag with | .some | .none => true | _ => false, v.payload⟩
def unpack (s : Slots) : Variant :=
  ⟨if s.optional then (if s.success then .some else .none)
   else (if s.success then .ok else .err), s.payload⟩
theorem slot_roundtrip (v : Variant) : unpack (pack v) = v := by
  rcases v with ⟨tag,p⟩
  cases tag <;> rfl

abbrev Handler (α : Type) := Variant → State → α
def consumeBox {α : Type} (b : Box) (s : State) (k : Handler α) : α :=
  k b.contents (drop b.contents.payload (bump b.contents.payload s))
def consumeSlots {α : Type} (b : Slots) (s : State) (k : Handler α) : α :=
  k (unpack b) s

-- 'effect' can change aliased storage, record IO, and select subsequent code
-- from the resulting state. Both forms stop immediately on an abrupt exit.
inductive Body where
  | tail (v : Variant)
  | early (v : Variant)
  | effect (step : State → State) (next : Body)
  | branch (test : State → Bool) (yes no : Body)
  | abort (code : Nat)
def boxed {α : Type} (b : Body) (s : State) (k : Handler α) (panic : Nat → State → α) : α :=
  match b with
  | .tail v | .early v => consumeBox ⟨v⟩ s k
  | .abort n => panic n s
  | .effect f t => boxed t (f s) k panic
  | .branch p y n => if p s then boxed y s k panic else boxed n s k panic
def scalar {α : Type} (b : Body) (s : State) (k : Handler α) (panic : Nat → State → α) : α :=
  match b with
  | .tail v | .early v => consumeSlots (pack v) s k
  | .abort n => panic n s
  | .effect f t => scalar t (f s) k panic
  | .branch p y n => if p s then scalar y s k panic else scalar n s k panic

theorem all_exits {α : Type} (b : Body) (s : State) (k : Handler α) (panic : Nat → State → α) :
    boxed b s k panic = scalar b s k panic := by
  induction b generalizing s with
  | tail v => simp [boxed, scalar, consumeBox, consumeSlots, release_after_acquire, slot_roundtrip]
  | early v => simp [boxed, scalar, consumeBox, consumeSlots, release_after_acquire, slot_roundtrip]
  | abort => rfl
  | effect f t ih => exact ih (f s)
  | branch p y n iy ino => simp only [boxed, scalar]; split <;> simp_all

-- Argument expressions can return from the caller before the callee starts.
-- The abrupt continuation receives only the already-evaluated argument prefix.
abbrev Argument := State → (Except Variant Value × State)
def arguments {α : Type} (xs : List Argument) (seen : List Value) (s : State)
    (call : List Value → State → α) (early : List Value → Variant → State → α) : α :=
  match xs with
  | [] => call seen.reverse s
  | x :: rest => match x s with
    | (.ok v, s') => arguments rest (v :: seen) s' call early
    | (.error e, s') => early seen.reverse e s'

theorem call_equivalence {α : Type} (xs : List Argument) (args : List Value) (s : State)
    (body : List Value → Body) (k : Handler α) (panic : Nat → State → α)
    (early : List Value → Variant → State → α) :
    arguments xs args s (fun vs st => boxed (body vs) st k panic) early =
    arguments xs args s (fun vs st => scalar (body vs) st k panic) early := by
  have h : (fun vs st => boxed (body vs) st k panic) =
      (fun vs st => scalar (body vs) st k panic) := by
    funext vs st
    exact all_exits _ _ _ _
  rw [h]

-- Scopes are ordered oldest first, as in QbeGen. Lookup searches the
-- visible suffix newest first, then the package. Caller-local rebinding
-- cannot affect any lookup in the emitted callee body.
abbrev Frame := Nat → Option Value
def lookup (frames : List Frame) (pkg : Nat → Value) (name : Nat) : Value :=
  ((frames.reverse.findSome? (fun f => f name)).getD (pkg name))
theorem lexical_boundary (caller callee : List Frame) (pkg : Nat → Value) (name : Nat) :
    lookup ((caller ++ callee).drop caller.length) pkg name = lookup callee pkg name := by
  simp

end VariantReturn

/-! ## 2. Immediately destructured primitive tuples -/


namespace TupleProjection

abbrev Word := BitVec 64
structure Memory where
  words : Nat → Word
  refs : Nat → Nat
  trace : List Nat
inductive Exit where | returned (value : Word) | panic (code : Nat)
abbrev Step := Memory → Except Exit Word × Memory

-- Effects include writes through aliases. An abrupt result stops evaluation
-- with exactly the state produced by the failing expression.
def eval (es : List Step) (s : Memory) : Except Exit (List Word) × Memory :=
  match es with
  | [] => (.ok [], s)
  | e :: rest =>
    match e s with
    | (.error x, t) => (.error x, t)
    | (.ok w, t) =>
      match eval rest t with
      | (.error x, u) => (.error x, u)
      | (.ok ws, u) => (.ok (w :: ws), u)

-- A private fixed-size scratch buffer, separate from the caller's memory.
-- Fields are written at consecutive indices; other slots keep their values.
def write (buf : Nat → Word) (i : Nat) (ws : List Word) : Nat → Word :=
  match ws with
  | [] => buf
  | w :: tl => write (fun j => if j = i then w else buf j) (i+1) tl

def read (buf : Nat → Word) (i n : Nat) : List Word :=
  match n with
  | 0 => []
  | n+1 => buf i :: read buf (i+1) n

theorem untouched (ws : List Word) (buf : Nat → Word) (i j : Nat) (hj : j < i) :
    write buf i ws j = buf j := by
  induction ws generalizing buf i with
  | nil => rfl
  | cons w ws ih =>
    simp only [write]
    rw [ih _ _ (by omega)]
    simp [Nat.ne_of_lt hj]

theorem fields_preserved (ws : List Word) (buf : Nat → Word) (i : Nat) :
    read (write buf i ws) i ws.length = ws := by
  induction ws generalizing buf i with
  | nil => rfl
  | cons w ws ih =>
    simp only [List.length_cons, write, read]
    rw [untouched ws _ (i+1) i (by omega), ih]
    simp

-- A fresh tuple's identity stays private to destructuring. Dropping a tuple
-- containing only primitive words invokes no payload destructor.
structure Box where
  fields : List Word
def heapPath {α : Type} (es : List Step) (s : Memory) (bind : List Word → Memory → α)
    (stop : Exit → Memory → α) : α :=
  match eval es s with
  | (.error x, t) => stop x t
  | (.ok ws, t) => bind (Box.mk ws).fields t

-- Evaluate into a private buffer as we go, independent of the heap semantics.
def stackEval (es : List Step) (buf : Nat → Word) (i : Nat) (s : Memory) :
    Except Exit (Nat → Word) × Memory :=
  match es with
  | [] => (.ok buf, s)
  | e :: rest =>
    match e s with
    | (.error x, t) => (.error x, t)
    | (.ok w, t) => stackEval rest (fun j => if j = i then w else buf j) (i+1) t

theorem simulation (es : List Step) (buf : Nat → Word) (i : Nat) (s : Memory) :
    stackEval es buf i s = (match eval es s with
    | (.error x, t) => (.error x, t)
    | (.ok ws, t) => (.ok (write buf i ws), t)) := by
  induction es generalizing buf i s with
  | nil => rfl
  | cons e es ih =>
    simp only [stackEval, eval]
    cases h : e s with
    | mk a t =>
      cases a with
      | error => rfl
      | ok w =>
        simp only
        rw [ih]
        cases eval es t with | mk r u => cases r <;> rfl

theorem arity (es : List Step) (s t : Memory) (ws : List Word)
    (h : eval es s = (.ok ws, t)) : ws.length = es.length := by
  induction es generalizing s t ws with
  | nil => simp [eval] at h; simp [← h.1]
  | cons e es ih =>
    simp only [eval] at h
    split at h
    · cases h
    · split at h
      · cases h
      · rename_i w st _ vs en he
        simp only [Prod.mk.injEq, Except.ok.injEq] at h
        rw [← h.1]
        simp [ih _ _ _ he]

def stackPath {α : Type} (es : List Step) (buf : Nat → Word) (s : Memory)
    (bind : List Word → Memory → α) (stop : Exit → Memory → α) : α :=
  match stackEval es buf 0 s with
  | (.error x, t) => stop x t
  | (.ok final, t) => bind (read final 0 es.length) t

theorem destructure {α : Type} (es : List Step) (buf : Nat → Word) (s : Memory)
    (bind : List Word → Memory → α) (stop : Exit → Memory → α) :
    heapPath es s bind stop = stackPath es buf s bind stop := by
  simp only [heapPath, stackPath, simulation]
  cases h : eval es s with
  | mk a t =>
    cases a with
    | error => rfl
    | ok ws =>
      simp only
      rw [← arity es s t ws h, fields_preserved]

end TupleProjection

/-! ## 3. Fixed literal table length -/


namespace FixedLiteral

abbrev Word := BitVec 64
structure Store where
  cells : Nat → List Word
  slots : Nat → Nat
  references : Nat → Nat
  trace : List Word

-- 'slot' is the compiler's fresh lexical slot, 'addr' the initialized object.
def Valid (s : Store) (slot addr n : Nat) : Prop :=
  s.slots slot = addr ∧ (s.cells addr).length = n

def writeElement (s : Store) (addr i : Nat) (v : Word) : Store :=
  {s with cells := fun a => if a = addr then (s.cells a).set i v else s.cells a}

theorem alias_write (s : Store) (slot addr n a i : Nat) (v : Word)
    (h : Valid s slot addr n) : Valid (writeElement s a i v) slot addr n := by
  rcases h with ⟨hs, hn⟩
  constructor
  · exact hs
  · by_cases eq : addr = a <;> simp_all [writeElement]

def rebind (s : Store) (other addr : Nat) : Store :=
  {s with slots := fun k => if k = other then addr else s.slots k}

theorem shadow (s : Store) (slot addr n other ptr : Nat) (fresh : slot ≠ other)
    (h : Valid s slot addr n) : Valid (rebind s other ptr) slot addr n := by
  simpa [Valid, rebind, fresh] using h

-- Compare the actual header loaded before the loop with a static immediate.
-- The loop continuation can observe effects, bounds failures, trace, identity,
-- mutations and RC counters. Only the read of initialized metadata is replaced.
def fromHeader {α : Type} (s : Store) (slot : Nat) (loop : Nat → Nat → Store → α) : α :=
  loop (s.cells (s.slots slot)).length (s.slots slot) s
def fromLiteral {α : Type} (s : Store) (slot n : Nat) (loop : Nat → Nat → Store → α) : α :=
  loop n (s.slots slot) s

theorem hoist {α : Type} (s : Store) (slot addr n : Nat) (h : Valid s slot addr n)
    (loop : Nat → Nat → Store → α) :
    fromHeader s slot loop = fromLiteral s slot n loop := by
  simp [fromHeader, fromLiteral, h.1, h.2]

inductive Edit where
  | set (addr index : Nat) (v : Word)
  | bind (slot addr : Nat)
  | effect (refs : Nat → Nat) (event : Word)
def keep (slot : Nat) : Edit → Prop
  | .bind other _ => slot ≠ other
  | _ => True
def runEdit (s : Store) : Edit → Store
  | .set a i v => writeElement s a i v
  | .bind k a => rebind s k a
  | .effect refs event => {s with references := refs, trace := event :: s.trace}

theorem run_prefix (es : List Edit) (s : Store) (slot addr n : Nat)
    (ok : ∀ e ∈ es, keep slot e) (h : Valid s slot addr n) :
    Valid (es.foldl runEdit s) slot addr n := by
  induction es generalizing s with
  | nil => exact h
  | cons e rest ih =>
    apply ih
    · intro x hx
      exact ok x (List.mem_cons_of_mem e hx)
    · cases e with
      | set a i v => exact alias_write _ _ _ _ _ _ _ h
      | bind k a => exact shadow _ _ _ _ _ _ (ok (.bind k a) (by simp)) h
      | effect r v => exact h

end FixedLiteral

end PionQbeEcosystemUnboxFixedLen
