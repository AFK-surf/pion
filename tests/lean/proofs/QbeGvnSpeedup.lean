/-
Formally verified equivalence theorems for QBE GVN compile-speed optimizations:
  1. `ReachEpoch`: generation-stamped reachability search in `vendor/qbe/cfg.c`
     (`reaches` / `reachesnotvia`), including 32-bit unsigned rollover handling.
  2. `Trail`: undo-trail restoration for `dwl` phi width marks in `vendor/qbe/copy.c`
     (`defwidthle` / `dwlundo`), including repeated writes and nested rollbacks.

Zero external dependencies, no unfinished proofs, pure kernel checks (compatible with
both standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeGvnSpeedup

namespace ReachEpoch

abbrev Vertex := Nat
abbrev Stamp := BitVec 32
abbrev Marks := Vertex → Bool
abbrev Stamps := Vertex → Stamp

def represents (g : Stamp) (m : Marks) (s : Stamps) : Prop :=
  ∀ v, m v = decide (s v = g)

def put {α : Type} (s : Vertex → α) (v : Vertex) (x : α) : Vertex → α :=
  fun w => if w = v then x else s w

theorem mark {g m s} (h : represents g m s) (v : Vertex) :
    represents g (put m v true) (put s v g) := by
  intro w
  by_cases e : w = v <;> simp [put, e, h w]

def next (g : Stamp) (s : Stamps) : Stamp × Stamps :=
  if g + 1 = 0 then (1, fun _ => 0) else (g + 1, s)

/-- Initial zeroed allocation and every mark/rollover preserve this bound. -/
def bounded (g : Stamp) (s : Stamps) : Prop := ∀ v, s v ≤ g

theorem initial : bounded 0 (fun _ => 0) := by intro v; simp

theorem bounded_mark {g s} (h : bounded g s) (v : Vertex) :
    bounded g (put s v g) := by
  intro w
  by_cases e : w = v <;> simp [put, e, h w]

theorem fresh {g s} (h : bounded g s) :
    represents (next g s).1 (fun _ => false) (next g s).2 ∧
    bounded (next g s).1 (next g s).2 := by
  by_cases z : g + 1 = 0
  · simp only [next, ite_eq_left z]
    constructor
    · intro _; exact (by decide : false = decide ((0 : Stamp) = 1))
    · intro _; exact (by decide : (0 : Stamp) ≤ 1)
  · have grows : g.toNat < (g + 1).toNat := by
      have hi := g.isLt
      have nz : (g + 1).toNat ≠ 0 := fun e => z (BitVec.eq_of_toNat_eq e)
      simp [BitVec.toNat_add] at nz ⊢
      omega
    constructor
    · intro v
      simp only [next, ite_eq_right z]
      have hv : (s v).toNat ≤ g.toNat := h v
      have hn : s v ≠ g + 1 := by
        intro eq
        rw [eq] at hv
        omega
      exact (decide_eq_false hn).symm
    · intro v
      simp only [next, ite_eq_right z]
      have hv : (s v).toNat ≤ g.toNat := h v
      change (s v).toNat ≤ (g + 1).toNat
      omega

/-- Any finite trace of the DFS: control flow may branch on marks and return
early, including the target test before the excluded-node test. -/
inductive Trace where
  | ret (v : Bool)
  | visit (v : Vertex) (rest : Trace)
  | test (v : Vertex) (yes no : Trace)

def run (t : Trace) (m : Marks) : Bool × Marks :=
  match t with
  | .ret x => (x, m)
  | .visit v k => run k (put m v true)
  | .test v y n => if m v then run y m else run n m

def stamped (g : Stamp) (t : Trace) (s : Stamps) : Bool × Stamps :=
  match t with
  | .ret x => (x, s)
  | .visit v k => stamped g k (put s v g)
  | .test v y n => if s v = g then stamped g y s else stamped g n s

theorem simulate (t : Trace) {g m s} (h : represents g m s) (b : bounded g s) :
    (run t m).1 = (stamped g t s).1 ∧
    represents g (run t m).2 (stamped g t s).2 ∧
    bounded g (stamped g t s).2 := by
  induction t generalizing m s with
  | ret x => exact ⟨rfl, h, b⟩
  | visit v k ih => exact ih (mark h v) (bounded_mark b v)
  | test v y n iy ino =>
    by_cases e : s v = g
    · simpa [stamped, run, h v, e] using iy h b
    · simpa [stamped, run, h v, e] using ino h b

theorem search_equivalent (t : Trace) {g s} (b : bounded g s) :
    (run t (fun _ => false)).1 = (stamped (next g s).1 t (next g s).2).1 :=
  (simulate t (fresh b).1 (fresh b).2).1

end ReachEpoch

namespace Trail

abbrev State := Nat → Int
abbrev Undo := List (Nat × Int)

def update (s : State) (p : Nat) (w : Int) : State :=
  fun q => if q = p then w else s q

def undo : State → Undo → State
  | s, [] => s
  | s, (p, old) :: rest => undo (update s p old) rest

theorem record_then_undo (s : State) (p : Nat) (w : Int) (rest : Undo) :
    undo (update s p w) ((p, s p) :: rest) = undo s rest := by
  simp only [undo]
  have h : update (update s p w) p (s p) = s := by
    funext q
    by_cases e : q = p <;> simp [update, e]
  rw [h]

theorem undo_append (s : State) (newer older : Undo) :
    undo s (newer ++ older) = undo (undo s newer) older := by
  induction newer generalizing s with
  | nil => rfl
  | cons entry rest ih =>
    rcases entry with ⟨p, w⟩
    exact ih (update s p w)

inductive Valid (initial : State) : State → Undo → Prop
  | start : Valid initial initial []
  | mark {s t} (h : Valid initial s t) (p : Nat) (w : Int) :
      Valid initial (update s p w) ((p, s p) :: t)
  | rollback {s} {newer older : Undo} (h : Valid initial s (newer ++ older)) :
      Valid initial (undo s newer) older

theorem restore {init s t} (h : Valid init s t) : undo s t = init := by
  induction h with
  | start => rfl
  | mark _ p w ih => rw [record_then_undo, ih]
  | rollback _ ih => rw [← undo_append, ih]

theorem equivalent (result : Bool) {s t} (h : Valid (fun _ => 0) s t) :
    (result, undo s t) = (result, fun _ => 0) := by
  rw [restore h]

end Trail

end PionQbeGvnSpeedup
