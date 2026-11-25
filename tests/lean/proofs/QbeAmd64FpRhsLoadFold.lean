/-
Soundness of the AMD64 scalar floating-point right-operand load fold
(`foldoperandloads` in `vendor/qbe/amd64/isel.c`, regression test
`tests/e2e/p119_amd64_fp_rhs_load_fold`).

After instruction selection, QBE rewrites

    %t =k load ADDR          (b->ins[j-1])
    %r =k sub|div %a, %t     (b->ins[j])

into `%r =k sub|div %a, ADDR`, which the emitters encode as
`subs{s,d}` / `divs{s,d}` with a memory source (`%r := %a op [ADDR]`), when

  * `k` is `s` or `d` and the load has the same class (same width),
  * the load result is a virtual temporary with exactly one use in the
    selected IR (address components, phis and jumps included),
  * that use is the right operand (`side == 1`) and the left operand is a
    temporary (a register or, after spilling, a stack slot),
  * the address is a temporary or an `RMem` addressing mode,
  * and the two instructions are adjacent in one block.

The integer `Oxcmp` fold that `foldoperandloads` already performed keeps its
original conditions.

  1. `sameRead`: for any width `w`, any operation result type `α` (a value
     together with the new floating-point status, for instance) and any
     floating-point environment, loading into a temporary and then applying
     the ordered operation equals applying it directly to the memory operand,
     including a read that faults (`none`).
  2. `foldEquiv` / `otherRegisters`: running the two instructions or the folded
     one from any state gives the same memory, the same floating-point
     environment and the same value in every register other than the dead
     load temporary, or faults in both.
  3. `singleUseOtherDistinct`: a load temporary with one use, used as the right
     operand, is not also the left operand (the hypothesis of `foldEquiv`).
  4. `sideOnePreservesOrder`: the memory-source encoding `reg := reg op [m]`
     computes exactly the original `op a t` when `t` is the right operand.
     `sideZeroChangesResult` / `sideZeroCounterexample`: for a left-operand
     load the same encoding computes `op a t` instead of `op t a`, which
     differs for every non-commuting pair; subtraction and division are such
     operations, so `side == 0` is never folded.
  5. `noWritesMemUnchanged` / `deferredReadUnchanged` /
     `adjacentMemoryUnchanged`: instructions without a store or call leave
     memory unchanged and a load writes no memory, so the read performed at
     `b->ins[j]` (nothing in between) sees the bits (or fault) that
     `b->ins[j-1]` would have seen. `storeBetweenCounterexample`: one
     intervening store can change them, so non-adjacent loads are not folded.
  6. `emitOneMem` / `spilledLhsEquiv`: under XMM pressure the spiller may leave
     the left operand of `sub` in a stack slot (`amd64_op[Osub].nmem == 2`);
     the two-address emitters first copy it into the (register) destination,
     so every emitted instruction has at most one memory operand and the pair
     computes `lhs op [m]`.

These are local models: the floating-point operation and the memory read
are arbitrary functions, so the theorems hold for every rounding mode,
NaN payload and exception flag. The encoder correspondence is covered by
`tests/e2e/p119_amd64_fp_rhs_load_fold`.

No imports and no proof holes; plain kernel checks (compatible with both
standalone `lean -DwarningAsError=true` and `scripts/test-lean.sh`).
-/

namespace PionQbeAmd64FpRhsLoadFold

/-! ### 1. One read, then the ordered operation -/

/-- The unfolded pair: read `w` bits into a temporary, then operate. -/
def separate {w : Nat} {Env α : Type} (read : Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → α) (env : Env) (lhs : BitVec w)
    (addr : Nat) : Option α := do
  let temp ← read addr
  pure (op env lhs temp)

/-- The folded instruction: the operation reads its right operand from memory. -/
def folded {w : Nat} {Env α : Type} (read : Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → α) (env : Env) (lhs : BitVec w)
    (addr : Nat) : Option α :=
  (read addr).map (fun rhs => op env lhs rhs)

theorem sameRead {w : Nat} {Env α : Type} (read : Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → α) (env : Env) (lhs : BitVec w)
    (addr : Nat) :
    separate read op env lhs addr = folded read op env lhs addr := by
  unfold separate folded
  cases read addr <;> rfl

/-! ### 2. The whole two-instruction step -/

/-- Machine state: registers by temporary, memory, floating-point environment
    (rounding mode and sticky exception flags). -/
structure St (w : Nat) (M Env : Type) where
  regs : Nat → BitVec w
  mem : M
  env : Env

def upd {w : Nat} (f : Nat → BitVec w) (r : Nat) (v : BitVec w) : Nat → BitVec w :=
  fun x => if x = r then v else f x

/-- `%tmp = load addr; %dst = op %lhs, %tmp`. -/
def runSeparate {w : Nat} {M Env : Type} (read : M → Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → BitVec w × Env) (s : St w M Env)
    (addr lhs tmp dst : Nat) : Option (St w M Env) := do
  let v ← read s.mem addr
  let regs1 := upd s.regs tmp v
  let res := op s.env (regs1 lhs) (regs1 tmp)
  pure { regs := upd regs1 dst res.1, mem := s.mem, env := res.2 }

/-- `%dst = op %lhs, [addr]`. -/
def runFolded {w : Nat} {M Env : Type} (read : M → Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → BitVec w × Env) (s : St w M Env)
    (addr lhs dst : Nat) : Option (St w M Env) := do
  let v ← read s.mem addr
  let res := op s.env (s.regs lhs) v
  pure { regs := upd s.regs dst res.1, mem := s.mem, env := res.2 }

/-- Equal memory, environment and every register except the dead `tmp`. -/
def Agree {w : Nat} {M Env : Type} (tmp : Nat) (a b : St w M Env) : Prop :=
  a.mem = b.mem ∧ a.env = b.env ∧ ∀ r, r ≠ tmp → a.regs r = b.regs r

def OptAgree {w : Nat} {M Env : Type} (tmp : Nat) :
    Option (St w M Env) → Option (St w M Env) → Prop
  | none, none => True
  | some a, some b => Agree tmp a b
  | _, _ => False

theorem otherRegisters {w : Nat} (regs : Nat → BitVec w) (tmp obs : Nat)
    (v : BitVec w) (dead : obs ≠ tmp) : upd regs tmp v obs = regs obs := by
  simp [upd, dead]

theorem foldEquiv {w : Nat} {M Env : Type} (read : M → Nat → Option (BitVec w))
    (op : Env → BitVec w → BitVec w → BitVec w × Env) (s : St w M Env)
    (addr lhs tmp dst : Nat) (hlhs : lhs ≠ tmp) :
    OptAgree tmp (runSeparate read op s addr lhs tmp dst)
      (runFolded read op s addr lhs dst) := by
  unfold runSeparate runFolded
  cases h : read s.mem addr with
  | none => simp [OptAgree]
  | some v =>
    simp only [Option.bind_eq_bind, Option.bind_some, Option.pure_def, OptAgree]
    have hl : upd s.regs tmp v lhs = s.regs lhs := otherRegisters s.regs tmp lhs v hlhs
    have ht : upd s.regs tmp v tmp = v := by simp [upd]
    rw [hl, ht]
    refine ⟨rfl, rfl, ?_⟩
    intro r hr
    unfold upd
    by_cases hd : r = dst
    · simp [hd]
    · simp [hd, hr]

/-! ### 3. The use count separates the operands -/

def countRef (t : Nat) : List Nat → Nat
  | [] => 0
  | x :: xs => (if x = t then 1 else 0) + countRef t xs

/-- `uses[t]` counts at least the two operands of the arithmetic instruction. -/
theorem singleUseOtherDistinct (a0 a1 t uses : Nat)
    (counted : countRef t [a0, a1] ≤ uses) (one : uses = 1) (right : a1 = t) :
    a0 ≠ t := by
  intro h
  subst right
  subst h
  simp [countRef] at counted
  omega

/-! ### 4. Operand order -/

/-- `subs{s,d}` / `divs{s,d}` with a memory source: `reg := reg op [m]`. -/
def memSource {V α : Type} (op : V → V → α) (reg memv : V) : α := op reg memv

/-- Right-operand load (`side == 1`): `%a` is the register, `%t` the memory. -/
theorem sideOnePreservesOrder {V α : Type} (op : V → V → α) (a t : V) :
    memSource op a t = op a t := rfl

/-- Left-operand load (`side == 0`): the only memory-source encoding keeps
    the other operand in the register and so computes `op a t`, not `op t a`. -/
theorem sideZeroChangesResult {V α : Type} (op : V → V → α) (a t : V)
    (noncomm : op t a ≠ op a t) : memSource op a t ≠ op t a :=
  fun h => noncomm h.symm

/-- Concrete witnesses: subtraction and division do not commute. -/
theorem sideZeroCounterexample :
    memSource (fun x y : BitVec 8 => x - y) 1#8 0#8 ≠ (fun x y : BitVec 8 => x - y) 0#8 1#8 ∧
    memSource (fun x y : BitVec 8 => x / y) 1#8 2#8 ≠ (fun x y : BitVec 8 => x / y) 2#8 1#8 := by
  decide

/-! ### 5. Adjacency: nothing writes memory between the load and its use -/

inductive Ins where
  | load (addr : Nat)
  | arith
  | store (addr : Nat) (val : Nat)
  | call

def writes : Ins → Bool
  | .store _ _ => true
  | .call => true
  | _ => false

def step {M : Type} (wr : M → Nat → Nat → M) (callee : M → M) (m : M) : Ins → M
  | .store a v => wr m a v
  | .call => callee m
  | _ => m

def run {M : Type} (wr : M → Nat → Nat → M) (callee : M → M) (m : M) :
    List Ins → M
  | [] => m
  | i :: is => run wr callee (step wr callee m i) is

theorem noWritesMemUnchanged {M : Type} (wr : M → Nat → Nat → M) (callee : M → M)
    (m : M) (between : List Ins) (h : ∀ i ∈ between, writes i = false) :
    run wr callee m between = m := by
  induction between generalizing m with
  | nil => rfl
  | cons i is ih =>
    have hi : writes i = false := h i (List.mem_cons_self ..)
    have hs : step wr callee m i = m := by
      cases i <;> simp_all [writes, step]
    simp only [run, hs]
    exact ih m (fun j hj => h j (List.mem_cons_of_mem _ hj))

/-- Reading after the load and any instructions that neither store nor call
    reads the bits, or the fault, the load itself would have read. -/
theorem deferredReadUnchanged {M V : Type} (wr : M → Nat → Nat → M)
    (callee : M → M) (read : M → Nat → Option V) (m : M) (addr : Nat)
    (between : List Ins) (h : ∀ i ∈ between, writes i = false) :
    read (run wr callee m (.load addr :: between)) addr = read m addr := by
  rw [noWritesMemUnchanged wr callee m (.load addr :: between)]
  intro i hi
  cases hi with
  | head => rfl
  | tail _ hi => exact h i hi

/-- `b->ins[j-1]` and `b->ins[j]` are adjacent: nothing runs in between, so
    the folded read at `b->ins[j]` sees what the load at `b->ins[j-1]` saw. -/
theorem adjacentMemoryUnchanged {M V : Type} (wr : M → Nat → Nat → M)
    (callee : M → M) (read : M → Nat → Option V) (m : M) (addr : Nat)
    (between : List Ins) (adjacent : between = []) :
    read (run wr callee m (.load addr :: between)) addr = read m addr := by
  subst adjacent
  exact deferredReadUnchanged wr callee read m addr [] (fun _ h => nomatch h)

/-- One intervening store to the loaded address can change what is read. -/
theorem storeBetweenCounterexample :
    let wr : (Nat → Nat) → Nat → Nat → (Nat → Nat) :=
      fun m a v x => if x = a then v else m x
    let m0 : Nat → Nat := fun _ => 0
    (run wr id m0 [.load 0, .store 0 7]) 0 ≠ m0 0 := by
  decide

/-! ### 6. High XMM pressure: a spilled left operand -/

inductive Opnd where
  | reg (r : Nat)
  | mem (a : Nat)
  deriving DecidableEq

def isMem : Opnd → Bool
  | .mem _ => true
  | .reg _ => false

/-- Memory operands of one emitted two-operand instruction `src, dst`. -/
def memCount (src dst : Opnd) : Nat :=
  (if isMem src then 1 else 0) + (if isMem dst then 1 else 0)

/-- The two-address emitters (`emitf` `-` templates, `enc_two_addr`):
    copy `a0` into the register destination unless it is already there, then
    `op a1, to`. -/
def emitTwoAddr (to : Nat) (a0 a1 : Opnd) : List (Opnd × Opnd) :=
  (if a0 = .reg to then [] else [(a0, .reg to)]) ++ [(a1, .reg to)]

theorem emitOneMem (to : Nat) (a0 a1 : Opnd) :
    ∀ p ∈ emitTwoAddr to a0 a1, memCount p.1 p.2 ≤ 1 := by
  intro p hp
  have hs : ∀ x : Opnd, memCount x (.reg to) ≤ 1 := by
    intro x
    cases x <;> simp [memCount, isMem]
  unfold emitTwoAddr at hp
  by_cases h : a0 = .reg to
  · simp [h] at hp
    subst hp
    exact hs a1
  · simp [h] at hp
    rcases hp with hp | hp <;> subst hp <;> exact hs _

def val {V : Type} (regs : Nat → V) (mem : Nat → V) : Opnd → V
  | .reg r => regs r
  | .mem a => mem a

/-- Execute the emitted pair: the copy writes the destination register, the
    operation reads it back as its left operand. -/
def execTwoAddr {V : Type} (op : V → V → V) (regs : Nat → V) (mem : Nat → V)
    (to : Nat) (a0 a1 : Opnd) : V :=
  let regs1 : Nat → V := fun x => if x = to then val regs mem a0 else regs x
  op (regs1 to) (val regs1 mem a1)

/-- With the left operand in a stack slot and the right operand the folded
    memory source, the pair computes `slot op [m]`. -/
theorem spilledLhsEquiv {V : Type} (op : V → V → V) (regs : Nat → V)
    (mem : Nat → V) (to slot m : Nat) :
    execTwoAddr op regs mem to (.mem slot) (.mem m) = op (mem slot) (mem m) := by
  simp [execTwoAddr, val]

end PionQbeAmd64FpRhsLoadFold
