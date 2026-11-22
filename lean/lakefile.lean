import Lake
open Lake DSL

-- Aeneas Lean backend (`AeneasVerif/aeneas` @ 1dc8ad31b1, `backends/lean`),
-- linked into `.deps/aeneas` by `scripts/test-lean.sh` (never committed).
require aeneas from "./.deps/aeneas"

package «pionlean» where
  leanOptions := #[⟨`weak.linter.dupNamespace, false⟩]

@[default_target] lean_lib PionLean
