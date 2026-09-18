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

## Baseline

*(pending — tier C, both machines, both graphs, no code changes)*

## Iterations

| # | Change | Graph | cyc/edge/iter | Δ | MLP | ≥64 | Verdict | Label |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
