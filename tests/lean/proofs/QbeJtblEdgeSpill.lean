/-
Store placement behind `sinktablehomes` / `sinkhome` in `vendor/qbe/rega.c`.

After physical register allocation and edge parallel copies, a loop jump
table (or its unique direct predecessor) can still write a single-definition
integer temporary to its compiler-private spill home although only a minority
of the table entries can read that home before the next original write. The
write is replaced by a `nop` and prepended, from the register that still holds
the value at the end of the dispatch (not clobbered by the table), to each
selected target. A selected target has the table as its sole predecessor and
duplicate entries share one prepended write.

The private home is observable only through later reads, so the model tracks
reads, writes of the home and independent observable events.

  1. `deadHome`: if no read of the home precedes its next write along a path,
     the value stored before the path is unobservable.
  2. `crossPrefix`: a prefix that never touches the home contributes its
     events unchanged.
  3. `sink`: moving the write across such a prefix onto a selected edge, with
     the register still holding the written value, keeps every observation;
     an edge that is not selected only needs `deadHome` (selection may
     over-approximate).
  4. `markedOnPath`: the backward may-read closure that seeds every reading
     block and adds predecessors (stopping at the original definition)
     contains the entry of every path reaching a read before the definition.
  5. `prependOnce`: walking the table entries with duplicates, while clearing
     the pending mark of a target once it received the write, prepends the
     write exactly once to every pending target and leaves every other block
     unchanged.
  6. `budgetSafe`: every candidate is moved only when all of its safety
     conditions hold and otherwise skipped; a scan truncated by the
     `2 * ngpr` budget at any point is a prefix of such steps and therefore
     keeps the observations as well.
-/

namespace PionQbeJtblEdgeSpill

namespace StorePlacement

/-- An event on the unique private spill home, or an independent observable event. -/
inductive Event (α β : Type) where
  | read
  | write (x : α)
  | emit (y : β)

section Observations

variable {α β : Type}

/-- The final private home is observable only through a subsequent read. -/
def observations (x : α) : List (Event α β) → List (Sum α β)
  | [] => []
  | .read :: rest => .inl x :: observations x rest
  | .write y :: rest => observations y rest
  | .emit y :: rest => .inr y :: observations x rest

/-- Whether the path reads the home before writing it again. -/
def needed : List (Event α β) → Bool
  | [] => false
  | .read :: _ => true
  | .write _ :: _ => false
  | .emit _ :: rest => needed rest

theorem deadHome (path : List (Event α β)) (old fresh : α)
    (dead : needed path = false) :
    observations old path = observations fresh path := by
  induction path with
  | nil => rfl
  | cons e rest ih =>
    cases e with
    | read => simp [needed] at dead
    | write => rfl
    | emit y => simp only [observations]; rw [ih dead]

/-- The prefix contains no access to this one private home. Other operations,
    including operations on other homes, can emit arbitrary observations. -/
theorem crossPrefix (prior : List β) (x : α) (path : List (Event α β)) :
    observations x (prior.map Event.emit ++ path) =
      prior.map Sum.inr ++ observations x path := by
  induction prior with
  | nil => rfl
  | cons y ys ih => simp [observations, ih]

/-- `keep` can over-approximate the set of arms that reach a use. A kept edge
    executes its store before the parallel copies, from the register that
    still holds the value at the end of the dispatch. -/
theorem sink (prior : List β) (path : List (Event α β)) (old fresh reg : α)
    (keep : Bool) (registerValue : reg = fresh)
    (covers : keep = false → needed path = false) :
    observations old (.write fresh :: (prior.map Event.emit ++ path)) =
      observations old (prior.map Event.emit ++
        (if keep then .write reg :: path else path)) := by
  subst reg
  cases keep with
  | false =>
    simp only [Bool.false_eq_true, ↓reduceIte, observations, crossPrefix]
    rw [deadHome path old fresh (covers rfl)]
  | true =>
    simp [observations, crossPrefix]

end Observations

/-- Reachability of a use along a finite control-flow path before the
    defining block kills the incoming contents of the private home. -/
inductive ReachesUse {Node : Type} (reads kills : Node → Prop)
    (edge : Node → Node → Prop) : Node → Prop where
  | here {n} : reads n → ReachesUse reads kills edge n
  | step {a b} : edge a b → ¬ kills a → ReachesUse reads kills edge b →
      ReachesUse reads kills edge a

theorem markedOnPath {Node : Type} {reads kills marked : Node → Prop}
    {edge : Node → Node → Prop}
    (seed : ∀ n, reads n → marked n)
    (close : ∀ a b, edge a b → ¬ kills a → marked b → marked a)
    {n : Node} (path : ReachesUse reads kills edge n) : marked n := by
  induction path with
  | here h => exact seed _ h
  | step h k _ ih => exact close _ _ h k ih

section Entries

variable {ν ι : Type} [DecidableEq ν]

/-- Point update of a function. -/
def upd {γ : Type} (f : ν → γ) (a : ν) (v : γ) : ν → γ :=
  fun x => if x = a then v else f x

/-- The prepend loop of `sinkhome`: the table entries (default first, with
    duplicates) in order; `pend` is `needed[s->id]`, cleared once the store
    `st` was prepended to the instructions `code s` of target `s`. -/
def prependAll (st : ι) : (ν → Bool) → (ν → List ι) → List ν → ν → List ι
  | _, code, [] => code
  | pend, code, s :: rest =>
    if pend s then prependAll st (upd pend s false) (upd code s (st :: code s)) rest
    else prependAll st pend code rest

theorem prependOnce (st : ι) (entries : List ν) (pend : ν → Bool)
    (code : ν → List ι) (s : ν) :
    prependAll st pend code entries s =
      if pend s = true ∧ s ∈ entries then st :: code s else code s := by
  induction entries generalizing pend code with
  | nil => simp [prependAll]
  | cons e rest ih =>
    cases hpe : pend e with
    | true =>
      simp only [prependAll, hpe, ↓reduceIte]
      rw [ih]
      by_cases hs : s = e
      · subst hs
        simp [upd, hpe]
      · simp [upd, hs]
    | false =>
      simp only [prependAll, hpe, Bool.false_eq_true, ↓reduceIte]
      rw [ih]
      by_cases hs : s = e
      · subst hs
        simp [hpe]
      · simp [hs]

end Entries

section Budget

variable {κ σ ω : Type}

/-- The candidate scan of `sinktablehomes`: each examined candidate spends one
    unit of the budget and is moved only when all of its safety conditions
    hold; an empty budget stops the scan with the current program. -/
def scan (safe : κ → σ → Bool) (move : κ → σ → σ) : Nat → List κ → σ → σ
  | 0, _, p => p
  | _ + 1, [], p => p
  | n + 1, c :: cs, p => scan safe move n cs (if safe c p then move c p else p)

theorem budgetSafe (obs : σ → ω) (safe : κ → σ → Bool) (move : κ → σ → σ)
    (sound : ∀ c p, safe c p = true → obs (move c p) = obs p) :
    ∀ (n : Nat) (cs : List κ) (p : σ), obs (scan safe move n cs p) = obs p := by
  intro n
  induction n with
  | zero => intro cs p; rfl
  | succ n ih =>
    intro cs p
    cases cs with
    | nil => rfl
    | cons c cs =>
      simp only [scan]
      rw [ih]
      cases h : safe c p with
      | true => simp only [↓reduceIte]; exact sound c p h
      | false => rfl

end Budget

end StorePlacement

end PionQbeJtblEdgeSpill
