/-
Invariants behind six byte-identical cold-bootstrap and ARM64 Mach-O compile
speed changes (Opt-Track P).

Transfer (`me_compute_gpr_out` in `vendor/qbe/arm64/macho.c`).
  1. `compose_correct`, `block_transfer`, `register_file_transfer`: every
     instruction of the reverse scan maps a register bit to
     `(x && keep) || gen`; composing these masks once per block gives the same
     block transfer as replaying the instructions, bit by bit over 64 bits.
  2. `sweep`: equal per-block updates keep every state of a fixed-point sweep.

Liveness worklist (`filllive` in `vendor/qbe/live.c`, `bscopy` / `bsequal`).
  3. `retained_edge`, `clean_predecessor`: when no successor input changed
     since a block was last visited, the phi-aware edge union reproduces its
     old output, so the block may be skipped.
  4. `copied_words`: copying the words of a set as a block equals copying them
     one at a time.

Driver (`drv_build_targets` in `compiler/src/cli/main.pion`).
  5. `preemit`: emitting the first unit of the largest batch before the
     workers start and handing it over in its slot yields the same ordered
     unit texts.
  6. `hashes_by_index`: serial source hashing gives the same hash at every
     canonical index.
  7. `published_prefix`: the first failed write keeps the canonical prefix.

Lexer (`lex` / `getint` in `vendor/qbe/parse.c`).
  8. `next_buffered`, `unread_delimiter`, `float_marker`: one byte of
     lookahead (or end of stream) reads the same stream as `ungetc`, the
     delimiter of a word stays unread, and `s` / `d` only consume `_` before
     the float conversion.

Projection (`philive` in `vendor/qbe/ssa.c`, `snapshot` in `vendor/qbe/rega.c`).
  9. `transfer_projects`, `block_projects`, `phi_projects`,
     `successors_project`, `rounds_agree`: backwards liveness restricted to
     the temporaries `phiins` queries commutes with every instruction, phi
     edge, successor union and fixed-point round.
 10. `summarize`: the forward `(gen, kill)` summary of a block equals its
     backwards instruction scan.
 11. `bindings`, `physical`: a block snapshot keeps exactly the active binding
     prefix, and physical-register membership only reads the first word.

These are local models of the changed code, checked by the Lean kernel; the
full compiler equivalence is covered by the byte-for-byte gates.
-/

namespace PionQbeColdBootstrapSpeedOpts

namespace TrackP

/-- A physical register's preserved and generated bit. -/
structure Mask where
  keep : Bool
  gen : Bool

def applyBit (m : Mask) (x : Bool) := (x && m.keep) || m.gen

def compose (p q : Mask) : Mask :=
  ⟨p.keep && q.keep, (p.gen && q.keep) || q.gen⟩

theorem compose_correct (p q : Mask) (x : Bool) :
    applyBit (compose p q) x = applyBit q (applyBit p x) := by
  rcases p with ⟨a,b⟩
  rcases q with ⟨c,d⟩
  cases a <;> cases b <;> cases c <;> cases d <;> cases x <;> rfl

def summary : List Mask → Mask
  | [] => ⟨true,false⟩
  | m :: ms => compose m (summary ms)

theorem block_transfer (ms : List Mask) (x : Bool) :
    applyBit (summary ms) x = ms.foldl (fun s m => applyBit m s) x := by
  induction ms generalizing x with
  | nil => cases x <;> rfl
  | cons m ms ih => simp [summary, compose_correct, ih, List.foldl]

theorem register_file_transfer (ms : List (Fin 64 → Mask)) (x : Fin 64 → Bool) :
    (fun i => applyBit (summary (ms.map (· i))) (x i)) =
    (fun i => (ms.map (· i)).foldl (fun s m => applyBit m s) (x i)) := by
  funext i
  exact block_transfer _ _

/-- Equality at each scheduled update preserves all states of a sweep. -/
theorem sweep {S B : Type} (f g : S → B → S) (h : ∀ x b, f x b = g x b)
    (order : List B) (x : S) : order.foldl f x = order.foldl g x := by
  induction order generalizing x with
  | nil => rfl
  | cons b bs ih => simpa only [List.foldl, h] using ih (g x b)

-- A phi edge clears successor definitions then adds predecessor-specific uses.
def edge (incoming kills uses : Bool) := (incoming && !kills) || uses
def edgeFold (s : List Bool) (old : Bool) := s.foldl (· || ·) old

theorem retained_edge (s : List Bool) (old : Bool)
    (h : ∀ e ∈ s, e = true → old = true) : edgeFold s old = old := by
  induction s generalizing old with
  | nil => rfl
  | cons e es ih =>
    have he := h e (by simp)
    have ht : ∀ a ∈ es, a = true → old = true :=
      fun a ha => h a (by simp [ha])
    have eq : (old || e) = old := by cases old <;> cases e <;> simp_all
    simpa [edgeFold, List.foldl, eq] using ih old ht

theorem clean_predecessor {B : Type} (successors : List B) (prev now : B → Bool)
    (kills uses : B → Bool) (old : Bool)
    (unchanged : ∀ b ∈ successors, now b = prev b)
    (covered : ∀ b ∈ successors, edge (prev b) (kills b) (uses b) = true → old = true) :
    edgeFold (successors.map (fun b => edge (now b) (kills b) (uses b))) old = old := by
  apply retained_edge
  intro e he
  obtain ⟨b,hb,rfl⟩ := List.mem_map.mp he
  rw [unchanged b hb]
  exact covered b hb

theorem copied_words {α : Type} (src : List α) :
    src.map id = src := by simp

-- The producer emits exactly the same ordered head followed by its successors.
theorem preemit {A T : Type} (emit : A → T) (first : A) (tail : List A) :
    let ready := emit first
    ready :: tail.map emit = (first :: tail).map emit := by rfl

theorem hashes_by_index {A H : Type} (hash : A → H) (xs : List A)
    (i : Nat) : (xs.map hash)[i]? = xs[i]?.map hash := by simp

theorem published_prefix {T : Type} (ok : T → Bool) (x : T) (xs : List T) :
    (x :: xs).takeWhile ok = (if ok x then x :: xs.takeWhile ok else []) := by
  cases h : ok x <;> simp [List.takeWhile, h]

-- Model one byte of lookahead, including end of stream.
def stream (pending : Option UInt8) (rest : List UInt8) := pending.toList ++ rest

theorem next_buffered (c : UInt8) (rest : List UInt8) :
    stream (some c) rest = c :: stream none rest := by rfl

theorem unread_delimiter (letters : UInt8 → Bool) (xs : List UInt8) :
    xs.takeWhile letters ++ xs.dropWhile letters = xs := by simp

theorem float_marker (c : UInt8) (rest : List UInt8) :
    (if c = 95 then rest else stream (some c) rest) =
      (if c = 95 then rest else c :: rest) := by rfl

end TrackP

namespace Projection

structure Op (A : Type) where
  reads : A → Bool
  writes : A → Bool

def backward {A : Type} (o : Op A) (live : A → Bool) (a : A) :=
  o.reads a || (live a && !(o.writes a))

def selectOp {A B : Type} (sel : B → A) (o : Op A) : Op B :=
  ⟨fun j => o.reads (sel j), fun j => o.writes (sel j)⟩

theorem transfer_projects {A B : Type} (sel : B → A) (o : Op A) (live : A → Bool) :
    backward (selectOp sel o) (live ∘ sel) = backward o live ∘ sel := by rfl

theorem block_projects {A B : Type} (sel : B → A) (ops : List (Op A)) (live : A → Bool) :
    (ops.map (selectOp sel)).foldr backward (live ∘ sel) =
      (ops.foldr backward live) ∘ sel := by
  induction ops with
  | nil => rfl
  | cons o os ih => simp [ih,transfer_projects]

def branch (dest arg live : Bool) := arg || (live && !dest)

theorem phi_projects {A B : Type} (sel : B → A) (dest arg live : A → Bool) (i : B) :
    branch ((dest ∘ sel) i) ((arg ∘ sel) i) ((live ∘ sel) i) =
    (fun a => branch (dest a) (arg a) (live a)) (sel i) := by rfl

theorem successors_project {A B : Type} (sel : B → A) (succ : List (A → Bool)) (j : B) :
    (succ.map (fun edge => edge ∘ sel)).any (fun edge => edge j) =
      succ.any (fun edge => edge (sel j)) := by simp [Function.comp_def]

theorem rounds_agree {S T : Type} (proj : S → T) (a : S → S) (b : T → T)
    (step : ∀ s, b (proj s) = proj (a s)) (s : S) (n : Nat) :
    Nat.rec (proj s) (fun _ st => b st) n = proj (Nat.rec s (fun _ st => a st) n) := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [ih, step]

-- Forward summary records upward-exposed uses and all definitions seen so far.
def note (g k : Bool) (o : Bool × Bool) :=
  (g || (o.1 && !k), k || o.2)

def evalBits (ops : List (Bool × Bool)) (x : Bool) :=
  ops.foldr (fun o y => o.1 || (y && !o.2)) x

theorem summarize (ops : List (Bool × Bool)) (g k x : Bool) :
    let p := ops.foldl (fun p o => note p.1 p.2 o) (g,k)
    (p.1 || (x && !p.2)) = (g || (evalBits ops x && !k)) := by
  induction ops generalizing g k with
  | nil => rfl
  | cons o os ih =>
    rcases o with ⟨r,w⟩
    change _ = (g || ((r || (evalBits os x && !w)) && !k))
    change ((os.foldl (fun p o => note p.1 p.2 o) (note g k (r,w))).1 || (x && !(os.foldl (fun p o => note p.1 p.2 o) (note g k (r,w))).2)) = _
    rw [ih (note g k (r,w)).1 (note g k (r,w)).2]
    cases g <;> cases k <;> cases r <;> cases w <;> cases (evalBits os x) <;> rfl

-- Snapshots retain exactly the active binding prefix in its original order.
theorem bindings (used spare : List (Nat × Nat)) :
    (used ++ spare).take used.length = used := by simp

theorem physical (regs : Fin 64 → Bool) (temps : Nat → Bool) (r : Fin 64) :
    (if (r.val : Nat) < 64 then regs r else temps r.val) = regs r := by simp [r.isLt]

end Projection

end PionQbeColdBootstrapSpeedOpts
