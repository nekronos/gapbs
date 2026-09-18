# PageRank performance iteration workflow

How to change PageRank and know whether it actually got faster, on one
microarchitecture, without being fooled by a cheap measurement.

Everything below was calibrated on the machine in `bench/results/*/provenance.txt`;
re-derive the numbers on a different part before trusting them.

## What is measured

**One core.** Serial build, no OpenMP, pinned with `taskset`, memory bound to one
NUMA node. Thread scheduling noise is larger than most microarchitectural effects,
and a loaded socket is memory-system-bound rather than core-bound, so the core is
measured alone.

**Per edge per iteration.** PageRank stops on the `-t` tolerance long before the
`-i1000` cap — 6 iterations on `kron`, 4 on `urand` — and the converged count
differs per graph. A per-trial or per-second figure is therefore not comparable
across graphs. The driver probes the count with `-l` and normalises by
`edges x iterations`.

**Cycles, not just wallclock.** Wallclock folds in frequency, which drifts with
governor, temperature and neighbours. `cycles_per_edge_iter` is the primary
series; `ns_per_edge_iter` is reported alongside for sanity, not for comparison
across machines or governors.

**Counters are setup-subtracted.** Each measurement runs the binary twice, at N
trials and at 1 trial, and differences them. What remains is per-trial work with
graph loading removed.

## The tier ladder

Cost rises ~4x per step. Do not skip upward without a reason; do not stay at the
bottom past the point where the answer matters.

| Tier | Configuration | Cost | Question it answers |
| --- | --- | --- | --- |
| **A** | g24, one graph, 5 trials, wallclock only | ~35 s | Did it get faster? |
| **B** | g24, both graphs, 16 trials, + counters | ~8 min | Why did it get faster? |
| **C** | g27 (GAPBS standard), both graphs, + counters | hours | The number of record |
| **D** | twitter / web / road | + ~275 GB download | Does it hold on real graphs? |

Scale matters because the working set has to clear the last-level cache by enough
that the kernel is genuinely in DRAM:

```
L3 = 260 MiB = 0.254 GiB on this machine

  g22   0.30 GiB working set  ->  1.2x L3   too small: partly cache-resident
  g24   1.25 GiB              ->  4.9x L3   fast tier
  g25   2.50 GiB              ->  9.8x L3   fall back here if g24 mis-ranks
  g27   9.82 GiB              -> 38.7x L3   GAPBS standard
```

At 1.2x L3 a locality-improving change is flattered and a change that only pays at
real DRAM depth is penalised. Start at g24.

**Keep both synthetic graphs from tier B up.** They behave differently — `kron`'s
power-law degree distribution gives hub locality and lower achieved concurrency;
`urand` has no locality at all and exposes more independent misses. A change can
help one and hurt the other, and a single-graph tier hides that.

Tier D exists for a different reason: real-world graphs have skewed degree
distributions that `kron` only approximates and `urand` not at all. A change tuned
on synthetic data can fail there. It is a pre-publication check, not an iteration
check.

## The loop

1. **Baseline first, on the tier you are about to use.** Record it. A delta against
   a remembered number is not a measurement.
2. **Change one thing.**
3. **Tier A.** If it is inside the noise floor, it is not a result — either make the
   change bigger or stop.
4. **Tier B** when tier A says something moved. The counters say whether it moved
   for the reason you think: a change that was supposed to raise memory-level
   parallelism and instead raised IPC did something else.
5. **Tier C at checkpoints** — before landing, before claiming, and whenever tier B
   and your model disagree.
6. **Record the result either way.** A change that did not work is worth one line
   saying what was tried and what it measured, at the place someone would try it
   again. That line is cheaper than repeating the experiment.

## Validating the fast tier

A fast tier is only valid if it ranks changes the same way the slow tier does.
**Check this once, before the campaign, not per iteration.**

Take two or three builds known to differ — `-O2` against `-O3`, or two `-march`
values — and confirm g24 orders them the same as g27. If the ordering disagrees,
move the fast tier to g25 and re-check.

This is the step that gets skipped, and skipping it means every subsequent
iteration is fast and possibly wrong.

## Measurement identity

A number is comparable only to one taken with the byte-identical command, on the
same machine, in the same state. The driver stamps each run with compiler version,
flags, commit (marked DIRTY if the tree is not clean), CPU model, governor, THP
setting, SMT state and pinning. Before comparing two rows, diff their
`provenance.txt`.

**Set the governor before any A/B.** At `powersave` the frequency drifts between
runs and a small delta may be governor noise rather than the change:

```
sudo cpupower -c 1 frequency-set -g performance
```

The driver warns when the governor is not `performance`, but does not change it —
changing machine state silently would make old results incomparable without
anything in the record saying so.

## Noise floor

Measured run-to-run on this machine at `powersave`, same binary, same graph:

- `cycles_per_edge_iter` ~1.4%
- achieved MLP ~1%

**A delta under ~2% is not a result** until the governor is fixed and the run
repeated. Re-establish this floor after any change to machine state, and after
moving to a different tier.

## Hazards

Each of these produces a confident, wrong number rather than an error.

- **Graph too small.** Covered above. The failure is silent and directional.
- **Governor drift.** Wallclock moves, cycles do not — which is why cycles are the
  primary series.
- **File targets do not re-run.** Upstream's `benchmark/out/*.out` are ordinary make
  targets; a second invocation is a no-op and you will read a stale result. The
  `pagerank` recipes delete the output first.
- **Counter multiplexing.** More events than counters and perf time-slices them,
  scaling the results. The driver warns when enabled time is under 99.9%; do not
  add events to a group without checking.
- **Iteration count changes.** If a change alters convergence, per-trial time is no
  longer comparable. The CSV carries `iters` — check it moved with the change and
  not by accident.
- **A dirty tree.** Provenance marks it. A number from a dirty tree cannot be
  reproduced.

## Reference baseline

`-march=native`, serial, cpu 1, node 0, `powersave`, g22 (the tier since superseded
by g24 — kept as the first datapoint, not as a target):

| graph | edges | iters | cycles/edge/iter | IPC | MLP | % cyc w/ miss | LLC MPKI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kron | 64.2M | 6 | 17.26 | 0.667 | 7.97 | 99.1% | 3.12 |
| urand | 67.1M | 4 | 18.04 | 0.642 | 9.66 | 99.2% | 4.19 |

Both kernels spend ~99% of cycles with at least one miss outstanding: PageRank at
this scale is memory-bound, and the lever is concurrency, not instruction count.

## Commands

```
just pagerank-one <march> kron 5      # tier A
just pagerank <march>                 # tier B
just pagerank-standard <march>        # tier C
just pagerank-matrix "<march> ..."    # build matrix
just pagerank-summary                 # every result so far
bench/mlp-by-kernel.sh                # achieved MLP across all GAPBS kernels
```
