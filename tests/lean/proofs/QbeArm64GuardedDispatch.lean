/-
Guarded jump-table dispatch copies in the QBE `arm64_apple` backend
(`vendor/qbe/main.c`, `replicatedispatch`, run after `rega` / `simpljmp`).

A block `b` ending in `jmp head`, where `head` is a guard block ending in
`jnz c, t, f` and one side `tb` of the guard is a jump-table block, is
rewritten to run its own instructions followed by the guard's and to branch on
`c` itself, with the side that was `tb` now going to a fresh copy `clone` of
`tb` (same instructions, same selector, same default and entries). The other
side, every other block and the original `tb` are unchanged. Registers are
already allocated, so a block is a list of state transformers; the state may
hold registers, flags, memory and an accumulated trace of visible events, and
an instruction may fault (`Except.error`).

  1. `body_append`: running `ins₁ ++ ins₂` is running `ins₁` and then `ins₂`,
     including a fault in either part (the C code concatenates `b->ins` and
     `head->ins`).
  2. `select_in`, `select_oob`, `select_negative`, `select_mem`: QBE's `jtbl`
     compares the 32-bit selector unsigned against the entry count, so an
     index past the last entry, and every word with the sign bit set when the
     table has at most 32 entries (`MaxTable`), takes the default; the target
     is always the default or an entry (duplicate entries included).
  3. `clone_edge`, `clone_table`, `other_blocks`: one step of the rewritten
     program from `b` is the two steps `b`, `head` of the original once the
     clone is read as `tb`; a step from the clone is a step from `tb`; every
     other block steps as before (`sim` covers all configurations).
  4. `arbitrary_path` (edge-wise equal steps give equal walks of any length),
     `walk_map` (a step simulation lifts to walks), `walk_fused`: every
     `n`-step walk of the rewritten program, read back through the clone
     projection, is an `m`-step walk of the original with `n ≤ m ≤ 2 n`, so
     every reachable configuration, fault, return and event trace, across
     loop back edges, is one of the original's (`replicate_correct`).
Each of the at most 24 sites per function is one such rewrite with its own
fresh clone; the theorems apply to them one after another.
-/

namespace PionQbeArm64GuardedDispatch

variable {σ ε L : Type}

/-- An allocated instruction: reads and writes the machine state or faults. -/
abbrev Code (σ ε : Type) := σ → Except ε σ

def seq (f g : Code σ ε) : Code σ ε :=
  fun s => (f s).bind g

def body (ins : List (Code σ ε)) : Code σ ε :=
  fun s => ins.foldl (fun r i => r.bind i) (.ok s)

theorem foldl_error (b : List (Code σ ε)) (e : ε) :
    b.foldl (fun (r : Except ε σ) i => r.bind i) (Except.error e) = Except.error e := by
  induction b with
  | nil => rfl
  | cons i b ih => exact ih

theorem body_append (a b : List (Code σ ε)) (s : σ) :
    body (a ++ b) s = seq (body a) (body b) s := by
  simp only [body, seq, List.foldl_append]
  cases a.foldl (fun r i => Except.bind r i) (.ok s) with
  | ok t => rfl
  | error e => exact foldl_error b e

/-- `jtbl`: the selector word is compared unsigned with the entry count. -/
def select (dflt : L) (arms : Array L) (w : UInt32) : L :=
  if h : w.toNat < arms.size then arms[w.toNat] else dflt

theorem select_in (dflt : L) (arms : Array L) (w : UInt32) (h : w.toNat < arms.size) :
    select dflt arms w = arms[w.toNat] := by
  simp [select, h]

theorem select_oob (dflt : L) (arms : Array L) (w : UInt32) (h : arms.size ≤ w.toNat) :
    select dflt arms w = dflt := by
  have h' : ¬ w.toNat < arms.size := Nat.not_lt.mpr h
  simp [select, h']

/-- A "negative" selector (sign bit set) of a table of at most 32 entries. -/
theorem select_negative (dflt : L) (arms : Array L) (w : UInt32)
    (hs : arms.size ≤ 32) (hw : 2147483648 ≤ w.toNat) :
    select dflt arms w = dflt :=
  select_oob dflt arms w (by omega)

theorem select_mem (dflt : L) (arms : Array L) (w : UInt32) :
    select dflt arms w = dflt ∨ select dflt arms w ∈ arms := by
  unfold select
  split
  · exact Or.inr (Array.getElem_mem _)
  · exact Or.inl rfl

inductive Term (σ L : Type) where
  | jmp (l : L)
  | jnz (c : σ → Bool) (t f : L)
  | jtbl (sel : σ → UInt32) (dflt : L) (arms : Array L)
  | ret

structure Blk (σ ε L : Type) where
  ins : List (Code σ ε)
  term : Term σ L

/-- A configuration: at the start of a block, or returned. -/
inductive Conf (σ L : Type) where
  | run (l : L) (s : σ)
  | halt (s : σ)

def Targets : Term σ L → L → Prop
  | .jmp l, x => x = l
  | .jnz _ t f, x => x = t ∨ x = f
  | .jtbl _ d a, x => x = d ∨ x ∈ a
  | .ret, _ => False

def next (t : Term σ L) (s : σ) : Conf σ L :=
  match t with
  | .jmp l => .run l s
  | .jnz c t f => .run (if c s then t else f) s
  | .jtbl sel d a => .run (select d a (sel s)) s
  | .ret => .halt s

def step (p : L → Blk σ ε L) : Conf σ L → Except ε (Conf σ L)
  | .run l s => (body (p l).ins s).bind fun v => .ok (next (p l).term v)
  | .halt s => .ok (.halt s)

variable [DecidableEq L]

/-- `replicatedispatch` for one site: `b` (ending in `jmp head`) takes the
guard's instructions and branch, with the table side `tb` retargeted to the
fresh block `clone`, a copy of `tb`. -/
def replicate (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L) :
    L → Blk σ ε L := fun l =>
  if l = clone then p tb
  else if l = b then
    { ins := (p b).ins ++ (p head).ins,
      term := .jnz c (if t = tb then clone else t) (if f = tb then clone else f) }
  else p l

/-- Read the clone as the table block it copies. -/
def proj (clone tb : L) : Conf σ L → Conf σ L
  | .run l s => .run (if l = clone then tb else l) s
  | .halt s => .halt s

/-- The original program with the two steps `b`, `head` taken as one. -/
def fstep (p : L → Blk σ ε L) (b : L) : Conf σ L → Except ε (Conf σ L)
  | .run l s => if l = b then (step p (.run l s)).bind (step p) else step p (.run l s)
  | .halt s => .ok (.halt s)

theorem proj_next (clone tb : L) (t : Term σ L) (v : σ) (h : ¬ Targets t clone) :
    proj clone tb (next t v) = next t v := by
  cases t with
  | jmp l =>
    simp only [Targets] at h
    have hl : l ≠ clone := fun e => h e.symm
    simp [next, proj, hl]
  | jnz c t f =>
    simp only [Targets, not_or] at h
    have h1 : t ≠ clone := fun e => h.1 e.symm
    have h2 : f ≠ clone := fun e => h.2 e.symm
    by_cases hc : c v = true <;> simp [next, proj, hc, h1, h2]
  | jtbl sel d a =>
    simp only [Targets, not_or] at h
    have hs : select d a (sel v) ≠ clone := by
      intro e
      rcases select_mem d a (sel v) with h' | h'
      · exact h.1 (e ▸ h')
      · exact h.2 (e ▸ h')
    simp [next, proj, hs]
  | ret => rfl

theorem sim (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L)
    (hb : (p b).term = .jmp head) (hh : (p head).term = .jnz c t f)
    (hcb : clone ≠ b) (htb : tb ≠ b) (fresh : ∀ l, ¬ Targets (p l).term clone)
    (x : Conf σ L) :
    (step (replicate p b head tb clone c t f) x).bind (fun y => .ok (proj clone tb y)) =
      fstep p b (proj clone tb x) := by
  cases x with
  | halt s => rfl
  | run l s =>
    by_cases hl : l = clone
    · subst hl
      simp only [step, replicate, proj, fstep, htb, ↓reduceIte]
      cases body (p tb).ins s with
      | error e => rfl
      | ok v =>
        show Except.ok (proj l tb (next (p tb).term v)) = Except.ok (next (p tb).term v)
        rw [proj_next _ _ _ _ (fresh tb)]
    · by_cases hlb : l = b
      · subst hlb
        have hhc : head ≠ clone := by
          intro e
          apply fresh l
          rw [hb]
          exact e.symm
        have ht : ¬ Targets (p head).term clone := fresh head
        rw [hh] at ht
        simp only [Targets, not_or] at ht
        simp only [step, replicate, proj, fstep, hl, ↓reduceIte, hb]
        rw [body_append]
        simp only [seq]
        cases body (p l).ins s with
        | error e => rfl
        | ok v =>
          show (Except.bind (body (p head).ins v) _).bind _ =
            (body (p head).ins v).bind (fun w => Except.ok (next (p head).term w))
          rw [hh]
          cases body (p head).ins v with
          | error e => rfl
          | ok w =>
            show Except.ok (proj clone tb (next (.jnz c _ _) w)) = Except.ok (next (.jnz c t f) w)
            congr 1
            have h1 : t ≠ clone := fun e => ht.1 e.symm
            have h2 : f ≠ clone := fun e => ht.2 e.symm
            by_cases htt : t = tb <;> by_cases hft : f = tb <;> by_cases hc : c w = true <;>
              simp [next, proj, htt, hft, hc, h1, h2]
      · simp only [step, replicate, proj, fstep, hl, hlb, ↓reduceIte]
        cases body (p l).ins s with
        | error e => rfl
        | ok v =>
          show Except.ok (proj clone tb (next (p l).term v)) = Except.ok (next (p l).term v)
          rw [proj_next _ _ _ _ (fresh l)]

theorem clone_edge (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L)
    (hb : (p b).term = .jmp head) (hh : (p head).term = .jnz c t f)
    (hcb : clone ≠ b) (htb : tb ≠ b) (fresh : ∀ l, ¬ Targets (p l).term clone) (s : σ) :
    (step (replicate p b head tb clone c t f) (.run b s)).bind (fun y => .ok (proj clone tb y)) =
      (step p (.run b s)).bind (step p) := by
  have := sim p b head tb clone c t f hb hh hcb htb fresh (.run b s)
  rw [this]
  simp [proj, fstep, Ne.symm hcb]

theorem clone_table (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L)
    (hb : (p b).term = .jmp head) (hh : (p head).term = .jnz c t f)
    (hcb : clone ≠ b) (htb : tb ≠ b) (fresh : ∀ l, ¬ Targets (p l).term clone) (s : σ) :
    (step (replicate p b head tb clone c t f) (.run clone s)).bind (fun y => .ok (proj clone tb y)) =
      step p (.run tb s) := by
  have := sim p b head tb clone c t f hb hh hcb htb fresh (.run clone s)
  rw [this]
  simp [proj, fstep, htb]

theorem other_blocks (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L)
    (l : L) (hl : l ≠ clone) (hlb : l ≠ b) :
    replicate p b head tb clone c t f l = p l := by
  simp [replicate, hl, hlb]

def walk {α : Type} (st : α → Except ε α) : Nat → α → Except ε α
  | 0, a => .ok a
  | n+1, a => (st a).bind (walk st n)

theorem arbitrary_path {α : Type} (before after : α → Except ε α)
    (edge : ∀ s, before s = after s) (n : Nat) (s : α) :
    walk before n s = walk after n s := by
  induction n generalizing s with
  | zero => rfl
  | succ n ih =>
    simp only [walk, edge]
    cases after s with
    | ok v => exact ih v
    | error _ => rfl

theorem walk_map {α β : Type} (g : α → β) (st : α → Except ε α) (st' : β → Except ε β)
    (h : ∀ x, (st x).bind (fun y => .ok (g y)) = st' (g x)) (n : Nat) (x : α) :
    (walk st n x).bind (fun y => .ok (g y)) = walk st' n (g x) := by
  induction n generalizing x with
  | zero => rfl
  | succ n ih =>
    simp only [walk]
    rw [← h x]
    cases st x with
    | ok y => exact ih y
    | error e => rfl

theorem walk_add {α : Type} (st : α → Except ε α) (a b : Nat) (x : α) :
    walk st (a + b) x = (walk st a x).bind (walk st b) := by
  induction a generalizing x with
  | zero => rw [Nat.zero_add]; rfl
  | succ a ih =>
    rw [Nat.add_right_comm]
    simp only [walk]
    cases st x with
    | ok y => exact ih y
    | error e => rfl

theorem fused_steps (p : L → Blk σ ε L) (b : L) (x : Conf σ L) :
    ∃ k, 1 ≤ k ∧ k ≤ 2 ∧ fstep p b x = walk (step p) k x := by
  cases x with
  | halt s => exact ⟨1, by omega, by omega, rfl⟩
  | run l s =>
    by_cases hl : l = b
    · refine ⟨2, by omega, by omega, ?_⟩
      simp only [fstep, hl, ↓reduceIte, walk]
      have e : ∀ y, (step p y).bind (fun z => Except.ok z) = step p y := fun y => by
        cases step p y <;> rfl
      rw [show (fun x => (step p x).bind fun z => Except.ok z) = step p from funext e]
    · refine ⟨1, by omega, by omega, ?_⟩
      simp only [fstep, hl, ↓reduceIte, walk]
      cases step p (.run l s) <;> rfl

theorem walk_fused (p : L → Blk σ ε L) (b : L) (n : Nat) (x : Conf σ L) :
    ∃ m, n ≤ m ∧ m ≤ 2 * n ∧ walk (fstep p b) n x = walk (step p) m x := by
  induction n generalizing x with
  | zero => exact ⟨0, by omega, by omega, rfl⟩
  | succ n ih =>
    obtain ⟨k, hk1, hk2, hk⟩ := fused_steps p b x
    simp only [walk]
    rw [hk]
    cases hw : walk (step p) k x with
    | error e =>
      refine ⟨k + n, by omega, by omega, ?_⟩
      rw [walk_add, hw]
      rfl
    | ok y =>
      obtain ⟨m, hm1, hm2, hm⟩ := ih y
      refine ⟨k + m, by omega, by omega, ?_⟩
      rw [walk_add, hw]
      exact hm

/-- Every walk of the rewritten program is, through the clone projection, a
walk of the original of between `n` and `2 n` steps. -/
theorem replicate_correct (p : L → Blk σ ε L) (b head tb clone : L) (c : σ → Bool) (t f : L)
    (hb : (p b).term = .jmp head) (hh : (p head).term = .jnz c t f)
    (hcb : clone ≠ b) (htb : tb ≠ b) (fresh : ∀ l, ¬ Targets (p l).term clone)
    (n : Nat) (x : Conf σ L) :
    ∃ m, n ≤ m ∧ m ≤ 2 * n ∧
      (walk (step (replicate p b head tb clone c t f)) n x).bind (fun y => .ok (proj clone tb y)) =
        walk (step p) m (proj clone tb x) := by
  rw [walk_map (proj clone tb) _ (fstep p b) (sim p b head tb clone c t f hb hh hcb htb fresh)]
  exact walk_fused p b n (proj clone tb x)

end PionQbeArm64GuardedDispatch
