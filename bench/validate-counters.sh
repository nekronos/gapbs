#!/usr/bin/env bash
# Discover this machine's outstanding-miss occupancy counter and prove it is one.
#
# Run this FIRST on any new machine, before trusting an MLP figure from
# run-pagerank.sh. On AMD the event name differs by model and a similarly-named
# allocation counter will produce a plausible, wrong number.
#
# Method: chase K independent pointer cycles. With K lanes the core has K
# independent misses available, so occupancy/cycles must read ~K. A counter that
# does not track K is not an occupancy counter.
set -uo pipefail
cd "$(dirname "$0")/.."
CPU=${CPU:-1}; NODE=${NODE:-0}
BIN=bench/build/validate-counters
mkdir -p bench/build
[[ -x $BIN ]] || clang -O2 -g -march=native -o $BIN bench/validate-counters.c

VENDOR=$(lscpu | sed -n 's/^Vendor ID: *//p' | head -1)
echo "vendor: $VENDOR"
echo "cpu:    $(lscpu | sed -n 's/^Model name: *//p' | head -1)"

# Candidate occupancy events, most specific first. Intel accumulates outstanding
# L1D misses per cycle; AMD's analogue is a Miss Address Buffer event whose name
# varies by generation, so discover rather than hard-code.
case "$VENDOR" in
  GenuineIntel) CANDS="L1D_PEND_MISS.PENDING l1d_pend_miss.pending" ;;
  AuthenticAMD) CANDS=$(perf list 2>/dev/null | grep -oiE '\bls_[a-z_]*mab[a-z_]*\b' | sort -u | tr '\n' ' ') ;;
  *)            CANDS=$(perf list 2>/dev/null | grep -oiE '\b[a-z0-9_.]*(pend|mab|outstanding)[a-z0-9_.]*\b' | sort -u | tr '\n' ' ') ;;
esac
[[ -n "${CANDS// }" ]] || { echo "FAIL: no candidate occupancy events found in perf list" >&2; exit 1; }
echo "candidates: $CANDS"
echo

occ() { # $1=event $2=lanes -> occupancy per cycle, setup-subtracted
  read_ev() {
    perf stat -x, --no-big-num -e "cycles,$1" \
      -- taskset -c $CPU numactl --membind=$NODE env VC_LANES=$2 VC_HITS=$3 $BIN 2>&1 >/dev/null \
    | awk -F, '$1 ~ /^[0-9]+$/ {printf "%s ", $1}'
  }
  read -r c1 e1 <<<"$(read_ev "$1" "$2" $((8<<20)))"
  read -r c0 e0 <<<"$(read_ev "$1" "$2" 1024)"
  awk -v c=$((c1-c0)) -v e=$((e1-e0)) 'BEGIN{ printf "%.2f", (c>0? e/c : 0) }'
}

for ev in $CANDS; do
  perf stat -e "$ev" true >/dev/null 2>&1 || { printf "  %-28s unsupported\n" "$ev"; continue; }
  printf "  %-28s " "$ev"
  vals=()
  for K in 1 2 4 8; do v=$(occ "$ev" $K); vals+=("$v"); printf "K=%d:%-7s " "$K" "$v"; done
  awk -v a="${vals[0]}" -v b="${vals[1]}" -v c="${vals[2]}" -v d="${vals[3]}" 'BEGIN{
    ok = (a>0.5 && a<1.8) && (b>a*1.4) && (c>b*1.4) && (d>c*1.2);
    print ok ? " -> OCCUPANCY (tracks K)" : " -> NOT occupancy (does not track K)" }'
done
echo
echo "Use the event marked OCCUPANCY in run-pagerank.sh. If none qualifies, the"
echo "machine exposes no occupancy counter and MLP must be derived by Little's"
echo "law from a miss rate and a measured latency instead -- label it as such."
