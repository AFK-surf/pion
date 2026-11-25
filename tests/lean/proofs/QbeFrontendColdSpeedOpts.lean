/-
Invariants behind the byte-identical cold-compile frontend optimizations of
Opt-Track T (`compiler/src/core/sig.pion`, `compiler/src/core/types.pion`,
`compiler/src/core/qbe.pion`):

  1. `front_slot_seen`, the hashed `#fmutlink` dedup. It landed on `main`
     independently in #56 (`SigDepCtx.slot_mut_links_seen`,
     `sig_add_slot_mut_link`, shared with callback child contexts like the
     ordered `slot_mut_links` array); this PR keeps that code and proves it
     equal to the linear `sig_union_str_array(links, [s])` it replaced: while
     the map indexes exactly the array (`indexed`), one step appends the same
     strings (`slotLinks_step`, `slotLinks_union_singleton`), any event
     sequence yields the same ordered array (`slotLinks_stable_order`) and the
     emitted `#fmutlink` text is byte-identical (`slotLinks_emitted_bytes`).
  2. `front_plan_once`: on a full check (`check_file == []`)
     `check_package_with_imports_mapped_plan` records the resolved
     `ConstInitPlan` it computes from `pkg` and `tc.resolved_method_calls`
     (also used for `E_CONST_CYCLE`). What runs afterwards, `resolve_eq_uses`,
     reads `tc.eq_uses`, updates `eq_tparams` / `eq_keys` /
     `verify_eq_tparams` / `verify_eq_keys` / `op_tparams` / `op_keys` and
     may append diagnostics, but
     never writes `resolved_method_calls` or the package. So
     `cli_prepare_qbe_units` reusing the recorded plan (recomputing when none
     was recorded), with diagnostics still returned first, returns exactly
     what recomputing returns (`planReuse_checked_plan`;
     `planReuse_resolve_eq_keeps_resolved` for that post phase's shape).
  3. `front_const_rows`: `compute_const_init_plan_from_pkg_tc` replays only
     the `#cdep` rows when every one of them has an empty call column. The
     parser keeps the first record per constant name, also across files
     (`constPlan_scan_project`); without call descriptors no function
     summary can add an edge or set `has_ambiguous_method`
     (`constPlan_empty_calls`), so the shared finishing code (Kahn order,
     cycle path, plan hash) sees identical inputs (`constPlan_finish_project`)
     and the guarded fast path with its fallback always equals the full
     planner (`constPlan_guarded_fast_path`).
  4. `front_loop_fp`: the four `while iter < 64` dependency fixed points
     (`while` / `while let`, C-style `for`, range `for`, `for-in`) carry the
     fingerprint computed at the end of one iteration to the head of the
     next instead of recomputing it from the unchanged state; the visited
     states and the exhaustion flag that selects
     `sig_fallback_dirty_outer_cslots` are identical for every budget
     (`loopFp_same_iterations_and_fallback`), and so is the iteration count
     (`loopFp_same_length`).

No proof holes; only the standard axioms (`scripts/test-lean.sh`).
-/
import Std.Data.HashSet.Lemmas

namespace PionFrontendColdSpeedOpts

/-! ### 1. `front_slot_seen` -/

/-- `slot_mut_links_seen` as a set of strings. -/
abbrev Index := Std.HashSet String

/-- The map holds exactly the strings of the ordered array. -/
def indexed (rows : List String) (index : Index) : Prop :=
  ∀ s : String, s ∈ index ↔ s ∈ rows

/-- `sig_union_str_array(rows, [s])`: linear membership scan, append if new. -/
def linearStep (rows : List String) (s : String) : List String :=
  if s ∈ rows then rows else rows ++ [s]

/-- `sig_union_str_array(rows, extra)` for an arbitrary `extra` array. -/
def unionArray (rows extra : List String) : List String :=
  extra.foldl linearStep rows

/-- `sig_add_slot_mut_link(ctx, s)`. -/
def fastStep (state : List String × Index) (s : String) : List String × Index :=
  if s ∈ state.2 then state else (state.1 ++ [s], state.2.insert s)

theorem slotLinks_union_singleton (rows : List String) (s : String) :
    unionArray rows [s] = linearStep rows s := rfl

theorem slotLinks_step (rows : List String) (index : Index) (s : String)
    (h : indexed rows index) :
    (fastStep (rows, index) s).1 = linearStep rows s ∧
    indexed (fastStep (rows, index) s).1 (fastStep (rows, index) s).2 := by
  by_cases hi : s ∈ index
  · have hr := (h s).mp hi
    simpa [fastStep, linearStep, hi, hr] using h
  · have hr : s ∉ rows := fun x => hi ((h s).mpr x)
    simp only [fastStep, linearStep, hi, hr, ↓reduceIte, true_and]
    intro t
    have ht := h t
    simp only [Std.HashSet.mem_insert, List.mem_append, List.mem_singleton]
    grind

theorem slotLinks_stable_order (events rows : List String) (index : Index)
    (h : indexed rows index) :
    (events.foldl fastStep (rows, index)).1 = events.foldl linearStep rows := by
  induction events generalizing rows index with
  | nil => rfl
  | cons s rest ih =>
    obtain ⟨he, hinv⟩ := slotLinks_step rows index s h
    simp only [List.foldl_cons]
    rw [← he]
    exact ih _ _ hinv

/-- The `#fmutlink` lines `sig_collect_fn_deps` writes from the array. -/
def emit (rows : List String) : String :=
  String.join (rows.map fun s => "#fmutlink " ++ s ++ "\n")

theorem slotLinks_emitted_bytes (events : List String) :
    emit (events.foldl fastStep ([], ∅)).1 = emit (events.foldl linearStep []) := by
  apply congrArg emit
  apply slotLinks_stable_order
  intro s
  simp

/-! ### 2. `front_plan_once` -/

/-- Type-checker state as far as plan reuse is concerned: `resolved` is
`tc.resolved_method_calls` (the only checker field the planner reads), `rest`
stands for every other field (`eq_uses`, `eq_tparams`, `eq_keys`,
`verify_eq_*`, `op_*`, ...), and `diags` the diagnostics. -/
structure Checker (R X D : Type) where
  resolved : R
  rest : X
  diags : List D

/-- The shape of `resolve_eq_uses`: rewrites other fields and may append
diagnostics, leaves `resolved` alone. -/
def resolveEqPost {R X D : Type} (f : X → X) (extra : X → List D) (tc : Checker R X D) :
    Checker R X D :=
  { tc with rest := f tc.rest, diags := tc.diags ++ extra tc.rest }

theorem planReuse_resolve_eq_keeps_resolved {R X D : Type} (f : X → X) (extra : X → List D)
    (tc : Checker R X D) : (resolveEqPost f extra tc).resolved = tc.resolved := rfl

/-- The full check: compute the plan from the package (`files`) and
`resolved`, add its cycle diagnostics, run the post phase; return the final
checker and the recorded plan. -/
def checkFull {F R X D P : Type} (plan : F → R → P) (cycleDiags : P → List D)
    (post : Checker R X D → Checker R X D) (files : F) (tc0 : Checker R X D) :
    Checker R X D × P :=
  let p := plan files tc0.resolved
  (post { tc0 with diags := tc0.diags ++ cycleDiags p }, p)

/-- `cli_prepare_qbe_units` after the check: diagnostics first, then the
recorded plan if there is one, else `compute_const_init_plan_from_pkg_tc`
on the final checker. `recorded = none` is the previous code. -/
def prepareWith {F R X D P A : Type} (plan : F → R → P) (prepare : P → A) (files : F)
    (tc : Checker R X D) (recorded : Option P) : Except (List D) A :=
  if tc.diags.isEmpty then .ok (prepare (recorded.getD (plan files tc.resolved)))
  else .error tc.diags

theorem planReuse_checked_plan {F R X D P A : Type} (plan : F → R → P)
    (cycleDiags : P → List D) (post : Checker R X D → Checker R X D)
    (hpost : ∀ tc, (post tc).resolved = tc.resolved) (prepare : P → A) (files : F)
    (tc0 : Checker R X D) :
    prepareWith plan prepare files (checkFull plan cycleDiags post files tc0).1
        (some (checkFull plan cycleDiags post files tc0).2) =
      prepareWith plan prepare files (checkFull plan cycleDiags post files tc0).1 none := by
  simp only [prepareWith, checkFull, Option.getD_some, Option.getD_none, hpost]

/-! ### 3. `front_const_rows` -/

/-- A parsed `#cdep NAME|reads|calls` record. -/
structure Entry where
  name : String
  reads : List String
  calls : List String
deriving DecidableEq

/-- One line of the per-file resolved summaries. -/
inductive Row where
  | constant (e : Entry)
  | summary (text : String)

def entry : Row → Option Entry
  | .constant e => some e
  | .summary _ => none

/-- `compute_const_init_plan_from_sigs` keeps the first record of each name
(`if !const_idx.contains(cname)`), across file boundaries; other lines feed
only the function / callback tables. -/
def scan (seen : List String) : List Row → List Entry
  | [] => []
  | .summary _ :: xs => scan seen xs
  | .constant e :: xs =>
    if e.name ∈ seen then scan seen xs else e :: scan (e.name :: seen) xs

/-- The rows `front_const_rows` keeps (`constant_rows`). -/
def project (rows : List Row) : List Row :=
  (rows.filterMap entry).map Row.constant

theorem constPlan_scan_project (rows : List Row) (seen : List String) :
    scan seen (project rows) = scan seen rows := by
  unfold project
  induction rows generalizing seen with
  | nil => rfl
  | cons row xs ih =>
    cases row with
    | summary _ => exact ih seen
    | constant e =>
      by_cases h : e.name ∈ seen <;> simp [entry, scan, h, ih]

theorem scan_mem (rows : List Row) (seen : List String) (e : Entry)
    (h : e ∈ scan seen rows) : Row.constant e ∈ rows := by
  induction rows generalizing seen with
  | nil => simp [scan] at h
  | cons row xs ih =>
    cases row with
    | summary _ => exact List.mem_cons_of_mem _ (ih seen h)
    | constant e' =>
      by_cases hs : e'.name ∈ seen
      · simp only [scan, hs, ↓reduceIte] at h
        exact List.mem_cons_of_mem _ (ih seen h)
      · simp only [scan, hs, ↓reduceIte, List.mem_cons] at h
        rcases h with h | h
        · subst h; exact List.mem_cons_self
        · exact List.mem_cons_of_mem _ (ih _ h)

/-- Edges of one constant: direct reads plus whatever the function tables add
for each call descriptor. -/
def edges (resolve : String → List String) (e : Entry) : List String :=
  e.reads ++ e.calls.flatMap resolve

/-- `has_ambiguous_method` contributions come only from call descriptors. -/
def ambiguous (resolve : String → Bool) (e : Entry) : Bool := e.calls.any resolve

theorem constPlan_empty_calls (entries : List Entry) (h : ∀ e ∈ entries, e.calls = [])
    (resolve₁ resolve₂ : String → List String) (amb₁ amb₂ : String → Bool) :
    entries.map (edges resolve₁) = entries.map (edges resolve₂) ∧
    entries.map (ambiguous amb₁) = entries.map (ambiguous amb₂) := by
  constructor <;> apply List.map_congr_left <;> intro e he <;>
    simp [edges, ambiguous, h e he]

/-- The finishing code is shared by both paths: it resolves reads to constant
indices, runs the stable Kahn sort, finds the cycle path and hashes. -/
theorem constPlan_finish_project {α : Type} (rows : List Row)
    (h : ∀ e ∈ scan [] rows, e.calls = [])
    (resolve₁ resolve₂ : String → List String) (amb₁ amb₂ : String → Bool)
    (finish : List String → List (List String) → List Bool → α) :
    let original := scan [] rows
    let projected := scan [] (project rows)
    finish (original.map Entry.name) (original.map (edges resolve₁))
      (original.map (ambiguous amb₁)) =
    finish (projected.map Entry.name) (projected.map (edges resolve₂))
      (projected.map (ambiguous amb₂)) := by
  simp only [constPlan_scan_project]
  obtain ⟨he, ha⟩ := constPlan_empty_calls _ h resolve₁ resolve₂ amb₁ amb₂
  rw [he, ha]

/-- The full planner over every summary line, with the function tables built
from those lines (`resolveOf rows`, `ambOf rows`). -/
def planFull {α : Type} (resolveOf : List Row → String → List String)
    (ambOf : List Row → String → Bool)
    (finish : List String → List (List String) → List Bool → α) (rows : List Row) : α :=
  let es := scan [] rows
  finish (es.map Entry.name) (es.map (edges (resolveOf rows))) (es.map (ambiguous (ambOf rows)))

/-- `compute_const_init_plan_from_pkg_tc` after the change: replay the `#cdep`
rows only when every one (duplicates included) has an empty call column,
otherwise fall back to the full planner. -/
def planGuarded {α : Type} (resolveOf : List Row → String → List String)
    (ambOf : List Row → String → Bool)
    (finish : List String → List (List String) → List Bool → α) (rows : List Row) : α :=
  if (rows.filterMap entry).all (fun e => e.calls.isEmpty) then
    planFull resolveOf ambOf finish (project rows)
  else planFull resolveOf ambOf finish rows

theorem constPlan_guarded_fast_path {α : Type} (resolveOf : List Row → String → List String)
    (ambOf : List Row → String → Bool)
    (finish : List String → List (List String) → List Bool → α) (rows : List Row) :
    planGuarded resolveOf ambOf finish rows = planFull resolveOf ambOf finish rows := by
  unfold planGuarded
  split
  · rename_i hall
    have h : ∀ e ∈ scan [] rows, e.calls = [] := by
      intro e he
      have hm := scan_mem rows [] e he
      have hf : e ∈ rows.filterMap entry := List.mem_filterMap.mpr ⟨_, hm, rfl⟩
      have := List.all_eq_true.mp hall e hf
      simpa using this
    exact (constPlan_finish_project rows h _ _ _ _ finish).symm
  · rfl

/-! ### 4. `front_loop_fp` -/

/-- Previous loop: the fingerprint is recomputed at the head of every
iteration. The flag records exhaustion of the budget (the fallback). -/
def scanned {S K : Type} [DecidableEq K] (step : S → S) (fingerprint : S → K) :
    Nat → S → List S × Bool
  | 0, _ => ([], true)
  | fuel + 1, before =>
    let after := step before
    if fingerprint after = fingerprint before then ([after], false)
    else
      let result := scanned step fingerprint fuel after
      (after :: result.1, result.2)

/-- New loop: the fingerprint is computed once before the loop and carried
along the back edge (`fp_before = fp_after`). -/
def carried {S K : Type} [DecidableEq K] (step : S → S) (fingerprint : S → K) :
    Nat → S → K → List S × Bool
  | 0, _, _ => ([], true)
  | fuel + 1, before, previous =>
    let after := step before
    let current := fingerprint after
    if current = previous then ([after], false)
    else
      let result := carried step fingerprint fuel after current
      (after :: result.1, result.2)

theorem loopFp_same_iterations_and_fallback {S K : Type} [DecidableEq K]
    (step : S → S) (fingerprint : S → K) (fuel : Nat) (before : S) :
    carried step fingerprint fuel before (fingerprint before) =
      scanned step fingerprint fuel before := by
  induction fuel generalizing before with
  | zero => rfl
  | succ fuel ih =>
    simp only [carried, scanned]
    by_cases h : fingerprint (step before) = fingerprint before
    · simp [h]
    · simp [h, ih]

theorem loopFp_same_length {S K : Type} [DecidableEq K]
    (step : S → S) (fingerprint : S → K) (fuel : Nat) (before : S) :
    (carried step fingerprint fuel before (fingerprint before)).1.length =
      (scanned step fingerprint fuel before).1.length := by
  rw [loopFp_same_iterations_and_fallback]

end PionFrontendColdSpeedOpts
