# Third-Party Notices

This repository includes or references the following third-party components.

## Vendored Components

### QBE (`vendor/qbe/`)
- **Upstream**: QBE 1.3 (<https://c9x.me/compile/>)
- **License**: MIT License
- **Copyright**: `© 2015-2026 Quentin Carbonneaux <quentin@c9x.me>`
- **Modifications**: Contains local Pion modifications for ARM64/Mach-O and ELF64 direct object emission, hardware `sqrt` lowering, and peephole optimizations.
- **Full license text**: [`vendor/qbe/LICENSE`](vendor/qbe/LICENSE) (also distributed in release archives as `share/pion/licenses/QBE-LICENSE`).

## Referenced Benchmarks

### Classic Benchmark Algorithms (`benchmarks/`)
- **Reference**: Classic benchmark kernels (e.g., `nbody`, `binarytrees`, `spectralnorm`, `fannkuchredux`, `mandelbrot`) follow problem specifications from The Computer Language Benchmarks Game (BSD-3-Clause) and are independently reimplemented in this project across Pion and comparison languages.

## External Test/Verification Dependencies (Not Vendored)

### Formal Verification (`lean/`)
The Lean 4 formalization under `lean/` fetches the following external dependencies on demand during testing/verification; they are not vendored into this repository:
- **`AeneasVerif/aeneas`**: Apache License 2.0
- **`mathlib4`**: Apache License 2.0
