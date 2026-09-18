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

### 1 — software prefetch in the gather, distance swept

`src/pr.cc`: `-DPR_PREFETCH_DIST=D` prefetches `outgoing_contrib[*(p + D)]` while
the gather consumes neighbour `p`. Loop split at `last - D` so no bounds test
sits between the independent loads. `D=0` compiles to a `.text` byte-identical
to the pristine source, so the control is real.

**Distance sweep**, cycles only, g27, target
(`bench/results/sweep-D-zen5-{standard,extended}/`):

| D | 0 | 4 | 8 | 16 | 32 | 64 | **96** | 128 | 192 | 256 | 384 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| kron | 1.000 | 0.839 | 0.865 | 0.919 | 1.012 | 1.118 | **1.177** | 1.152 | 1.093 | 1.094 | 1.080 |
| urand | 1.000 | 0.879 | 0.915 | 0.953 | 0.986 | 0.982 | 0.979 | 0.982 | 0.982 | 0.982 | 0.982 |

Clean peak at **D=96** on kron. Small distances are actively harmful — D=4 is 16%
*slower* than no prefetch, because the line is already in flight when the
prefetch issues, so it buys nothing and consumes a miss-handling slot anyway.
The optimum needs 96 neighbours of lookahead, which is what ~80-100 ns of DRAM
latency costs against a gather consuming a neighbour every few cycles.

**Counters at D=96** (`bench/results/iter1-D96/`):

| | cyc/edge/iter | IPC | MLP | ≥32 | ≥64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zen5 kron, baseline | 21.088 | 0.545 | 35.66 | 63.3% | **0.0%** |
| zen5 kron, D=96 | **18.097** | **0.823** | 27.92 | 66.6% | **30.2%** |
| zen5 urand, baseline | 25.332 | 0.456 | 49.92 | 93.3% | 0.0% |
| zen5 urand, D=96 | 26.037 | 0.458 | 48.67 | 91.2% | 0.0% |
| zen4 kron, baseline | 39.322 | 0.294 | 15.85 | 0.0% | 0.0% |
| zen4 kron, D=96 | 46.870 | 0.320 | 14.15 | 0.0% | 0.0% |

**Verdict: accepted, Zen 5-specific.** kron -14.2% on the target. urand +2.8%,
just outside the 2% floor, so this is a recorded trade rather than a flat
second graph: urand already sustains 49.9 of the 64 demand slots at this scale
and has no headroom for a prefetch to fill, so it pays the instruction cost for
nothing.

Three findings that outlast the number.

**The load-queue bypass is real.** `pct_ge64` went from 0.0% to 30.2% — a level
the kernel never reached once at baseline. Prefetch instructions are holding
miss capacity without taking load-queue slots, which is what the 64-vs-124 split
predicts and the first direct evidence of it here.

**Mean MLP is the wrong success signal for prefetch, and it fell on a win.**
35.66 to 27.92. Occupancy-cycles per edge-iteration went 752 to 505, a third
lower, while cycles fell 14% and IPC rose 51%. The prefetches are converting
demand misses into hits: the line arrives before the load issues, so the load
never misses. Fewer misses outstanding on average, in deeper bursts. Read
`pct_ge64` and IPC instead; the end condition's headroom rule is written against
mean MLP and would have scored this change a failure.

**Zen 4 regresses 19% on the same binary**, and that is the clearest evidence
for the capacity argument in the campaign so far. Zen 4 never exceeds 32
outstanding. With no spare capacity, prefetches do not fill headroom — they
compete with demand loads for the same buffers and displace them. One change,
+14% where there is capacity to spare and -19% where there is not.

### 2 — prefetch temporal hint, swept at D=96 — REJECTED (null)

`bench/results/iter2-hint{0,1,2,3}/`. `__builtin_prefetch`'s locality argument,
verified distinct at the instruction level.

| hint | instruction | kron avg_time_s |
| --- | --- | ---: |
| 0 | `prefetchnta` | 34.932 |
| 1 | `prefetcht2` | **34.465** |
| 2 | `prefetcht1` | 34.492 |
| 3 | `prefetcht0` | 34.599 |

Full spread **1.35%**, inside the 2% noise floor. NTA is nominally worst and T2
nominally best, both by margins that are not distinguishable from noise. No
change; T0 retained as the default.

The hypothesis was that T0 would be a poor choice, since at D=96 the line is
wanted 96 gather iterations later and the kernel streams a 9.8 GiB working set,
so L1 eviction before use looked likely. Measurement says the level the prefetch
targets does not matter here. The plausible reason is that the choice was never
really between cache levels: the win is that the line is **in the machine at
all** rather than being waited on, and once it is off the DRAM path, which level
holds it costs a few cycles against a ~400-cycle miss. Consistent with the D
sweep, where sensitivity to *distance* was enormous (16% between D=4 and D=96)
and sensitivity to placement is nil.

Counts as one of the three consecutive sub-threshold iterations in the primary
stop rule. It does not indicate the prefetch lever is exhausted — only that this
knob is not one. `pct_ge64` is 30.2%, so 70% of cycles remain below the
demand-load ceiling.

### 3 — flat CSR prefetch across vertex boundaries — in progress

Motivated by a limitation of iteration 1 visible in the graph statistics: kron
has **average degree 15.7** while the winning distance is **D=96**, so
`last - first > D` is false for the large majority of vertices. Their main loop
is empty and no prefetch fires at all — only high-degree hubs benefit. That the
change still bought 14% says the hubs carry most of the edges; the low-degree
tail is untouched.

Prefetching `D` edges ahead through the flattened CSR neighbour array, ignoring
vertex boundaries, covers every edge regardless of its vertex's degree. Clamped
with a conditional move rather than a branch, since a branch between the
independent loads is what costs the concurrency being bought.
