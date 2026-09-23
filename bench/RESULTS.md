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

### 3 — flat CSR prefetch across vertex boundaries — ACCEPTED, Zen 5-specific

Motivated by a limitation of iteration 1 visible in the graph statistics: kron
has **average degree 15.7** while the winning distance is **D=96**, so
`last - first > D` is false for the large majority of vertices. Their main loop
is empty and no prefetch fires at all — only high-degree hubs benefit. That the
change still bought 14% says the hubs carry most of the edges; the low-degree
tail is untouched.

Prefetching `D` edges ahead through the flattened CSR neighbour array, ignoring
vertex boundaries, covers every edge regardless of its vertex's degree. Clamped
with a conditional move rather than a branch. `PR_PREFETCH_FLAT=1`.

**Distance sweep** (`bench/results/iter3-flat-sweep/`):

| D | 0 | 32 | 64 | 96 | **128** | 192 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| kron | 1.000 | 0.835 | 1.096 | 1.318 | **1.443** | 1.304 |
| urand | 1.000 | 0.859 | 1.114 | **1.204** | 1.121 | 1.036 |

**Counters at D=128** (`bench/results/iter3-D128-flat/`), against the baseline:

| | cyc/edge/iter | IPC | MLP | ≥32 | ≥64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zen5 kron, baseline | 21.088 | 0.545 | 35.66 | 63.3% | 0.0% |
| zen5 kron, **D=128 flat** | **14.159** | **1.668** | 31.00 | 89.4% | **44.7%** |
| zen5 urand, baseline | 25.332 | 0.456 | 49.92 | 93.3% | 0.0% |
| zen5 urand, **D=128 flat** | **22.623** | **1.049** | 31.97 | 89.8% | **59.8%** |
| zen4 kron, baseline | 39.322 | 0.294 | 15.85 | 0.0% | 0.0% |
| zen4 kron, D=128 flat | 46.019 | 0.515 | 14.25 | 0.0% | 0.0% |
| zen4 urand, baseline | 61.585 | 0.190 | 17.66 | 0.0% | 0.0% |
| zen4 urand, D=128 flat | 64.743 | 0.369 | 16.87 | 0.0% | 0.0% |

**kron -32.9% cycles, IPC 3.06x, `pct_ge64` 0 to 44.7%.** urand -10.7% at this
distance (its own optimum is D=96, worth 20.4%). Zen 4 regresses on both, 17%
and 5%, still never exceeding 32 outstanding — the same displacement effect as
iteration 1, now larger because more prefetches compete for buffers it does not
have.

IPC tripling is the clearest single number in the campaign: the core went from
retiring 0.545 instructions per cycle to 1.668 on identical work, because it is
no longer standing still waiting for DRAM.

### Correction, 2026-09-19: `urand` was never a non-target

Iteration 2's record and the `WORKFLOW.md` rule both claimed `urand` could not
benefit from prefetching because it already sustained 49.9 of 64 demand slots
and had no headroom. **That was wrong, and the measurement behind it was of code
that never ran.**

`urand` is uniform-random with Poisson(16) degrees. The within-vertex prefetch
fires only for vertices with more than `D` neighbours; at D=96 that is
P = 8.8e-43, an expected 1e-34 vertices out of 134 million. **Zero prefetches
were ever issued on `urand`.** Its flat ~0.98 was the restructured loop's
overhead with the prefetch never executing. Under the flat-CSR form it gains
20.4%.

The evidence was there to read: `urand` was 0.979–0.982 across a 100x range of
`D`. **A parameter that spans two orders of magnitude with no effect is evidence
that the parameter is not reaching the code, before it is evidence about the
machine.** The degree statistic that explained kron's low-degree tail was the
same statistic that explained urand entirely, and it was applied to one and not
the other.

## Campaign 2 — other kernels

### `pr_spmv` — ACCEPTED, transfers cleanly

Flat-CSR prefetch ported directly from `pr.cc`; `pr_spmv` walks the same
`in_neigh` direction and gathers the same `outgoing_contrib[v]`. The Jacobi
formulation costs a separate refresh pass (baseline 56.85 s against `pr`'s
41.51 s, 7 iterations against 5) but does not touch the access pattern.

| D | 0 | 64 | 96 | **128** | 192 |
| --- | ---: | ---: | ---: | ---: | ---: |
| kron | 1.000 | 1.078 | 1.295 | **1.410** | 1.307 |
| urand | 1.000 | 1.100 | **1.182** | 1.097 | 1.021 |

**+41.0% on kron at D=128.** Same optima as `pr` (kron 128, urand 96), near
identical curve shape and magnitude. The technique transfers to a structurally
identical gather with no retuning.

### `bc` — the flat form does not apply, and the reason is measurable

`bc` walks a `SlidingQueue` in frontier order, not vertex-id order. Measured on
the test graph: **the next queue vertex is `u+1` in 0.15-0.22% of steps.** A
flat lookahead crossing a vertex boundary therefore lands on a line that is
essentially never the one used next — and at D=128 that would be ~44% of
prefetches. On `urand`, with no hubs, it is 100% waste. A wasted flat prefetch
is not neutral: it is a real DRAM read on a wrong line.

So `bc` uses the **within-vertex** form, which still covers 55.9% of edges at
D=128 (4.8% of vertices carry 76.6% of edges), and `PR_PREFETCH_FLAT=1` is a
compile error there so the sweep driver cannot record a within-vertex build
labelled as flat.

Only the forward BFS `depths[v]` gather is instrumented — it misses on 100% of
edges. Skipped: `path_counts[v]` in the same loop (~87% of those prefetches
would be waste, since only 10-14% of traversed edges are successor edges), and
the whole backward pass for the same reason. A `succ`-bit-gated variant is a
different, unproven pattern and belongs in its own iteration so attribution
stays clean.

**Generalisation.** The flat form needs the *outer* walk to be sequential in
the CSR layout. `pr` and `pr_spmv` walk `u = 0..n`, so it holds. Any
frontier-, queue-, or bucket-ordered kernel breaks it, which by inspection also
covers `bfs`, `cc`, and the bucket loop in `sssp`.

**`bc` result: ACCEPTED, +9.0% at D=64.**

| D | 0 | 32 | **64** | 128 |
| --- | ---: | ---: | ---: | ---: |
| kron | 1.000 | 1.058 | **1.090** | 1.088 |

Plateaus after 64. Much smaller than `pr`'s 41% for three compounding reasons:
the within-vertex form covers ~68% of edges at D=64 rather than every edge;
only the forward `depths[v]` gather is instrumented; and the frontier ordering
means the lookahead cannot cross vertex boundaries at all.

**The first `bc` sweep was a false negative, and it is the most instructive
error in the campaign.** It measured -4.4% to -7.1%, monotonically worse with
distance, and the obvious write-up — "frontier-ordered kernels do not benefit"
— was consistent with the data and matched the correct flat-form finding from
the same kernel. It was still wrong.

Cause: two incompatible ways to handle a neighbour list shorter than `D`.

| | short-list behaviour |
| --- | --- |
| loop split (`pr.cc`) | prefetching body never executes; **zero** prefetches |
| clamp inside loop (first `bc.cc`) | prefetches `depths[*(last-1)]` **every iteration** |

The clamp is correct for the *flat* form, where `edge_end - 1` is reached once
at the end of the whole array. Ported into the *within-vertex* form it turns a
rare fallback into the common path: at average degree 15.7 against D>=64 the
condition is always false, so `bc` issued one redundant prefetch of the same
address per edge, across 2.1 billion edges. Switching to the loop split moved
the result 16 percentage points, from -7.1% to +9.0%.

**Lesson, distinct from the tooling bugs earlier in this campaign.** Those
produced implausible values that announced themselves — a negative MLP, 100.3%
of cycles, a hostname under a `kernel` column. This produced a *plausible*
value that agreed with a *correct* neighbouring finding. A result that confirms
what you already believe deserves the same scrutiny as one that contradicts it,
and more than one that looks absurd.

### `sssp` — ACCEPTED, +35.8% at D=128

Within-vertex loop split on the `dist[wn.v]` gather in `RelaxEdges`, the single
gather both DeltaStep call sites go through. `WNode` is 8 bytes (id + weight),
so a given `D` reaches half as far in bytes as in `pr`.

| D | 0 | 32 | 64 | **128** | 192 |
| --- | ---: | ---: | ---: | ---: | ---: |
| kron | 1.000 | 1.255 | 1.299 | **1.358** | 1.246 |

**This breaks the explanation that was forming.** After `bc` came in at +9.0%
against the PageRanks' 41%, the tempting story was that the flat form is what
matters and within-vertex kernels are capped near 10%. `sssp` uses the
within-vertex form and reaches 35.8%.

The better predictor is **what fraction of the kernel's runtime the
instrumented gather represents**:

| kernel | form | instrumented | result |
| --- | --- | --- | ---: |
| `pr`, `pr_spmv` | flat | the whole kernel, every edge | 41% |
| `sssp` | within-vertex | `RelaxEdges` — every edge, is the kernel | 35.8% |
| `bc` | within-vertex | forward `depths[v]` only, one of two phases | 9.0% |

`bc` is low because roughly a third of its work was instrumented, not because
within-vertex is weak. Prefetch form sets the *ceiling*; coverage of the
runtime sets the *result*.

### `cc_sv` — ACCEPTED, 2.02x at D=128 — the largest result of the campaign

Within-vertex loop split on `comp[v]` in the hooking loop, the only prefetchable
gather. `comp[comp[v]]` cannot be covered: its address is the value the first
load returns.

| D | 0 | 8 | 16 | 32 | 64 | 96 | **128** | 192 | 256 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| kron | 1.000 | 1.315 | 1.457 | 1.678 | 1.847 | 1.978 | **2.020** | 1.855 | 1.782 |

**I predicted single digits for this kernel and ranked it last.** The reasoning
was that pointer jumping puts half the misses out of reach. The premise was
wrong: `comp[high_comp]` is *conditional*, taken only when `comp_u != comp_v`,
which after the first iteration is rare. The first hop is nearly all the misses
and is fully prefetchable — over a 536 MB array touched roughly 4.2 billion
times, the most miss-dense gather in the suite. Its baseline of 58.44 s against
`sssp`'s 29.52 s on the same graph says as much.

The error is the same one that produced the wrong `urand` conclusion in
campaign 1: **reasoning about the structure of an access pattern without asking
how often each branch of it executes.**

## Campaign 2 summary

| kernel | speedup | D | form | coverage |
| --- | ---: | ---: | --- | --- |
| **`cc_sv`** | **2.02x** | 128 | within-vertex | first hop, ~all misses |
| `pr` | 1.44x | 128 | flat | whole kernel |
| `pr_spmv` | 1.41x | 128 | flat | whole kernel |
| `sssp` | 1.36x | 128 | within-vertex | whole kernel |
| `bc` | 1.09x | 64 | within-vertex | one phase of two |

**D=128 is optimal for four of five kernels**, across different element sizes
(4 B vs 8 B `WNode`), iteration orders (sequential, bucket, frontier) and both
prefetch forms. That points at the distance being set by DRAM latency against
issue rate rather than by anything kernel-specific.

### Scoring the predictions

The ranked candidate list was written before any testing.

| kernel | predicted | actual |
| --- | --- | ---: |
| `pr_spmv` | Tier 1, near-certain | +41% |
| `bc` | Tier 1, strong | +9% |
| `sssp` | Tier 2, +10-18% | +36% |
| `cc_sv` | Tier 2, single digits | **+102%** |

**Four for four on direction. Zero for four on magnitude, and the order
inverted** — the kernel ranked last is the largest win by a factor of two, the
one ranked first is the smallest.

The ranking was built on whether the access pattern *admits* a prefetch, which
predicted the sign correctly every time. Magnitude turned out to be governed by
two things the ranking never considered: what fraction of the kernel's runtime
the prefetchable gather represents, and how miss-dense that gather is. Both are
measurable up front; neither was measured.

## Postscript: what the compilers already do (2026-09-23)

`cc_sv`, unaltered source, Zen 5, kron g27, `taskset -c 8`, wall clock under
`perf stat`, two runs each.

**No compiler emits the indirect prefetch.** clang 22, AOCC 5.1.0 (plain,
`-flto`, `-fprefetch-loop-arrays`) and GCC 15.3 `-fprefetch-loop-arrays` each
emit exactly 196 prefetch instructions, byte-identical in form, every one a
constant-offset `prefetcht0`/`t1` inside static libc. The manual builds carry
one more — the scaled-index gather form, `prefetcht0 (%r14,%rcx,4)`. LLVM's
`LoopDataPrefetch` and GCC's `aprefetch` work from affine SCEV address
expressions, and `comp[*p]` is not affine in the induction variable.

**AOCC was 26% faster anyway, and it is loop alignment.** The hot loop is the
same instructions in the same order (clang `0x405870`, AOCC `0x3f0ec0` inlined
into `main` under `-flto`). Instructions differ 1.2% — clang's extra
`inc %esi` + `movslq` in the *outer* loop — and branch misses are a wash, so
all 65 G cycles of the gap are stall.

| build | loop head | sec | Gcycles | IPC | mean MLP |
| --- | --- | ---: | ---: | ---: | ---: |
| clang 22 | `%64 = 48`, straddles | 59.59 / 60.27 | 324.2 / 328.1 | 0.406 | 14.0 |
| clang `-falign-loops=32` | `%64 = 32` | 51.03 / 53.28 | 277.5 / 289.7 | 0.464 | 16.7 |
| clang `-falign-loops=64` | `%64 = 0` | 47.50 / 47.86 | 258.3 / 260.2 | 0.507 | 18.0 |
| AOCC 5.1.0 `-flto` | `%64 = 0` | 47.78 / 47.30 | 259.9 / 257.2 | 0.503 | 18.0 |

AOCC 64-aligns loop heads with and without `-flto`, so it is its default, not
an LTO effect. Aligned clang matches AOCC on every counter.

**Prefetch subsumes alignment; they are not additive.**

| | sec | vs clang baseline |
| --- | ---: | ---: |
| clang 22 `-O3 -march=znver5` | 59.9 | 1.00x |
| `-falign-loops=64` (= AOCC) | 47.7 | 1.26x |
| prefetch D=128 alone | 30.43 / 30.54 | 1.97x |
| alignment + prefetch | 30.09 / 30.20 | **1.99x** |

Adding alignment on top of the prefetch buys 1.1%, inside the 2% noise floor:
once the prefetch is in, the loop waits on memory and the fetch bubble hides
behind the miss. Both prefetch builds land at `%64 = 16` — adding the
instruction moved the loop off AOCC's aligned slot too — so the campaign's
2.02x compares two equally misaligned builds and is not alignment luck.

**Restatement.** 2.02x is against clang 22 and stands. 1.26x of that gap is
also reachable by a flag unrelated to prefetching, so the prefetch-specific
increment over a best-compiled baseline is **1.58x**. Measured on `cc_sv` only;
the other four kernels' baselines were not checked for the same accident.

*Hazard hit again:* a failed `scp` left the binary absent, and `perf stat` on
the failed exec reported plausible-looking IPC and MLP with 0.00 s elapsed. The
rerun greps the kernel's own "Average Time" line before trusting any counter.
