# GAP Benchmark Suite -- PageRank microarchitecture iteration
#
# The upstream targets (build / build-graphs / bench) run the full 27-kernel
# suite and write results to files without printing them. The pagerank-*
# recipes below are the iteration loop: one -march, one core, counters, CSV.

build:
    make

build-graphs:
    make bench-graphs

bench:
    make bench-run

all: build build-graphs bench

# --- PageRank microarchitecture iteration ---------------------------------

# Fast loop: 4M-vertex synthetic graphs, seconds per run.
pagerank march="native":
    bench/run-pagerank.sh --march {{march}} --tier quick

# Number of record: GAPBS's own scale (2^27 vertices). Slow, generates ~17 GB.
pagerank-standard march="native":
    bench/run-pagerank.sh --march {{march}} --tier standard

# One graph only, for a tight edit loop.
pagerank-one march="native" graph="kron" trials="5":
    bench/run-pagerank.sh --march {{march}} --tier quick --graphs {{graph}} --trials {{trials}}

# Build the -march matrix and run each, skipping any this compiler rejects.
pagerank-matrix marches="x86-64-v3 znver4 znver5 sapphirerapids emeraldrapids":
    #!/usr/bin/env bash
    set -uo pipefail
    for m in {{marches}}; do
      if echo 'int main(){return 0;}' | clang++ -march=$m -x c++ - -o /dev/null 2>/dev/null; then
        bench/run-pagerank.sh --march $m --tier quick
      else
        echo "skip $m (unsupported by this clang)" >&2
      fi
    done

# Every result collected so far, one table.
pagerank-summary:
    #!/usr/bin/env bash
    set -euo pipefail
    first=1
    for f in bench/results/*/pagerank.csv; do
      [ -e "$f" ] || continue
      if [ $first = 1 ]; then head -1 "$f"; first=0; fi
      tail -n +2 "$f"
    done | column -s, -t

# Remove built binaries, generated graphs and results.
pagerank-clean:
    rm -rf bench/build bench/graphs bench/results
