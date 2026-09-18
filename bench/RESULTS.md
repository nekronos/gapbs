# Campaign log: PageRank on Zen 5

Append-only. Every row here is reproducible from the CSV named beside it in
`bench/results/`. Method, tiers, accept rule and stop condition:
`bench/WORKFLOW.md`.

**Target:** Zen 5 (Ryzen 9 9950X), `-march=znver5`, cpu 8 (CCD1, 32 MiB L3).
**Reference:** Zen 4 (Ryzen 9 7950X3D), `-march=znver4`, cpu 8 (CCD1, 32 MiB L3
— *not* the 96 MiB V-Cache CCD).
**Compiler:** clang 22.1.8 via `nix-shell -p llvmPackages_22.clang`, serial
(no OpenMP), static.

## Setup findings (before iteration 1)

| Finding | Consequence |
| --- | --- |
| `ls_alloc_mab_count` is a true occupancy counter on both parts — reads 0.93/2.00/3.84/7.22 on Zen 5 at 1/2/4/8 independent misses | misses in flight are directly measurable, not inferred |
| `cmask=N` works on this PMU with no multiplexing | the *distribution* of misses in flight is measurable, not just the mean |
| clang 21 **and** 22 emit byte-identical assembly for `-march=znver4` and `-march=znver5` on `pr.cc` | any cross-machine difference today is silicon, not code generation |
| NixOS has no generic dynamic loader | binaries must be static; a dynamic one exits 127 and perf reports counters for the failed exec without complaint |
| Standard g27 graph set already present on both machines | tier C needs no generation |

## Noise floor (target, tier B, 3 repeats of one binary)

`bench/results/noise-r{1,2,3}/`, sha `f2ae9737a0268784`, clang 22.1.8.

| metric | kron | urand | threshold adopted |
| --- | --- | --- | --- |
| `cycles_per_edge_iter` | 0.72% | 1.80% | **2%** — a change must beat this to be accepted |
| `mlp` | **4.10%** | 1.69% | **10%** for the headroom stop rule |

The cycles threshold matches the figure carried over from Intel, so 2% stands.
The MLP threshold does not: the end condition originally stopped when two
consecutive changes each added under 5% to MLP, which is inside kron's 4.1%
noise. Raised to 10%. MLP is a ratio of two setup-subtracted counters and its
errors compound, so it is the noisier of the two signals despite being the one
the campaign is buying.

## Baseline — tier C (g27), unmodified source

`bench/results/baseline/` and `baseline-zen4/`. clang 22.1.8, serial, static,
sha `f2ae9737a0268784` — **byte-identical on both machines**, since clang emits
the same code for `-march=znver4` and `-march=znver5` on this source. Any
difference below is therefore silicon, not code generation.

| host | graph | cyc/edge/iter | IPC | MLP | ≥16 | ≥32 | ≥64 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **zen5** | kron | **21.088** | 0.545 | **35.66** | 88.8% | 63.3% | **0.0%** |
| **zen5** | urand | **25.332** | 0.456 | **49.92** | 99.0% | 93.3% | **0.0%** |
| zen4 | kron | 39.322 | 0.294 | 15.85 | 67.0% | 0.0% | 0.0% |
| zen4 | urand | 61.585 | 0.190 | 17.66 | 80.6% | 0.0% | 0.0% |

Three things this fixes in place.

**Zen 4 never exceeds 32 outstanding misses**, on either graph, on any cycle.
Zen 5 is above 32 for 63–93% of cycles. That is a capability boundary between
the parts, not a property of the code.

**The speedup is the concurrency.** Zen 5 is 1.86x faster on kron with 2.25x the
misses in flight, and 2.43x faster on urand with 2.83x. The ratios track closely
enough that the performance difference on this kernel is essentially the
miss-capacity difference.

**Neither part reaches 64 outstanding on any cycle.** 64 is the demand-load
ceiling, so the demand path is the whole story so far, and everything above it
is reachable only by prefetch instructions that take no load-queue slot.

## Scale changes the quantity being optimised

Same binary, same machine, tier B (g24) against tier C (g27):

| graph | MLP @ g24 | MLP @ g27 | ratio |
| --- | ---: | ---: | ---: |
| kron | 16.0 | 35.7 | **2.2x** |
| urand | 33.8 | 49.9 | 1.5x |

The fast tier does not preserve the memory regime. g24 clears a 32 MiB L3 by
40x and the kernel is memory-bound there on 99% of cycles — yet it sustains less
than half the concurrency it does at g27. **Working-set multiples predict
whether a kernel is memory-bound; they do not predict how much concurrency is
available to it.** A prefetch distance tuned at g24 has no claim to being right
at g27.

Consequence: the fast tier moves up, and the ranking check is owed against g27
before any tier-B result is used to accept a change.

## Iterations

| # | Change | Graph | cyc/edge/iter | Δ | MLP | ≥64 | Verdict | Label |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
