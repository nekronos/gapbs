#!/usr/bin/env bash
# Achieved MLP per GAPBS kernel on one graph, single core.
# Same setup-subtraction as run-pagerank.sh: N-trial minus 1-trial run.
set -uo pipefail
cd "$(dirname "$0")/.."
MARCH=${MARCH:-native}; CPU=${CPU:-1}; NODE=${NODE:-0}; SCALE=${SCALE:-22}
B="bench/build/$MARCH"; G="bench/graphs"
CXXFLAGS="-std=c++11 -O3 -Wall -g -fno-omit-frame-pointer -march=$MARCH"

mkdir -p "$B" "$G"
for k in bfs pr pr_spmv cc cc_sv bc sssp tc converter; do
  [[ -x "$B/$k" ]] || clang++ $CXXFLAGS src/$k.cc -o "$B/$k"
done
[[ -f "$G/kron-g$SCALE.sg"  ]] || "$B/converter" -g$SCALE -k16 -b  "$G/kron-g$SCALE.sg"  >/dev/null
[[ -f "$G/kron-g$SCALE.wsg" ]] || "$B/converter" -g$SCALE -k16 -wb "$G/kron-g$SCALE.wsg" >/dev/null

EV=cycles,instructions,L1D_PEND_MISS.PENDING,L1D_PEND_MISS.PENDING_CYCLES
T=$(mktemp); trap 'rm -f "$T"' EXIT
run() { # $1=binary $2=args-with-trials
  perf stat -x, --no-big-num --output "$T" -e "$EV" \
    -- taskset -c $CPU numactl --membind=$NODE $1 $2 >/dev/null 2>&1
  awk -F, 'NF>=3 && $1 ~ /^[0-9]+$/ {printf "%s ", $1}' "$T"
}

printf "%-10s %-8s %8s %7s %7s %12s\n" kernel graph mlp ipc pct_miss sec_per_trial
for spec in \
  "bfs   kron-g$SCALE.sg   -n%d" \
  "pr    kron-g$SCALE.sg   -i1000 -t1e-4 -n%d" \
  "pr_spmv kron-g$SCALE.sg -i1000 -t1e-4 -n%d" \
  "cc    kron-g$SCALE.sg   -n%d" \
  "cc_sv kron-g$SCALE.sg   -n%d" \
  "bc    kron-g$SCALE.sg   -i4 -n%d" \
  "sssp  kron-g$SCALE.wsg  -d2 -n%d" \
  "tc    kron-g$SCALE.sg   -n%d" ; do
  set -- $spec; k=$1; gf=$2; shift 2; argt="$*"
  # KERNELS="bfs pr" restricts the sweep -- tc alone is ~9 minutes.
  if [[ -n "${KERNELS:-}" ]]; then [[ " $KERNELS " == *" $k "* ]] || continue; fi
  N=${TRIALS:-6}; [[ $k == tc ]] && N=2
  # Bash substitution, not printf: the arg strings begin with "-i"/"-d"/"-n",
  # which printf parses as its own options and then emits nothing.
  aN=${argt//%d/$N}; a1=${argt//%d/1}
  sec=$(taskset -c $CPU numactl --membind=$NODE "$B/$k" -f "$G/$gf" $aN 2>/dev/null \
        | sed -n 's/^Average Time: *//p')
  read -r cN iN pN pcN <<<"$(run "$B/$k" "-f $G/$gf $aN")"
  read -r c1 i1 p1 pc1 <<<"$(run "$B/$k" "-f $G/$gf $a1")"
  awk -v k="$k" -v g="${gf%%-*}" -v sec="${sec:-0}" \
      -v c=$((cN-c1)) -v i=$((iN-i1)) -v p=$((pN-p1)) -v pc=$((pcN-pc1)) \
    'BEGIN{ printf "%-10s %-8s %8.2f %7.3f %6.1f%% %12s\n", k, g,
              (c>0?p/c:0), (c>0?i/c:0), (c>0?100*pc/c:0), sec }'
done
