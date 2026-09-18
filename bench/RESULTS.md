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

## Baseline

*(pending — tier C, both machines, both graphs, no code changes)*

## Iterations

| # | Change | Graph | cyc/edge/iter | Δ | MLP | ≥64 | Verdict | Label |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
