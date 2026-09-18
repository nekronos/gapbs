#!/usr/bin/env bash
# Run the PageRank benchmark across graphs at one -march, single-core, with
# microarchitectural counters. Built for A/B iteration: every run is stamped
# with the build and machine state it was taken under, because a number is
# only comparable to one taken with the byte-identical command.
#
#   bench/run-pagerank.sh --march znver5 --tier quick
#
# Defaults are the fast-turnaround tier. Use --tier standard for GAPBS's own
# scale (-g27) once a change looks worth measuring properly.
set -euo pipefail
cd "$(dirname "$0")/.."

MARCH=native
TIER=quick
TRIALS=16
CPU=1
NODE=0
CXX_BIN=clang++
GRAPHS=""
TAG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --march)   MARCH=$2; shift 2 ;;
    --tier)    TIER=$2; shift 2 ;;
    --trials)  TRIALS=$2; shift 2 ;;
    --cpu)     CPU=$2; shift 2 ;;
    --node)    NODE=$2; shift 2 ;;
    --cxx)     CXX_BIN=$2; shift 2 ;;
    --graphs)  GRAPHS=$2; shift 2 ;;
    --tag)     TAG=$2; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

case $TIER in
  quick)    SCALE=24 ;;   # 16.8M vertices -- clears 32 MiB L3 by ~40x, and the
                          # Zen 4 96 MiB V-Cache CCD by ~13x. g22 was sized for a
                          # 260 MiB Intel L3 and is only 1.2x there.
  standard) SCALE=27 ;;   # 134M vertices -- GAPBS's own benchmark scale
  *) echo "unknown tier: $TIER (quick|standard)" >&2; exit 2 ;;
esac
[[ -n "$GRAPHS" ]] || GRAPHS="kron urand"   # synthetic only: no multi-GB downloads
[[ -n "$TAG" ]] || TAG="${MARCH}-${TIER}"

BUILD="bench/build/${MARCH}"
GRAPHDIR="bench/graphs"
OUT="bench/results/${TAG}"
mkdir -p "$BUILD" "$GRAPHDIR" "$OUT"

# Serial build: OpenMP thread scheduling swamps microarchitectural effects, and
# per-core capacity is not additive anyway, so the core is measured alone.
CXXFLAGS="-std=c++11 -O3 -Wall -g -fno-omit-frame-pointer -march=${MARCH}"
echo "building pr at -march=${MARCH} (serial)" >&2
$CXX_BIN $CXXFLAGS src/pr.cc -o "$BUILD/pr"
[[ -x "$BUILD/converter" ]] || $CXX_BIN $CXXFLAGS src/converter.cc -o "$BUILD/converter"

for g in $GRAPHS; do
  f="$GRAPHDIR/${g}-g${SCALE}.sg"
  if [[ ! -f "$f" ]]; then
    echo "generating $f" >&2
    case $g in
      kron)  "$BUILD/converter" -g$SCALE -k16 -b "$f" >/dev/null ;;
      urand) "$BUILD/converter" -u$SCALE -k16 -b "$f" >/dev/null ;;
      *)     echo "no generator for '$g' -- real-world graphs need benchmark/graphs/$g.sg" >&2; exit 2 ;;
    esac
  fi
done

# Provenance: what this number is only comparable against.
{
  echo "date:      $(date -Is)"
  echo "host:      $(hostname)"
  echo "cpu:       $(lscpu | sed -n 's/^Model name: *//p' | head -1)"
  echo "commit:    $(git rev-parse --short HEAD)$(git diff --quiet || echo ' (DIRTY)')"
  echo "compiler:  $($CXX_BIN --version | head -1)"
  echo "cxxflags:  $CXXFLAGS"
  echo "march:     $MARCH"
  echo "tier:      $TIER (scale $SCALE)"
  echo "trials:    $TRIALS"
  echo "pinned:    cpu $CPU, numa node $NODE"
  echo "governor:  $(cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "thp:       $(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
  echo "smt:       $(cat /sys/devices/system/cpu/smt/control 2>/dev/null || echo n/a)"
} | tee "$OUT/provenance.txt" >&2

GOV=$(cat /sys/devices/system/cpu/cpu$CPU/cpufreq/scaling_governor 2>/dev/null || echo unknown)
if [[ "$GOV" != "performance" ]]; then
  echo "WARNING: cpu$CPU governor is '$GOV', not 'performance'. Frequency will" >&2
  echo "         drift between runs and A/B deltas may be governor noise, not" >&2
  echo "         microarchitecture. Fix: cpupower -c $CPU frequency-set -g performance" >&2
fi

GA=cycles,instructions,L1D_PEND_MISS.PENDING,L1D_PEND_MISS.PENDING_CYCLES
GB=cycles,branches,branch-misses,LLC-load-misses
PERFTMP=$(mktemp); trap 'rm -f "$PERFTMP"' EXIT

# Counters over N trials. Setup (graph read) is subtracted by differencing an
# N-trial run against a 1-trial run, so what remains is per-trial work only.
counters() { # $1=events $2=trials $3=graphfile
  perf stat -x, --no-big-num --output "$PERFTMP" -e "$1" \
    -- taskset -c "$CPU" numactl --membind="$NODE" \
       "$BUILD/pr" -f "$3" -i1000 -t1e-4 -n"$2" >/dev/null 2>&1 || true
  awk -F, 'NF>=3 && $1 ~ /^[0-9]+$/ {
             if ($6!="" && $6+0 < 99.9) print "MULTIPLEX " $3 > "/dev/stderr"
             printf "%s ", $1 }' "$PERFTMP"
}

CSV="$OUT/pagerank.csv"
echo "march,tier,graph,nodes,edges,iters,trials,avg_time_s,min_trial_s,cycles_per_edge_iter,ns_per_edge_iter,ipc,mlp_uncond,pct_cyc_miss,llc_mpki,branch_miss_rate" > "$CSV"

for g in $GRAPHS; do
  f="$GRAPHDIR/${g}-g${SCALE}.sg"
  echo "running pagerank on $g (scale $SCALE)" >&2

  raw=$(taskset -c "$CPU" numactl --membind="$NODE" \
        "$BUILD/pr" -f "$f" -i1000 -t1e-4 -n"$TRIALS" 2>/dev/null)
  nodes=$(echo "$raw" | sed -n 's/^Graph has \([0-9]*\) nodes.*/\1/p')
  edges=$(echo "$raw" | sed -n 's/^Graph has [0-9]* nodes and \([0-9]*\) .*/\1/p')
  avg=$(echo "$raw"  | sed -n 's/^Average Time: *//p')
  mint=$(echo "$raw" | sed -n 's/^Trial Time: *//p' | sort -g | head -1)
  iters=$(taskset -c "$CPU" numactl --membind="$NODE" \
          "$BUILD/pr" -f "$f" -i1000 -t1e-4 -n1 -l 2>/dev/null \
          | grep -cE '^ *[0-9]+ ')

  read -r cN iN pN pcN <<<"$(counters $GA "$TRIALS" "$f")"
  read -r c1 i1 p1 pc1 <<<"$(counters $GA 1 "$f")"
  read -r dN bN bmN lmN  <<<"$(counters $GB "$TRIALS" "$f")"
  read -r d1 b1 bm1 lm1  <<<"$(counters $GB 1 "$f")"

  awk -v m="$MARCH" -v t="$TIER" -v g="$g" -v n="$nodes" -v e="$edges" -v tr="$TRIALS" -v it="$iters" \
      -v avg="$avg" -v mint="$mint" \
      -v c=$((cN-c1)) -v i=$((iN-i1)) -v p=$((pN-p1)) -v pc=$((pcN-pc1)) \
      -v b=$((bN-b1)) -v bm=$((bmN-bm1)) -v lm=$((lmN-lm1)) -v tn=$((TRIALS-1)) \
    'BEGIN{
       ed = e*it*tn;          # edges touched per trial x trials measured
       printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%.3f,%.3f,%.3f,%.3f,%.1f,%.2f,%.5f\n",
         m,t,g,n,e,it,tr,avg,mint,
         (ed>0?c/ed:0), (e*it>0?avg*1e9/(e*it):0), (c>0?i/c:0),
         (c>0?p/c:0), (c>0?100*pc/c:0), (i>0?1000*lm/i:0), (b>0?bm/b:0) }' >> "$CSV"
done

echo >&2
column -s, -t < "$CSV"
echo >&2; echo "results: $CSV" >&2
