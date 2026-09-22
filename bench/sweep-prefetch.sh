#!/usr/bin/env bash
# Sweep the prefetch distance, cycles only, at a chosen tier.
#
#   bench/sweep-prefetch.sh --tier standard --dists "0 4 8 16 32 64"
#
# Finding the SHAPE of the D curve needs wall time and cycles, not the full
# counter set -- one run per point instead of five. That is what makes sweeping
# at g27 affordable, which matters because D is a timing parameter: it is tuned
# against miss latency and miss density, and both differ by scale. A D tuned at
# a smaller tier has no claim to being right at the real one.
#
# Take the best two or three points from here and re-run them through
# run-zen.sh for the full counters and the reference machine.
set -euo pipefail
cd "$(dirname "$0")/.."
HOSTS_CONF="$(dirname "$0")/hosts.conf"
[[ -f $HOSTS_CONF ]] || { echo "missing $HOSTS_CONF" >&2; exit 2; }
# shellcheck disable=SC1090
source "$HOSTS_CONF"

TIER=standard; DISTS="0 4 8 16 32 64"; GRAPHS="kron urand"; TRIALS=4
HOST=zen5; MARCH=znver5; CPU=8; HINT=3; FLAT=0; KERNEL=pr; TAG=""
while [[ $# -gt 0 ]]; do case $1 in
  --tier) TIER=$2; shift 2 ;;    --dists) DISTS=$2; shift 2 ;;
  --graphs) GRAPHS=$2; shift 2 ;; --trials) TRIALS=$2; shift 2 ;;
  --host) HOST=$2; shift 2 ;;    --march) MARCH=$2; shift 2 ;;
  --hint) HINT=$2; shift 2 ;;  --flat) FLAT=$2; shift 2 ;;  --kernel) KERNEL=$2; shift 2 ;;    --tag) TAG=$2; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done
case $TIER in quick) SCALE=24 ;; standard) SCALE=27 ;; *) echo "tier: quick|standard" >&2; exit 2 ;; esac
case $HOST in zen5) ADDR=$ZEN5_HOST ;; zen4) ADDR=$ZEN4_HOST ;; *) echo "host: zen4|zen5" >&2; exit 2 ;; esac
[[ -n "$TAG" ]] || TAG="sweep-${KERNEL}-${HOST}-${TIER}"

# Per-kernel argument lines. bc's -i is the number of BFS sources, not
# iterations, and -t is not a bc flag at all; sssp needs a weighted graph.
kernel_args() {  # $1 = trials
  case $KERNEL in
    pr|pr_spmv)      echo "-i1000 -t1e-4 -n$1" ;;
    bc)              echo "-i4 -n$1" ;;
    sssp)            echo "-d2 -n$1" ;;
    cc|cc_sv|bfs|tc) echo "-n$1" ;;
    *) echo "no argument line for kernel $KERNEL" >&2; exit 2 ;;
  esac
}
graph_ext() { case $KERNEL in sssp) echo wsg ;; *) echo sg ;; esac; }

OUT="bench/results/$TAG"; mkdir -p "$OUT"
CSV="$OUT/sweep.csv"
echo "kernel,host,march,tier,graph,dist,hint,flat,trials,iters,avg_time_s,min_trial_s,ns_per_edge_iter,speedup_vs_d0(0=no D0 in run)" > "$CSV"
echo "sweeping $KERNEL, D in [$DISTS] on $HOST ($MARCH, tier $TIER, hint $HINT)" >&2

declare -A BASE
for D in $DISTS; do
  B="bench/build/sweep-$KERNEL-$MARCH-D$D-H$HINT-F$FLAT"; mkdir -p "$B"
  nix-shell -p llvmPackages_22.clang --run \
    "clang++ -std=c++11 -O3 -Wall -g -fno-omit-frame-pointer -static -march=$MARCH \
     -DPR_PREFETCH_DIST=$D -DPR_PREFETCH_HINT=$HINT -DPR_PREFETCH_FLAT=$FLAT src/$KERNEL.cc -o '$B/pr'"
  RB=/tmp/pr_sweep.$$
  scp -q -o BatchMode=yes "$B/pr" "$ADDR:$RB"
  for g in $GRAPHS; do
    EXT=$(graph_ext)
    f=$([[ $TIER == standard ]] && echo "\$HOME/code/gapbs/benchmark/graphs/$g.$EXT" || echo "/tmp/zenbench/$g-g$SCALE.$EXT")
    ARGS=$(kernel_args "$TRIALS")
    raw=$(ssh -o BatchMode=yes "$ADDR" "taskset -c $CPU $RB -f $f $ARGS" 2>/dev/null)
    avg=$(sed -n 's/^Average Time: *//p' <<<"$raw")
    [[ -n "$avg" ]] || { echo "  D=$D $g: NO TIMING (exec failed?) -- skipped" >&2; continue; }
    edges=$(sed -n 's/^Graph has [0-9]* nodes and \([0-9]*\) .*/\1/p' <<<"$raw")
    mint=$(sed -n 's/^Trial Time: *//p' <<<"$raw" | sort -g | head -1)
    # -l logs per-iteration steps for pr/pr_spmv only; for every other kernel
    # the probe is a second full run of the workload for a number that does not
    # exist, so it is skipped rather than discarded.
    case $KERNEL in
      pr|pr_spmv) iters=$(ssh -o BatchMode=yes "$ADDR" "taskset -c $CPU $RB -f $f $(kernel_args 1) -l" 2>/dev/null | grep -cE '^ *[0-9]+ ') ;;
      *)          iters=1 ;;
    esac
    [[ ${iters:-0} -gt 0 ]] || iters=1
    key="$g"; [[ $D -eq 0 ]] && BASE[$key]=$avg
    [[ -n "${BASE[$key]:-}" ]] || BASE[$key]=0
    awk -v kk="$KERNEL" -v h="$HOST" -v m="$MARCH" -v t="$TIER" -v g="$g" -v d="$D" \
        -v hint="$HINT" -v fl="$FLAT" -v tr="$TRIALS" -v it="$iters" -v avg="$avg" \
        -v mint="$mint" -v e="$edges" -v b="${BASE[$key]}" \
      'BEGIN{ printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.3f,%.4f\n",
         kk,h,m,t,g,d,hint,fl,tr,it,avg,mint,
         (e*it>0?avg*1e9/(e*it):0),(avg>0 && b>0 ? b/avg : 0) }' | tee -a "$CSV" >&2
  done
done
ssh -o BatchMode=yes "$ADDR" "rm -f /tmp/pr_sweep.$$" 2>/dev/null || true

echo >&2; column -s, -t < "$CSV"; echo "results: $CSV" >&2
