#!/usr/bin/env bash
# Build once, ship to both Zen machines, measure the SAME binary on each.
#
#   bench/run-zen.sh --march x86-64-v3 --tier quick
#
# Zen 5 is the optimisation target. Zen 4 is a reference, used only to classify
# a gain as microarchitecture-specific or general -- never to gate it.
#
# Binaries are STATIC. NixOS has no generic dynamic loader, so a dynamically
# linked binary built elsewhere exits 127 -- and perf reports counters for the
# failed exec without complaining, which looks like a real measurement.
set -euo pipefail
cd "$(dirname "$0")/.."

ZEN4=user@reference-host          # Ryzen 9 7950X3D
ZEN5=user@target-host       # Ryzen 9 9950X
CPU=8                              # CCD1 on BOTH -> 32 MiB L3 each. Pinning Zen 4
                                   # to a V-Cache core (cpu 0-7/16-23, 96 MiB) would
                                   # confound the comparison with cache size.
REMOTE_GRAPHS='$HOME/code/gapbs/benchmark/graphs'
OCC=ls_alloc_mab_count             # validated as a true occupancy counter on both

MARCH=x86-64-v3; TIER=quick; TRIALS=16; GRAPHS="kron urand"; TAG=""; HOSTS="zen5 zen4"
while [[ $# -gt 0 ]]; do case $1 in
  --march) MARCH=$2; shift 2 ;;  --tier) TIER=$2; shift 2 ;;
  --trials) TRIALS=$2; shift 2 ;; --graphs) GRAPHS=$2; shift 2 ;;
  --tag) TAG=$2; shift 2 ;;      --hosts) HOSTS=$2; shift 2 ;;
  *) echo "unknown arg: $1" >&2; exit 2 ;;
esac; done
case $TIER in quick) SCALE=24 ;; standard) SCALE=27 ;; *) echo "tier: quick|standard" >&2; exit 2 ;; esac
[[ -n "$TAG" ]] || TAG="${MARCH}-${TIER}"

BUILD="bench/build/zen-$MARCH"; OUT="bench/results/$TAG"; mkdir -p "$BUILD" "$OUT"
CXXFLAGS="-std=c++11 -O3 -Wall -g -fno-omit-frame-pointer -static -march=$MARCH"
echo "building pr + converter static at -march=$MARCH" >&2
clang++ $CXXFLAGS src/pr.cc -o "$BUILD/pr"
clang++ $CXXFLAGS src/converter.cc -o "$BUILD/converter"
SHA=$(sha256sum "$BUILD/pr" | cut -c1-16)
echo "binary sha256[0:16] = $SHA  (identical on every host below)" >&2

CSV="$OUT/zen.csv"
echo "host,cpu,march,sha,tier,graph,nodes,edges,iters,trials,avg_time_s,min_trial_s,cycles_per_edge_iter,ipc,mlp" > "$CSV"

for hostname in $HOSTS; do
  case $hostname in zen4) ADDR=$ZEN4 ;; zen5) ADDR=$ZEN5 ;; *) echo "host: zen4|zen5" >&2; exit 2 ;; esac
  echo "=== $hostname ($ADDR) ===" >&2
  scp -q -o BatchMode=yes "$BUILD/pr" "$BUILD/converter" "$ADDR:/tmp/"

  ssh -o BatchMode=yes "$ADDR" TIER="$TIER" SCALE="$SCALE" TRIALS="$TRIALS" \
      GRAPHS="$GRAPHS" CPU="$CPU" OCC="$OCC" HOSTNAME_TAG="$hostname" \
      MARCH="$MARCH" SHA="$SHA" 'bash -s' <<'REMOTE' >> "$CSV"
set -uo pipefail
GDIR="$HOME/code/gapbs/benchmark/graphs"
WORK=/tmp/zenbench; mkdir -p $WORK

# The standard graphs are g27. A smaller tier is generated once, locally.
resolve() {
  if [[ "$TIER" == standard ]]; then echo "$GDIR/$1.sg"; return; fi
  local f="$WORK/$1-g$SCALE.sg"
  if [[ ! -f $f ]]; then
    case $1 in kron)  /tmp/converter -g$SCALE -k16 -b "$f" >/dev/null 2>&1 ;;
               urand) /tmp/converter -u$SCALE -k16 -b "$f" >/dev/null 2>&1 ;;
               *) echo "no generator for $1" >&2; return 1 ;; esac
  fi
  echo "$f"
}

nixperf() { nix-shell -p linuxPackages.perf --run "$1" >/dev/null 2>&1; }

for g in $GRAPHS; do
  f=$(resolve "$g") || continue
  raw=$(taskset -c $CPU /tmp/pr -f "$f" -i1000 -t1e-4 -n$TRIALS 2>/dev/null)
  # Guard: a failed exec yields no Average Time. perf would still report plausible
  # counters for it, so refuse to emit a row rather than record a phantom.
  avg=$(sed -n 's/^Average Time: *//p' <<<"$raw")
  [[ -n "$avg" ]] || { echo "FATAL: pr produced no timing on $HOSTNAME_TAG/$g (exec failed?)" >&2; continue; }
  nodes=$(sed -n 's/^Graph has \([0-9]*\) nodes.*/\1/p' <<<"$raw")
  edges=$(sed -n 's/^Graph has [0-9]* nodes and \([0-9]*\) .*/\1/p' <<<"$raw")
  mint=$(sed -n 's/^Trial Time: *//p' <<<"$raw" | sort -g | head -1)
  iters=$(taskset -c $CPU /tmp/pr -f "$f" -i1000 -t1e-4 -n1 -l 2>/dev/null | grep -cE '^ *[0-9]+ ')

  ctr() {
    rm -f $WORK/perf.out
    nixperf "perf stat -x, --no-big-num --output $WORK/perf.out -e cycles,instructions,$OCC -- taskset -c $CPU /tmp/pr -f $f -i1000 -t1e-4 -n$1"
    awk -F, '$1 ~ /^[0-9]+$/ {printf "%s ", $1}' $WORK/perf.out
  }
  read -r cN iN pN <<<"$(ctr $TRIALS)"
  read -r c1 i1 p1 <<<"$(ctr 1)"

  awk -v h="$HOSTNAME_TAG" -v cpu="$CPU" -v m="$MARCH" -v s="$SHA" -v t="$TIER" -v g="$g" \
      -v n="$nodes" -v e="$edges" -v it="$iters" -v tr="$TRIALS" -v avg="$avg" -v mint="$mint" \
      -v c=$((cN-c1)) -v i=$((iN-i1)) -v p=$((pN-p1)) -v tn=$((TRIALS-1)) 'BEGIN{
        ed=e*it*tn;
        printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.3f,%.3f,%.2f\n",
          h,cpu,m,s,t,g,n,e,it,tr,avg,mint,
          (ed>0?c/ed:0),(c>0?i/c:0),(c>0?p/c:0) }'
done
REMOTE
done

echo >&2; column -s, -t < "$CSV"; echo >&2; echo "results: $CSV" >&2
