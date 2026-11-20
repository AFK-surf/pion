# benchmarks/agent_eval

Objective, one-command comparison of how friendly **Pion**, **MoonBit**, **Rust** and **Go** are to an AI coding
agent. `sh benchmarks/agent_eval/run.sh` (on a machine with `moon`, `cargo`, `go`, `clang`, `python3`) builds
`out/pionc2` when missing, runs the three dimensions and writes `results.json` + `SUMMARY.md` here.

| path | content |
|---|---|
| `tasks/tNN_*/` | 12 engineering tasks: `prompt.md`, `expected.txt`, and one project per language (`pion/`, `moonbit/`, `rust/`, `go/`) whose program prints `expected.txt` and whose unit tests pass |
| `errors/eNN_*/` | 12 agent error classes: one minimal broken project per language + `expect.json` (verified outcome and the diagnostic it must match) |
| `tools/agent_eval.py` | harness (`dim1`, `dim2`, `dim3`, `report`); all build products go to `out/agent_eval/` |
| `tools/metrics.py` | effective LOC, bytes, bytes/4 and lexical-token counts |
| `tools/report.py` | builds the `summary` block and `SUMMARY.md` from measured data |
| `tools/build_pionc2.sh` | minimal pionc0 -> pionc1 -> pionc2 bootstrap into `out/` |

Dimension 2 compares each probe's outcome with `expect.json`; a mismatch fails the run, so a probe that
fails for an unrelated reason cannot be counted as "caught".
