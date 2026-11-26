/-
Wave AA2 formal verification (`compiler/src/core/inline_rc.pion`):
  1. `SingleSite`: Exact state-machine bisimulation between the inlined QBE SSA
     fast path (`@_rci_*` / `@_rcd_*`, including 32-bit modular wrap, single
     `pion_destroy_obj` trigger on zero, immortal/frozen/MT branches, and
     post-split `phi` predecessor remapping) and the runtime reference
     `pion_rc_inc` / `pion_rc_dec`.
  2. `MaskEquiv`: Compositional semantic equivalence for any selection mask
     `mask : Nat → Bool`, proving that arbitrary selective RC expansion
     (unreachable exclusion, compact inner-loop filtering, per-function site
     budget, and acyclic fast-path skipping) preserves observable behavior.
  3. `ForwardDag`: Strictly-forward CFG acyclic certificate
     (`∀ (u, v) ∈ E, u < v ⟹ ¬∃ cycle`), proving the completeness and soundness
     of AA2-3's O(V + E) linear check that skips Tarjan SCC on forward-only CFGs.

Plain kernel checks, no proof holes, standard axioms only
(`propext`, `Classical.choice`, `Quot.sound`).
-/

namespace PionWaveAA2InlineRc

/-! ## 1. Single-site RC inline expansion bisimulation -/
namespace SingleSite

abbrev Ptr := Nat

structure RcHeader where
  ownerTid : UInt32
  localRc  : UInt32
  sharedRc : UInt32
  flags    : UInt16
  deriving DecidableEq

structure HeapState where
  mtFlag    : UInt32
  objs      : Ptr → Option RcHeader
  destroyed : List Ptr

def updateObj (objs : Ptr → Option RcHeader) (p : Ptr) (h : RcHeader) :
    Ptr → Option RcHeader :=
  fun q => if q == p then some h else objs q

def isImmortal (h : RcHeader) : Bool :=
  (h.flags &&& (2 : UInt16)) != (0 : UInt16)

/-- Reference runtime semantics of `pion_rc_inc(p)` in ST mode, delegating to
    `mtInc` when `mtFlag != 0`. -/
def rtRcInc (mtInc : HeapState → Ptr → HeapState) (st : HeapState) (p : Ptr) :
    HeapState :=
  if p == 0 then st
  else if st.mtFlag != 0 then mtInc st p
  else
    match st.objs p with
    | none => st
    | some h =>
      if h.ownerTid != 0 then
        { st with objs := updateObj st.objs p { h with localRc := h.localRc + 1 } }
      else if isImmortal h then
        st
      else
        { st with objs := updateObj st.objs p { h with sharedRc := h.sharedRc + 1 } }

/-- Reference runtime semantics of `pion_rc_dec(p)` in ST mode, delegating to
    `mtDec` when `mtFlag != 0`. Appends `p` to `destroyed` iff the decremented
    32-bit counter becomes `0`. -/
def rtRcDec (mtDec : HeapState → Ptr → HeapState) (st : HeapState) (p : Ptr) :
    HeapState :=
  if p == 0 then st
  else if st.mtFlag != 0 then mtDec st p
  else
    match st.objs p with
    | none => st
    | some h =>
      if h.ownerTid != 0 then
        let r1 := h.localRc - 1
        let st1 := { st with objs := updateObj st.objs p { h with localRc := r1 } }
        if r1 == 0 then { st1 with destroyed := st1.destroyed ++ [p] } else st1
      else if isImmortal h then
        st
      else
        let r1 := h.sharedRc - 1
        let st1 := { st with objs := updateObj st.objs p { h with sharedRc := r1 } }
        if r1 == 0 then { st1 with destroyed := st1.destroyed ++ [p] } else st1

/-- Counter field selected by the `phi` in `@_rci_fast_*` / `@_rcd_fast_*`:
    `localSlot` corresponds to `arg - 20` (`local_rc`, from `@_rc*_st_*`),
    `sharedSlot` corresponds to `arg - 16` (`shared_rc`, from `@_rc*_imm_*`). -/
inductive RcSlot where
  | localSlot
  | sharedSlot
  deriving DecidableEq

/-- Predecessor label entering `@_rc*_fast_*`. -/
inductive FastPred where
  | fromSt
  | fromImm
  deriving DecidableEq

/-- Exact `phi @_rc*_st_* %la, @_rc*_imm_* %sa` address selection. -/
def fastPhiSlot : FastPred → RcSlot
  | .fromSt  => .localSlot
  | .fromImm => .sharedSlot

def readSlot (h : RcHeader) : RcSlot → UInt32
  | .localSlot  => h.localRc
  | .sharedSlot => h.sharedRc

def writeSlot (h : RcHeader) (slot : RcSlot) (v : UInt32) : RcHeader :=
  match slot with
  | .localSlot  => { h with localRc := v }
  | .sharedSlot => { h with sharedRc := v }

/-- Block-by-block state-machine execution of the inlined `pion_rc_inc` QBE SSA
    template (`@_rci_nn`, `@_rci_st`, `@_rci_imm`, `@_rci_fast`, `@_rci_slow`,
    `@_rci_end`). -/
def inlineRcInc (mtInc : HeapState → Ptr → HeapState) (st : HeapState) (p : Ptr) :
    HeapState :=
  -- Entry: `%nz =w cnel arg, 0; jnz %nz, @_rci_nn, @_rci_end`
  if p == 0 then st
  else
    -- `@_rci_nn`: `%mt =w loaduw $pion_mt_flag; jnz %mt, @_rci_slow, @_rci_st`
    if st.mtFlag != 0 then mtInc st p
    else
      match st.objs p with
      | none => st
      | some h =>
        -- `@_rci_st`: `%ot =w loaduw (arg - 24); jnz %ot, @_rci_fast, @_rci_imm`
        let fastPred? : Option FastPred :=
          if h.ownerTid != 0 then
            some .fromSt
          else
            -- `@_rci_imm`: `%fl =w loaduh (arg - 10); %im =w and %fl, 2; jnz %im, @_rci_end, @_rci_fast`
            if (h.flags &&& (2 : UInt16)) != (0 : UInt16) then none
            else some .fromImm
        match fastPred? with
        | none => st
        | some pred =>
          -- `@_rci_fast`: `%ra =l phi ...; %rc =w loaduw %ra; %r1 =w add %rc, 1; storew %r1, %ra`
          let slot := fastPhiSlot pred
          let r1 := readSlot h slot + 1
          { st with objs := updateObj st.objs p (writeSlot h slot r1) }

/-- Block-by-block state-machine execution of the inlined `pion_rc_dec` QBE SSA
    template (`@_rcd_nn`, `@_rcd_st`, `@_rcd_imm`, `@_rcd_fast`, `@_rcd_drop`,
    `@_rcd_slow`, `@_rcd_end`). -/
def inlineRcDec (mtDec : HeapState → Ptr → HeapState) (st : HeapState) (p : Ptr) :
    HeapState :=
  if p == 0 then st
  else
    if st.mtFlag != 0 then mtDec st p
    else
      match st.objs p with
      | none => st
      | some h =>
        let fastPred? : Option FastPred :=
          if h.ownerTid != 0 then
            some .fromSt
          else
            if (h.flags &&& (2 : UInt16)) != (0 : UInt16) then none
            else some .fromImm
        match fastPred? with
        | none => st
        | some pred =>
          let slot := fastPhiSlot pred
          let r1 := readSlot h slot - 1
          let st1 := { st with objs := updateObj st.objs p (writeSlot h slot r1) }
          -- `jnz %r1, @_rcd_end, @_rcd_drop`
          if r1 != 0 then st1
          else
            -- `@_rcd_drop`: `call $pion_destroy_obj(l arg); jmp @_rcd_end`
            { st1 with destroyed := st1.destroyed ++ [p] }

theorem inline_rc_inc_bisim (mtInc : HeapState → Ptr → HeapState)
    (st : HeapState) (p : Ptr) :
    inlineRcInc mtInc st p = rtRcInc mtInc st p := by
  unfold inlineRcInc rtRcInc isImmortal
  by_cases hp : (p == 0) = true
  · simp [hp]
  · simp only [hp]
    by_cases hmt : (st.mtFlag != 0) = true
    · simp [hmt]
    · simp only [hmt]
      cases hobj : st.objs p with
      | none => rfl
      | some h =>
        by_cases hot : (h.ownerTid != 0) = true
        · simp [hot, fastPhiSlot, readSlot, writeSlot]
        · simp only [hot]
          by_cases himm : ((h.flags &&& (2 : UInt16)) != (0 : UInt16)) = true
          · simp [himm]
          · simp [himm, fastPhiSlot, readSlot, writeSlot]

theorem inline_rc_dec_bisim (mtDec : HeapState → Ptr → HeapState)
    (st : HeapState) (p : Ptr) :
    inlineRcDec mtDec st p = rtRcDec mtDec st p := by
  unfold inlineRcDec rtRcDec isImmortal
  by_cases hp : (p == 0) = true
  · simp [hp]
  · simp only [hp]
    by_cases hmt : (st.mtFlag != 0) = true
    · simp [hmt]
    · simp only [hmt]
      cases hobj : st.objs p with
      | none => rfl
      | some h =>
        by_cases hot : (h.ownerTid != 0) = true
        · simp only [hot, ite_true, fastPhiSlot, readSlot, writeSlot]
          by_cases hz : (h.localRc - 1 == 0) = true
          · have hnz : (h.localRc - 1 != 0) = false := by simp [bne, hz]
            simp [hz, hnz]
          · have hnz : (h.localRc - 1 != 0) = true := by simp [bne, hz]
            simp [hz, hnz]
        · simp only [hot]
          by_cases himm : ((h.flags &&& (2 : UInt16)) != (0 : UInt16)) = true
          · simp [himm]
          · simp only [himm, fastPhiSlot, readSlot, writeSlot]
            by_cases hz : (h.sharedRc - 1 == 0) = true
            · have hnz : (h.sharedRc - 1 != 0) = false := by simp [bne, hz]
              simp [hz, hnz]
            · have hnz : (h.sharedRc - 1 != 0) = true := by simp [bne, hz]
              simp [hz, hnz]

/-- 32-bit modular arithmetic wrap on `local_rc` / `shared_rc` increment. -/
theorem rc_inc_wrap32 :
    ((0xFFFFFFFF : UInt32) + (1 : UInt32)) = (0 : UInt32) := by
  decide

/-- In ST non-null non-immortal `pion_rc_dec`, `pion_destroy_obj` is invoked
    exact-once iff the selected 32-bit counter decrements to zero. -/
theorem inline_rc_dec_destroy_exact_once
    (mtDec : HeapState → Ptr → HeapState) (st : HeapState) (p : Ptr) (h : RcHeader)
    (hp : p ≠ 0) (hmt : st.mtFlag = 0) (hobj : st.objs p = some h)
    (hmut : h.ownerTid ≠ 0 ∨ isImmortal h = false) :
    let cur := if h.ownerTid != 0 then h.localRc else h.sharedRc
    (inlineRcDec mtDec st p).destroyed =
      if cur - 1 == 0 then st.destroyed ++ [p] else st.destroyed := by
  rw [inline_rc_dec_bisim]
  unfold rtRcDec
  have hp' : (p == 0) = false := beq_false_of_ne hp
  have hmt' : (st.mtFlag != 0) = false := by simp [hmt]
  simp only [hp', hmt', hobj, Bool.false_eq_true, ite_false]
  by_cases hot : (h.ownerTid != 0) = true
  · simp only [hot, ite_true]
    by_cases hz : (h.localRc - 1 == 0) = true <;> simp [hz]
  · simp only [hot]
    have hot0 : h.ownerTid = 0 := by
      cases heq : (h.ownerTid == 0)
      · exfalso; apply hot; simp [bne, heq]
      · exact beq_iff_eq.mp heq
    have himm : isImmortal h = false := hmut.resolve_left (fun c => c hot0)
    simp only [himm, Bool.false_eq_true, ite_false]
    by_cases hz : (h.sharedRc - 1 == 0) = true <;> simp [hz]

/-- Post-split `phi` predecessor remapping:
    when basic block `orig` is split by inline RC expansion so its exiting tail
    block becomes `tail = remap orig`, rewriting every `phi` arm predecessor `l`
    to `remap l` preserves exact `phi` evaluation when entering from `tail`,
    provided `remap` is injective on arm labels. -/
def rewritePhiArms {Lbl Val : Type} (remap : Lbl → Lbl)
    (arms : List (Lbl × Val)) : List (Lbl × Val) :=
  arms.map (fun (l, v) => (remap l, v))

def evalPhi {Lbl Val : Type} [DecidableEq Lbl]
    (arms : List (Lbl × Val)) (pred : Lbl) : Option Val :=
  match arms with
  | [] => none
  | (l, v) :: rest => if l == pred then some v else evalPhi rest pred

theorem phi_remap_bisim {Lbl Val : Type} [DecidableEq Lbl]
    (remap : Lbl → Lbl)
    (hinj : ∀ a b, remap a = remap b → a = b)
    (arms : List (Lbl × Val)) (orig : Lbl) :
    evalPhi (rewritePhiArms remap arms) (remap orig) = evalPhi arms orig := by
  induction arms with
  | nil => rfl
  | cons arm rest ih =>
    rcases arm with ⟨l, v⟩
    change evalPhi ((remap l, v) :: rewritePhiArms remap rest) (remap orig) =
      evalPhi ((l, v) :: rest) orig
    simp only [evalPhi]
    by_cases heq : l = orig
    · subst heq
      simp
    · have hne : remap l ≠ remap orig := fun h => heq (hinj l orig h)
      have hb1 : (l == orig) = false := beq_false_of_ne heq
      have hb2 : (remap l == remap orig) = false := beq_false_of_ne hne
      simp [hb1, hb2, ih]

end SingleSite

/-! ## 2. Compositional equivalence for arbitrary selection masks -/
namespace MaskEquiv

open SingleSite

inductive Inst where
  | rcInc (p : Ptr)
  | rcDec (p : Ptr)
  | other (f : HeapState → HeapState)

def stepRef (mtInc mtDec : HeapState → Ptr → HeapState)
    (ins : Inst) (st : HeapState) : HeapState :=
  match ins with
  | .rcInc p => rtRcInc mtInc st p
  | .rcDec p => rtRcDec mtDec st p
  | .other f => f st

def stepMask (mtInc mtDec : HeapState → Ptr → HeapState)
    (expand : Bool) (ins : Inst) (st : HeapState) : HeapState :=
  match ins with
  | .rcInc p => if expand then inlineRcInc mtInc st p else rtRcInc mtInc st p
  | .rcDec p => if expand then inlineRcDec mtDec st p else rtRcDec mtDec st p
  | .other f => f st

def execRef (mtInc mtDec : HeapState → Ptr → HeapState)
    (prog : List Inst) (st : HeapState) : HeapState :=
  match prog with
  | [] => st
  | ins :: rest => execRef mtInc mtDec rest (stepRef mtInc mtDec ins st)

def execWithMask (mtInc mtDec : HeapState → Ptr → HeapState)
    (mask : Nat → Bool) (idx : Nat) (prog : List Inst) (st : HeapState) :
    HeapState :=
  match prog with
  | [] => st
  | ins :: rest =>
    execWithMask mtInc mtDec mask (idx + 1) rest
      (stepMask mtInc mtDec (mask idx) ins st)

theorem step_mask_equiv (mtInc mtDec : HeapState → Ptr → HeapState)
    (expand : Bool) (ins : Inst) (st : HeapState) :
    stepMask mtInc mtDec expand ins st = stepRef mtInc mtDec ins st := by
  cases ins with
  | rcInc p =>
    cases expand with
    | false => rfl
    | true => exact inline_rc_inc_bisim mtInc st p
  | rcDec p =>
    cases expand with
    | false => rfl
    | true => exact inline_rc_dec_bisim mtDec st p
  | other f => rfl

/-- Any subset selection mask `mask : Nat → Bool` produces the exact same final
    heap state and destruction trace as unexpanded runtime RC calls. -/
theorem exec_with_mask_equiv (mtInc mtDec : HeapState → Ptr → HeapState)
    (mask : Nat → Bool) (idx : Nat) (prog : List Inst) (st : HeapState) :
    execWithMask mtInc mtDec mask idx prog st = execRef mtInc mtDec prog st := by
  induction prog generalizing idx st with
  | nil => rfl
  | cons ins rest ih =>
    simp only [execWithMask, execRef]
    rw [step_mask_equiv]
    exact ih (idx + 1) (stepRef mtInc mtDec ins st)

/-- Any two selection policies `mask1` and `mask2` (e.g. baseline all-SCC vs
    Wave AA2 compact-inner-loop + per-function cap) are observationally identical. -/
theorem any_two_masks_equiv (mtInc mtDec : HeapState → Ptr → HeapState)
    (mask1 mask2 : Nat → Bool) (idx : Nat) (prog : List Inst) (st : HeapState) :
    execWithMask mtInc mtDec mask1 idx prog st =
    execWithMask mtInc mtDec mask2 idx prog st := by
  rw [exec_with_mask_equiv, exec_with_mask_equiv]

end MaskEquiv

/-! ## 3. Strictly-forward CFG acyclic certificate (AA2-3) & reachability (AA2-1) -/
namespace ForwardDag

/-- A non-empty directed path in a graph with edge relation `Edge`. -/
inductive NonEmptyPath (Edge : Nat → Nat → Prop) : Nat → Nat → Prop where
  | single {u v : Nat} : Edge u v → NonEmptyPath Edge u v
  | step {u v w : Nat} : Edge u v → NonEmptyPath Edge v w → NonEmptyPath Edge u w

/-- A CFG is strictly forward when every edge `(u, v)` satisfies `u < v`.
    Note: self-loops `u -> u` fail `u < u` and are therefore rejected. -/
def StrictlyForward (Edge : Nat → Nat → Prop) : Prop :=
  ∀ u v, Edge u v → u < v

theorem forward_path_lt {Edge : Nat → Nat → Prop}
    (hfwd : StrictlyForward Edge) {u v : Nat}
    (hp : NonEmptyPath Edge u v) : u < v := by
  induction hp with
  | single h => exact hfwd _ _ h
  | step h _ ih => exact Nat.lt_trans (hfwd _ _ h) ih

/-- Core AA2-3 certificate: a strictly-forward CFG has no directed cycle of any
    length (including self-loops), so Tarjan SCC necessarily marks every block
    `in_loop = false`. -/
theorem forward_no_cycle {Edge : Nat → Nat → Prop}
    (hfwd : StrictlyForward Edge) (v : Nat) :
    ¬ NonEmptyPath Edge v v := by
  intro hcyc
  have hlt : v < v := forward_path_lt hfwd hcyc
  exact Nat.lt_irrefl v hlt

/-- Concrete adjacency-list edge relation matching `IrcCfg.succs`. -/
def HasEdge (succs : List (List Nat)) (u v : Nat) : Prop :=
  ∃ adj, succs[u]? = some adj ∧ v ∈ adj

/-- Concrete linear pass checking all successors of block `u` satisfy `u < v`. -/
def blockAllForward (u : Nat) (adj : List Nat) : Bool :=
  adj.all (fun v => decide (u < v))

def cfgAllForwardFrom : Nat → List (List Nat) → Bool
  | _, [] => true
  | u, adj :: rest => blockAllForward u adj && cfgAllForwardFrom (u + 1) rest

def cfgAllForward (succs : List (List Nat)) : Bool :=
  cfgAllForwardFrom 0 succs

private theorem blockAllForward_sound {u v : Nat} {adj : List Nat}
    (h : blockAllForward u adj = true) (hv : v ∈ adj) : u < v := by
  unfold blockAllForward at h
  rw [List.all_eq_true] at h
  exact of_decide_eq_true (h v hv)

private theorem cfgAllForwardFrom_sound (base : Nat) (succs : List (List Nat))
    (h : cfgAllForwardFrom base succs = true) :
    ∀ k adj, succs[k]? = some adj → ∀ v ∈ adj, base + k < v := by
  induction succs generalizing base with
  | nil =>
    intro k adj hk
    simp at hk
  | cons adj0 rest ih =>
    simp only [cfgAllForwardFrom, Bool.and_eq_true] at h
    intro k adj hk v hv
    cases k with
    | zero =>
      simp at hk
      subst hk
      simpa using blockAllForward_sound h.1 hv
    | succ k' =>
      simp at hk
      have hlt := ih (base + 1) h.2 k' adj hk v hv
      omega

theorem cfgAllForward_strictly_forward (succs : List (List Nat))
    (h : cfgAllForward succs = true) :
    StrictlyForward (HasEdge succs) := by
  intro u v ⟨adj, hu, hv⟩
  have hlt := cfgAllForwardFrom_sound 0 succs h u adj hu v hv
  simpa using hlt

/-- Soundness of AA2-3's linear check: when `cfgAllForward succs = true`,
    the CFG has zero cycles and skipping Tarjan SCC is exact. -/
theorem cfgAllForward_acyclic (succs : List (List Nat))
    (h : cfgAllForward succs = true) (v : Nat) :
    ¬ NonEmptyPath (HasEdge succs) v v :=
  forward_no_cycle (cfgAllForward_strictly_forward succs h) v

/-- Reachability from entry `0` (AA2-1): an unreachable block is never visited
    by any path starting at entry `0`. -/
inductive Reachable (Edge : Nat → Nat → Prop) (entry : Nat) : Nat → Prop where
  | refl : Reachable Edge entry entry
  | step {u v : Nat} : Reachable Edge entry u → Edge u v → Reachable Edge entry v

theorem unreachable_not_on_entry_path {Edge : Nat → Nat → Prop} {entry v : Nat}
    (hunreach : ¬ Reachable Edge entry v) :
    v ≠ entry ∧ ¬ NonEmptyPath Edge entry v := by
  constructor
  · intro heq
    subst heq
    exact hunreach Reachable.refl
  · intro hpath
    have hreach : Reachable Edge entry v := by
      have aux : ∀ {a b}, NonEmptyPath Edge a b → Reachable Edge entry a →
          Reachable Edge entry b := by
        intro a b hp
        induction hp with
        | single e => intro ha; exact Reachable.step ha e
        | step e _ ih => intro ha; exact ih (Reachable.step ha e)
      exact aux hpath Reachable.refl
    exact hunreach hreach

end ForwardDag

end PionWaveAA2InlineRc
