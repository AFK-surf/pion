/-
Invariants behind three byte-identical compile-speed optimizations:
  1. `compiler/src/cli/main.pion` `drv_build_targets`, multi-unit direct-object
     pipeline (`Workers`): running the RC pass in the workers keeps every unit's
     text (`purePass`) and does not depend on completion order
     (`completionOrder`); the `turn` token makes the batches write the CAS
     prefix and report the first error of one ordered producer (`orderedGate`,
     `contiguousBatches`), a failed write outranks a backend failure
     (`failedWriteWins`), and no worker or producer can wait forever
     (`predecessorsTerminate`, `canEnqueue`, `backendRoom`).
  2. `compiler/src/core/inline_rc.pion` `irc_trim_slice` and
     `irc_split_lines_range` (`Offsets`): trimming two offsets before
     materializing equals slicing and then trimming, non-ASCII ranges included
     (`wsAscii`, `asciiOfTrim`, `trimSlice`, `offsetSlice`), and the line's
     ASCII flag kept by the newline scan selects the same text
     (`asciiStep`, `lineMaterialize`).
  3. `compiler/src/cli/main.pion` `drv_cleanup_ssa` (`Chunks`): an accepted cut
     leaves the QBE lexer in its initial state (`acceptedCut`), so restarting
     there visits the same states (`lexicalRestart`), and concatenating the
     cleaned chunks in order gives the whole-module output (`orderedConcat`).

Plain kernel checks, no proof holes (compatible with both standalone
`lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeParallelRcSpeedOpts

namespace Workers

-- All data indexed by a unit come from the producer's single emission order.
def observe (f : ι → α) (completed : List ι) (key : ι) [DecidableEq ι] : Option α :=
  if key ∈ completed then some (f key) else none

theorem completionOrder [DecidableEq ι] (f : ι → α) (k : ι)
    {xs ys : List ι} (h : xs.Perm ys) :
    observe f xs k = observe f ys k := by
  simp only [observe, h.mem_iff]

-- State after a sequence of writes: an ordered success prefix and the first error.
def publish : List (Except ε α) → List α × Option ε
  | [] => ([], none)
  | .error e :: _ => ([], some e)
  | .ok x :: xs =>
    let rest := publish xs
    (x :: rest.1, rest.2)

def followedBy (a b : List α × Option ε) : List α × Option ε :=
  match a.2 with
  | some _ => a
  | none => (a.1 ++ b.1, b.2)

theorem orderedGate (xs ys : List (Except ε α)) :
    publish (xs ++ ys) = followedBy (publish xs) (publish ys) := by
  induction xs with
  | nil => simp [publish, followedBy]
  | cons x xs ih =>
    cases x with
    | error e => simp [publish, followedBy]
    | ok v =>
      simp only [List.cons_append, publish, ih]
      cases h : publish xs with
      | mk vals err => cases err <;> simp [followedBy]

def batches : List (List (Except ε α)) → List α × Option ε
  | [] => ([], none)
  | b :: bs => followedBy (publish b) (batches bs)

theorem contiguousBatches (bs : List (List (Except ε α))) :
    batches bs = publish bs.flatten := by
  induction bs with
  | nil => rfl
  | cons b bs ih => simp [batches, ih, orderedGate]

theorem purePass (finish : α → β) (bs : List (List α)) :
    (bs.map (List.map finish)).flatten = bs.flatten.map finish := by
  induction bs with
  | nil => rfl
  | cons b bs ih => simp only [List.map_cons, List.flatten_cons, List.map_append, ih]

def finalError (front back : Option ε) := front.orElse (fun _ => back)

theorem failedWriteWins (e : ε) (back : Option ε) :
    finalError (some e) back = some e := rfl

-- A worker may await the preceding batch only. The first token is buffered.
theorem predecessorsTerminate : WellFounded (fun a b : Nat => a + 1 = b) := by
  have sub : Subrelation (fun a b : Nat => a + 1 = b) (fun a b => a < b) := by
    intro a b h
    change a + 1 = b at h
    omega
  exact sub.wf Nat.lt_wfRel.wf

-- A producer can enqueue a complete batch even if its worker has not started.
theorem canEnqueue {start pos stop : Nat} (hs : start ≤ pos) (hp : pos < stop) :
    pos - start < stop - start := by omega

-- Each backend reports at most once; the parent reads only after scope joins.
theorem backendRoom {already workers : Nat} (h : already < workers) :
    already + 1 < workers + 1 := by omega

end Workers

namespace Offsets

def ws (x : Nat) : Bool := x == 9 || x == 13 || x == 32

def ascii (x : Nat) : Bool := decide (x < 128)

def trim (xs : List Nat) := ((xs.dropWhile ws).reverse.dropWhile ws).reverse

theorem wsAscii {x : Nat} (h : ws x = true) : ascii x = true := by
  simp [ws] at h
  rcases h with (h | h) | h <;> simp_all [ascii]

theorem asciiOfTrim (xs : List Nat) : (trim xs).all ascii = xs.all ascii := by
  have left (ys : List Nat) : (ys.dropWhile ws).all ascii = ys.all ascii := by
    induction ys with
    | nil => rfl
    | cons y ys ih =>
      cases h : ws y <;> simp_all [List.dropWhile, wsAscii]
  simp [trim, left, List.all_reverse]

-- Non-ASCII slices use the original scalar decoder. dropWhile counts are
-- exactly the two byte offsets calculated by the bounded scans.
def legacy (decode : List Nat → List Nat) (xs : List Nat) :=
  trim (if xs.all ascii then xs else decode xs)

def fused (decode : List Nat → List Nat) (xs : List Nat) :=
  if (trim xs).all ascii then trim xs else legacy decode xs

theorem trimSlice (decode : List Nat → List Nat) (xs : List Nat) :
    fused decode xs = legacy decode xs := by
  unfold fused
  rw [asciiOfTrim]
  split <;> simp_all [legacy]

theorem offsetSlice (xs : List Nat) :
    let first := xs.takeWhile ws
    let rest := xs.drop first.length
    let last := rest.reverse.takeWhile ws
    rest.take (rest.length - last.length) = trim xs := by
  have skip (ys : List Nat) : ys.drop (ys.takeWhile ws).length = ys.dropWhile ws := by
    induction ys with
    | nil => rfl
    | cons y ys ih => cases h : ws y <;> simp [List.dropWhile, List.takeWhile, h, ih]
  dsimp only
  rw [skip]
  unfold trim
  rw [← skip (xs.dropWhile ws).reverse, List.reverse_drop, List.reverse_reverse, List.length_reverse]

-- Each iteration keeps the conjunction for the current line's byte prefix.
theorem asciiStep (line : List Nat) (b : Nat) :
    (line ++ [b]).all ascii = (line.all ascii && ascii b) := by simp

theorem lineMaterialize (decode : List Nat → List Nat) (line : List Nat)
    (flag : Bool) (h : flag = line.all ascii) :
    (if flag then line else if line.all ascii then line else decode line) =
      (if line.all ascii then line else decode line) := by
  subst flag
  split <;> simp_all

end Offsets

namespace Chunks

inductive Mode where | plain | quoted | escaped | comment deriving DecidableEq

structure Lex where
  mode : Mode
  depth : Nat
  deriving DecidableEq

def neutral : Lex := ⟨.plain, 0⟩

def step (s : Lex) (b : Nat) : Lex :=
  match s.mode with
  | .comment => if b == 10 then ⟨.plain, s.depth⟩ else s
  | .escaped => ⟨.quoted, s.depth⟩
  | .quoted =>
    if b == 92 then ⟨.escaped, s.depth⟩
    else if b == 34 then ⟨.plain, s.depth⟩ else s
  | .plain =>
    if b == 34 then ⟨.quoted, s.depth⟩
    else if b == 35 then ⟨.comment, s.depth⟩
    else if b == 123 then ⟨.plain, s.depth + 1⟩
    else if b == 125 then ⟨.plain, s.depth - 1⟩ else s

def unquoted (s : Lex) := s.mode == .plain || s.mode == .comment

theorem acceptedCut (s : Lex)
    (h : unquoted ([125, 10].foldl step s) = true)
    (d : ([125, 10].foldl step s).depth = 0) :
    [125, 10].foldl step s = neutral := by
  rcases s with ⟨m, depth⟩
  cases m <;> simp_all [step, neutral, unquoted]

-- Restarting the scanner at a checked boundary gives exactly the same suffix states.
theorem lexicalRestart (front suffix : List Nat) (h : front.foldl step neutral = neutral) :
    (front ++ suffix).foldl step neutral = suffix.foldl step neutral := by
  simp [List.foldl_append, h]

-- A record denotes either verbatim top-level bytes or one complete function.
-- The dev pass takes no call-graph inputs from other records.
inductive Record (α β : Type) where | raw (s : List α) | fnBody (f : β)

def emit (clean : β → List α) : Record α β → List α
  | .raw s => s
  | .fnBody f => clean f

theorem orderedConcat (clean : β → List α) (groups : List (List (Record α β))) :
    (groups.map (fun g => g.flatMap (emit clean))).flatten =
    groups.flatten.flatMap (emit clean) := by
  induction groups with
  | nil => rfl
  | cons g gs ih =>
    simp only [List.map_cons, List.flatten_cons, List.flatMap_append, ih]

end Chunks

end PionQbeParallelRcSpeedOpts
