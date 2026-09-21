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

*(pending)*
