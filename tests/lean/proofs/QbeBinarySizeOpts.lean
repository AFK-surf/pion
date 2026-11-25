/-
Soundness models for the Opt-Track Z2 output-size changes (regression test
`tests/e2e/p128_binary_size_opts`).

  1. `WasmDeadFn` — `compiler/src/core/wasm.pion` no longer emits the internal
     `__pion_map_hash` helper: every Map hash is already inlined
     (`wasm_emit_map_hash_inline`), so the helper had no incoming call edge.
     Removing it shifts the indices of the later functions down by one.
     `index_roundtrip` / `covers_live` / `avoids_deleted`: the index shift is a
     bijection between the compact module and every surviving slot of the old
     one. `delete_unreachable`: for any step function (calls, returns, indirect
     transfers, memory and imports folded into the state), running the old
     module from a surviving entry produces exactly the trace of the compact
     module, whatever the deleted body did.
  2. `ElfNames` — `vendor/qbe/amd64/elf.c` writes `.rela` immediately before
     the name of every section that has relocations, so the section's
     `sh_name` points into the tail of its relocation section's name.
     `shared_names`: both offsets still read the same NUL-terminated names as
     the separately stored strings, and the table is the same byte sequence.
  3. `ElfLiteralSym` — a non-exported compiler literal (`pion_str_<n>_hdr`,
     `pion_cstr_<n>`) that owns its whole dedicated `.data` input section at
     offset 0 and is referenced only by `S + A` relocations (`R_X86_64_64`,
     `PC32`, `32`, `32S`) is emitted as an `STT_SECTION` symbol of that
     section. `rebased_value` / `rebased_relocation`: also after a partial
     link moves the input section to any offset `delta` of a merged section
     (and its addends by `delta`), these relocations compute the same field
     as through the named symbol, for every 64-bit addend. `got_not_rebased`:
     a GOT-relative relocation is not invariant under that rewrite, so a
     literal it references keeps its name.
  4. `RuntimePool` — `runtime/pion_rt.c` stores its cold panic texts as the
     members of one `struct PionErrors`; call sites pass `offsetof` constants.
     `pooled_diagnostic`: reading from the pool base plus a member's offset
     yields exactly that member's NUL-terminated text, whatever precedes or
     follows it (including padding). `grouped_link`: putting the optional host
     I/O functions into the single input section `.text.pion_io` keeps every
     function reachable from the entry / exported / constructor roots, along
     only kept sections, when the retained set is closed under relocations
     (`--gc-sections`); coarsening the grouping may only keep more.

The correspondence between these models and the C / Pion sources is covered by
the end-to-end test above; the models do not cover the linker or the Wasm VM.
-/
import Std

namespace PionQbeBinarySizeOpts

/-! ## 1. Wasm32: deleting the unreferenced `__pion_map_hash` -/

namespace WasmDeadFn

/-- Old function index of the compact index `i` when the old slot `cut`
    (the deleted helper) is removed. -/
def liftIdx (cut i : Nat) : Nat := if i < cut then i else i + 1

/-- Compact index of a surviving old index. -/
def lowerIdx (cut i : Nat) : Nat := if i < cut then i else i - 1

theorem index_roundtrip (cut i : Nat) : lowerIdx cut (liftIdx cut i) = i := by
  unfold lowerIdx liftIdx
  split <;> (try split) <;> omega

theorem covers_live (cut old : Nat) (h : old ≠ cut) :
    liftIdx cut (lowerIdx cut old) = old := by
  unfold lowerIdx liftIdx
  split <;> (try split) <;> omega

theorem avoids_deleted (cut i : Nat) : liftIdx cut i ≠ cut := by
  unfold liftIdx
  split <;> omega

/-- One observable transition of a function: an event, the index of the next
    function (any call, return or indirect transfer) and the next state
    (frames, memory, imports). -/
abbrev Step (S E : Type) := Nat → S → E × Nat × S

def trace {S E : Type} (step : Step S E) (fuel pc : Nat) (s : S) : List E :=
  match fuel with
  | 0 => []
  | n + 1 =>
    let (e, j, t) := step pc s
    e :: trace step n j t

/-- The old module: the compact module with an arbitrary body re-inserted at
    `cut`; surviving code keeps its effects and refers to lifted indices. -/
def insertFn {S E : Type} (cut : Nat) (dead : S → E × Nat × S) (live : Step S E) :
    Step S E :=
  fun old s =>
    if old = cut then dead s else
      let (e, j, t) := live (lowerIdx cut old) s
      (e, liftIdx cut j, t)

theorem delete_unreachable {S E : Type} (cut : Nat) (dead : S → E × Nat × S)
    (live : Step S E) (fuel i : Nat) (s : S) :
    trace (insertFn cut dead live) fuel (liftIdx cut i) s = trace live fuel i s := by
  induction fuel generalizing i s with
  | zero => rfl
  | succ n ih =>
    simp only [trace, insertFn, avoids_deleted, ite_false, index_roundtrip]
    cases h : live i s with
    | mk e next =>
      rcases next with ⟨j, t⟩
      simp [ih]

end WasmDeadFn

/-! ## 2. ELF64: section names as suffixes of `.rela<name>` -/

namespace ElfNames

/-- `before` is the table so far, `marker` the bytes `.rela`, `terminatedName`
    the section name with its NUL. The section name offset is
    `(before ++ marker).length`, the relocation name offset `before.length`. -/
theorem shared_names (before marker terminatedName after : List UInt8) :
    (((before ++ marker) ++ (terminatedName ++ after)).drop (before ++ marker).length).take
      terminatedName.length = terminatedName ∧
    ((before ++ ((marker ++ terminatedName) ++ after)).drop before.length).take
      (marker ++ terminatedName).length = marker ++ terminatedName ∧
    (before ++ marker) ++ (terminatedName ++ after) =
      before ++ ((marker ++ terminatedName) ++ after) := by
  exact ⟨by simp only [List.drop_left, List.take_left],
    by simp only [List.drop_left, List.take_left], by simp [List.append_assoc]⟩

end ElfNames

/-! ## 3. ELF64: private literals through their section symbol -/

namespace ElfLiteralSym

/-- A partial link (`ld -r`) may put the literal's input section at offset
    `delta` of a merged output section based at `mbase`. A named symbol at
    offset 0 then has the value `mbase + (delta + 0)`; a relocation against the
    section symbol is rewritten to the merged section with addend
    `addend + delta`. Both denote the same `S + A`. -/
theorem rebased_value (mbase delta addend : BitVec 64) :
    (mbase + (delta + 0)) + addend = mbase + (addend + delta) := by
  bv_omega

/-- Hence every relocation that is a function of `S + A` (`R_X86_64_64`,
    `_32`, `_32S`) or of `S + A - P` (`R_X86_64_PC32`) computes the same field
    through the section symbol, before and after any partial link. -/
theorem rebased_relocation {α : Type} (f : BitVec 64 → α)
    (mbase delta addend place : BitVec 64) :
    f ((mbase + (delta + 0)) + addend) = f (mbase + (addend + delta)) ∧
    f ((mbase + (delta + 0)) + addend - place) = f (mbase + (addend + delta) - place) := by
  rw [rebased_value]
  exact ⟨rfl, rfl⟩

/-- A GOT-relative relocation resolves the symbol itself (`GOT(S) + A - P`),
    so rebasing its addend is not sound once `delta ≠ 0`: a symbol loaded via
    the GOT (`R_X86_64_GOTPCREL`) keeps its name (`keep_name` in `elf.c`). -/
theorem got_not_rebased (base addend delta place : BitVec 64) (h : delta ≠ 0) :
    ∃ got : BitVec 64 → BitVec 64,
      got base + (addend + delta) - place ≠ got (base + delta) + addend - place := by
  refine ⟨fun _ => 0, ?_⟩
  intro heq
  apply h
  dsimp only at heq
  bv_omega

end ElfLiteralSym

/-! ## 4. Runtime: pooled panic texts and the grouped I/O section -/

namespace RuntimePool

/-- `previous` is every byte before the member (other texts and any ABI
    padding, i.e. exactly `offsetof`), `terminatedMessage` includes its NUL. -/
theorem pooled_diagnostic (previous terminatedMessage later : List UInt8) :
    ((previous ++ (terminatedMessage ++ later)).drop previous.length).take
       terminatedMessage.length = terminatedMessage := by
  simp

inductive Path {α : Type} (edge : α → α → Prop) : α → α → Prop where
  | refl (a : α) : Path edge a a
  | next {a b c : α} : Path edge a b → edge b c → Path edge a c

/-- A retained section set that contains the roots and is closed under every
    relocation edge keeps every reachable section, along kept sections only. -/
theorem grouped_link {α : Type} {edge : α → α → Prop}
    {root dst : α} (keep : α → Prop) (hr : keep root)
    (closed : ∀ a b, keep a → edge a b → keep b)
    (p : Path edge root dst) :
    keep dst ∧ Path (fun a b => edge a b ∧ keep b) root dst := by
  induction p with
  | refl => exact ⟨hr, .refl _⟩
  | next prev edgeBC ih =>
    obtain ⟨kb, pb⟩ := ih
    have kc := closed _ _ kb edgeBC
    exact ⟨kc, .next pb ⟨edgeBC, kc⟩⟩

end RuntimePool

end PionQbeBinarySizeOpts
