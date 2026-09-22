# Prefetch optimisation on Zen 5 — report

**Target:** AMD Ryzen 9 9950X (Zen 5), single core pinned to CCD1, 32 MiB L3.
**Reference:** AMD Ryzen 9 7950X3D (Zen 4), same pinning — used to classify a
gain as microarchitecture-specific, never to gate one.
**Build:** clang 22.1.8, `-O3`, serial, static, `-march=znver5` / `znver4`.
**Workload:** GAPBS at g27 (134M vertices, 2.1B edges). Measurements are
setup-subtracted; noise floor 2% on `cycles_per_edge_iter`, 10% on mean MLP.

Method: `bench/WORKFLOW.md`. Iteration log and raw CSVs: `bench/RESULTS.md`
and `bench/results/`.

---

## Campaign 1 — PageRank (`pr`)

### Result

| | baseline | optimised | change |
| --- | ---: | ---: | ---: |
| cycles / edge / iteration | 21.088 | **14.159** | **-32.9%** |
| wall time per trial | 41.51 s | **28.48 s** | -31.4% |
| IPC | 0.545 | **1.668** | **x3.06** |
| cycles with >=64 misses outstanding | **0.0%** | **44.7%** | — |
| mean misses in flight | 35.66 | 31.00 | -13% |

`urand` (uniform-random, same scale) gains 10.7% at the same setting and 20.4%
at its own optimum.

### What produced it

Two accepted changes, both software prefetch of the random gather
`outgoing_contrib[v]`:

1. **Within-vertex prefetch** — prefetch `D` neighbours ahead; loop split at
   `last - D` so no branch sits between the independent loads. Distance swept
   0-384, clean optimum at D=96. **-14.2%.**
2. **Flat CSR prefetch** — prefetch `D` edges ahead through the flattened
   neighbour array, ignoring vertex boundaries. Optimum D=128.
   **-32.9% cumulative.**

The second exists because of a limitation in the first: at average degree 15.7
against D=96, the within-vertex loop fires only for high-degree hubs. Crossing
vertex boundaries covers every edge.

One rejected change: the prefetch temporal hint (NTA / T2 / T1 / T0) spans
1.35%, inside noise. Cache level is irrelevant here; only distance matters.

### The mechanism is measured, not assumed

Zen 5 holds up to 124 outstanding misses, but only 64 are reachable by demand
loads since each occupies a load-queue slot. The remainder is reachable only by
prefetch instructions, which take no slot.

At baseline the kernel **never once** reached 64 outstanding. After the change
it is above 64 on **44.7% of cycles** — measured directly with
`ls_alloc_mab_count` plus `cmask`, the counter having first been validated by
construction as an occupancy counter rather than an allocation rate.

**Mean misses in flight fell** (35.66 to 31.00) while the kernel got 33%
faster. Prefetch converts demand misses into hits, so occupancy drops even as
depth increases. Mean MLP is the wrong success signal for prefetch work; the
`>=64` fraction and IPC are the right ones.

### The gain is capacity-specific

The same binary is **17% slower** on Zen 4, which never exceeds 32 outstanding
misses on any cycle. Without spare capacity, prefetches do not fill headroom —
they compete with demand loads for the same buffers and displace them.

Identical bytes: **+33% where there is miss capacity to spare, -17% where there
is not.** That contrast is the strongest evidence in the campaign that what was
bought is miss-handling capacity rather than better code.

### Two corrections worth keeping

**A wide null meant the knob was disconnected, not that the machine ignored
it.** `urand` was recorded as unable to benefit because it "already sustained
49.9 of 64 demand slots". It has Poisson(16) degrees; the within-vertex
prefetch fires only above degree `D`, and at D=96 that is an expected 1e-34
vertices out of 134 million. Zero prefetches ever issued. Its flat ~0.98 across
a 100x range of `D` was loop-restructuring overhead. Under the flat form it
gains 20.4%.

**Cache clearance does not predict available concurrency.** The fast tier (g24)
clears a 32 MiB L3 by 40x and is miss-bound on 99% of cycles, yet sustains
MLP 16.0 where g27 sustains 35.7 on the same binary. Working-set multiples
predict whether a kernel is memory-bound, not how much concurrency it has.

---

## Campaign 2 — other GAPBS kernels

*(in progress)*

Candidates ranked by whether the address of a future miss is computable now —
the property that makes prefetch pay. Conditions: **A** sequential outer walk
producing a random inner index; **B** genuinely miss-bound; **C** no early exit
wasting the prefetch.

| tier | kernel | MLP | %miss | assessment |
| --- | --- | ---: | ---: | --- |
| 1 | `pr_spmv` | 8.00 | 99.2% | SpMV form of the same gather; near-certain transfer |
| 1 | `bc` | 4.43 | 94.0% | Gathers over `out_neigh(u)` in both passes, no early exit |
| 2 | `sssp` | 5.21 | 95.2% | Prefetchable, but `WNode` is 8 B so `D` reaches half as far |
| 2 | `cc_sv` | 4.91 | 84.6% | First hop prefetchable; the pointer-jump hop is not |
| 3 | `cc` | 0.97 | 46.4% | Samples ~2 neighbours per vertex — too short for lookahead |
| 3 | `bfs` | 1.00 | 45.2% | Breaks on first hit, and the frontier bitmap fits in L3 |
| 4 | `tc` | 0.32 | 13.1% | Sequential scans, already hardware-prefetched; compute-bound |

MLP and %miss above are from the all-kernel sweep on a different part at a
smaller scale; the ranking should hold, the absolute values will not.

### Results

All at g27 on the target. `kron` is power-law (average degree 15.7, hubs carry
most edges); `urand` is uniform-random with Poisson(16) degrees.

| kernel | form | kron | urand | optimal D |
| --- | --- | ---: | ---: | ---: |
| **`cc_sv`** | within-vertex | **2.02x** | 1.08x | 128 |
| `pr` | **flat** | 1.44x | **1.20x** | 128 |
| `pr_spmv` | **flat** | 1.41x | **1.18x** | 128 |
| `sssp` | within-vertex | 1.36x | **0.86x** | 128 |
| `bc` | within-vertex | 1.09x | **0.93x** | 64 |

**D=128 is optimal for four of five kernels**, across 4-byte and 8-byte
neighbour elements, sequential/bucket/frontier iteration orders, and both
prefetch forms. That points at the distance being set by DRAM latency against
issue rate rather than by anything kernel-specific.

### The result that matters most: form decides generality

The within-vertex loop split fires only for vertices with more than `D`
neighbours. On `kron` the hubs carry most edges, so covering a minority of
vertices still covers a majority of work. On `urand`, with Poisson(16) degrees,
**P(degree > 128) is vanishing — essentially no prefetch ever issues.**

What remains on `urand` is the loop restructuring alone, and its codegen effect
is arbitrary: **-14.3% on `sssp`, -7.4% on `bc`, +8.4% on `cc_sv`.** Not
neutral, just unrelated to prefetching.

The flat-CSR form has no such dependence — it prefetches `D` edges ahead
through the flattened array regardless of any vertex's degree — and it is the
only form that gains on both graph shapes (`pr` 1.44x/1.20x, `pr_spmv`
1.41x/1.18x).

**So the honest claim is narrower than the headline numbers.** `cc_sv`'s 2.02x
is a power-law result. `sssp` and `bc` are power-law results that turn into
regressions on uniform degrees. Only `pr` and `pr_spmv` — the two kernels whose
sequential outer walk admits the flat form — are general.

The flat form requires the outer iteration to be sequential in the CSR layout.
`pr`/`pr_spmv` walk `u = 0..n`. `bc` walks a frontier queue where the next
vertex is `u+1` in 0.15-0.22% of steps; `sssp` walks delta-stepping buckets;
`cc_sv`'s gather sits behind an indirection. For those three the flat form is
meaningless, which is why they are stuck with a degree-dependent technique.

### `cc_sv` mechanism, both parts

| | cyc/edge | IPC | MLP | >=32 | >=64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zen5 D=0 | 150.72 | 0.410 | 13.84 | **0.0%** | 0.0% |
| zen5 D=128 | **73.96** | **0.966** | **23.24** | **40.8%** | **16.3%** |
| zen4 D=0 | 157.23 | 0.394 | 12.19 | 0.0% | 0.0% |
| zen4 D=128 | 165.60 | 0.434 | 12.04 | 0.0% | 0.0% |

Two things stand out. **`cc_sv`'s mean MLP rises** (13.84 to 23.24) where
`pr`'s fell — `cc_sv` was starved enough at baseline that prefetch adds net
concurrency instead of converting misses to hits. And **the two parts start
nearly equal** (12.19 against 13.84 MLP, 157 against 151 cycles per edge, Zen 4
only 11% slower) and diverge to 2.4x once prefetch asks for miss capacity that
only one of them has.

### Scoring the predictions

The candidate ranking was written before any testing.

| kernel | predicted | actual (kron) |
| --- | --- | ---: |
| `pr_spmv` | Tier 1, near-certain | +41% |
| `bc` | Tier 1, strong | +9% |
| `sssp` | Tier 2, +10-18% | +36% |
| `cc_sv` | Tier 2, single digits | **+102%** |

**Four for four on direction. Zero for four on magnitude, with the order
inverted** — the kernel ranked last is the largest win by 2x, the one ranked
first the smallest.

The ranking asked whether the access pattern *admits* a prefetch, and that
predicted the sign every time. Magnitude is governed by two things it never
considered: what fraction of the kernel's runtime the prefetchable gather
represents, and how miss-dense that gather is. Both were measurable up front.

The `cc_sv` miss is the instructive one. I reasoned that pointer jumping puts
half its misses out of reach — but `comp[comp[v]]` is *conditional*, taken only
when `comp_u != comp_v`, which after the first iteration is rare. The first hop
is nearly all the misses and fully prefetchable, over a 536 MB array touched
~4.2 billion times. **Reasoning about the structure of an access pattern
without asking how often each branch of it executes** is the same error that
produced the wrong `urand` conclusion in campaign 1.
