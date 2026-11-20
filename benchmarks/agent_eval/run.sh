#!/bin/sh
# One-command reproduction of the agent_eval suite (m2 vs MoonBit vs Rust vs Go).
#   sh benchmarks/agent_eval/run.sh            # all three dimensions + report
#   RUNS=5 sh benchmarks/agent_eval/run.sh     # timed runs per measurement (after 1 warmup)
# Builds out/m2c2 first when it is missing. Writes benchmarks/agent_eval/results.json
# and SUMMARY.md; every other artefact stays under out/agent_eval (git-ignored).
set -u
export PATH="$HOME/.moon/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:$PATH"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
RUNS="${RUNS:-5}"

for tool in moon cargo go clang python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "missing tool: $tool" >&2; exit 2; }
done
if [ ! -x "$ROOT/out/m2c2" ] || [ ! -x "$ROOT/out/qbe" ] || [ ! -f "$ROOT/out/libm2rt.a" ]; then
  sh "$HERE/tools/build_m2c2.sh" || exit 2
fi

RC=0
python3 "$HERE/tools/agent_eval.py" dim1 || RC=1
python3 "$HERE/tools/agent_eval.py" dim2 --runs "$RUNS" || RC=1
python3 "$HERE/tools/agent_eval.py" dim3 --runs "$RUNS" || RC=1
python3 "$HERE/tools/agent_eval.py" report --runs "$RUNS" || RC=1
if [ "$RC" -ne 0 ]; then
  echo "agent_eval: at least one gate failed (see results.json)" >&2
fi
exit "$RC"
