/-
`#eval` / `#guard` of extracted code (run by `scripts/test-lean.sh` with
`lake env lean Eval.lean`): the extracted definitions — `Aeneas.Std.loop`
loops and `partial_fixpoint` recursion included — are executable, and agree
with the native semantics of the same Pion functions.
-/
import Algos.Funs
open Aeneas Aeneas.Std Result Pion

namespace PionEval

def i (x : Int) : Std.I32 := ⟨BitVec.ofInt _ x⟩
def arr (l : List Int) : Pion.Array Std.I32 := ⟨l.map i⟩

/-- `r` evaluates to `ok v` with `v == expected`. -/
def okIs {α : Type} [BEq α] (r : Result α) (expected : α) : Bool := r.reducesTo expected

def rmap {α β : Type} (r : Result α) (f : α → β) : Result β := do
  let x ← r
  ok (f x)

/-- `r` fails (`fail e`). -/
def fails {α : Type} (r : Result α) : Bool :=
  match r.match with
  | .vis (.fail _) _ => true
  | _ => false

#guard okIs (algos.sum (arr [1, 2, 3])) (i 6)
#guard okIs (algos.sum (arr [])) (i 0)
#guard okIs (algos.avg2 (i 7) (i 9)) (i 8)
#guard okIs (algos.binary_search (arr [1, 3, 5, 7, 9]) (i 7)) (some (i 3))
#guard okIs (algos.binary_search (arr [1, 3, 5, 7, 9]) (i 4)) none
#guard okIs (algos.insertion_sort (arr [5, 2, 9, 1, 5])) (arr [1, 2, 5, 5, 9])
#guard okIs (algos.find_first_neg (arr [1, 2, -3, 4])) (i 2)
#guard okIs (algos.swap (i 1) (i 2)) (i 2, i 1)
#guard okIs (algos.sum_inclusive (i 4)) (i 10)
#guard okIs (algos.sum_inclusive (i (-1))) (i 0)
#guard okIs (algos.classify (i 0)) (i 0)
#guard okIs (algos.classify (i 1)) (i 10)
#guard okIs (algos.classify (i (-5))) (i (-1))
#guard okIs (algos.classify (i 7)) (i 100)
#guard okIs (algos.first_pos ⟨[none, some (i (-1)), some (i 4), some (i 2)]⟩) (i 4)
#guard okIs (algos.first_pos ⟨[]⟩) (i (-1))
#guard okIs (algos.«fun» (i 3) (i 4)) (i 14)
#guard okIs (algos.shift_mix (i 5) (i 1)) (i 2)
#guard okIs (algos.eval (.Add (.Lit (i 2)) (.Neg (.Lit (i 5))))) (i (-3))
#guard okIs (algos.tree_sum (.Node (.mk ⟨[.Leaf (i 1), .Node (.mk ⟨[.Leaf (i 2)]⟩), .Leaf (i 3)]⟩))) (i 6)
#guard okIs (algos.is_even (i 10)) true
#guard okIs (algos.is_odd (i 7)) true
#guard okIs (algos.count_red ⟨[.Red, .Green, .Red]⟩) (i 2)
#guard okIs (algos.div_sum (i 12) (i 3) (i 4)) (.Ok (i 7))
#guard okIs (algos.div_sum (i 1) (i 0) (i 1)) (.Err "division by zero")
#guard okIs (rmap (algos.grow_rect ⟨⟨i 0, i 0⟩, ⟨i 2, i 3⟩, arr []⟩) Prod.fst) (i 20)
#guard okIs (rmap (algos.move_rect ⟨⟨i 1, i 2⟩, ⟨i 3, i 4⟩, arr []⟩ (i 10)) (fun r => (r.lo.x, r.lo.y, r.hi.x, r.hi.y, r.tags)))
  (i 11, i 4, i 13, i 2, arr [10])
#guard okIs (rmap (vlib.Acc.record ⟨i 1, arr []⟩ (i 5)) (fun a => (a.total, a.hist))) (i 6, arr [5])
#guard okIs (vlib.rev_ends (arr [1, 2, 3])) (arr [3, 2, 1])
-- `#verify` runtime checks (division by zero, `MIN / -1`, `MIN % -1`, shift range).
#guard fails (vlib.safe_div (i 1) (i 0))
#guard fails (vlib.safe_div (i (-2147483648)) (i (-1)))
#guard fails (vlib.safe_rem ⟨BitVec.ofInt _ (-9223372036854775808)⟩ ⟨BitVec.ofInt _ (-1)⟩)
#guard fails (vlib.shl (i 1) (i 32))
#guard okIs (vlib.shl (i 3) (i 4)) (i 48)
#guard fails (algos.sum (⟨(List.range 3).map (fun _ => i 1)⟩)) == false
-- A longer loop (10^5 iterations through `Aeneas.Std.loop`).
#guard okIs (algos.sum ⟨(List.range 100000).map (fun _ => i 1)⟩) (i 100000)

-- `misc`: `..base`, tuple destructuring, named / default / optional
-- arguments, constants (pure and monadic), `to_int64`, leading-dot `==`,
-- `String` `+` / `length`, `FixedArray` literal / index / length.
--   q = (1 + 100, 2); w = (101 * 3 + 1) + (2 * 2 + 0) + 50 = 358
--   big = 358 * 3 = 1074; n = "ab!".length() = 3; total = 1 + 3 + 3 = 7
#guard okIs (algos.misc ⟨i 1, i 2⟩ .Red "ab") (i 7, ⟨BitVec.ofInt _ 1074⟩, true)
#guard okIs algos.HALF (i 50)
#guard algos.LIMIT == i 100

#eval IO.println "PionEval: all #guard checks passed"

end PionEval
