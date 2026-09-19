# PageRank performance iteration workflow

## Target microarchitecture: AMD Zen 5

**Read the optimization guide before changing code.** Software Optimization
Guide for the AMD Zen5 Microarchitecture, AMD doc **58455** rev 1.00 — see
`docs/README.md` for where to get it. Optimising a memory-bound kernel against
a guessed machine model wastes whole measurement cycles; the guide is a few
hours and it is the cheapest input to this campaign.

For this workload specifically, the sections that decide what is worth trying:

- **Load/store unit** — loads per cycle, store queue depth, and how many
  outstanding cache misses a core sustains (the Miss Address Buffers). PageRank
  is concurrency-limited, so this ceiling sets what any change can reach.
- **Cache hierarchy and topology** — L1D/L2 per core and L3 per CCD. The tier
  scales below are derived from the L3 a single core can see — 32 MiB on the
  target part; see "The machines".
- **Hardware prefetchers** — which patterns they detect. Graph traversal defeats
  most of them; knowing which are active decides whether software prefetch is
  worth trying.
- **Software prefetch guidance** — distance, which instruction form, and when
  AMD says it hurts. This is the chapter the campaign turns on; "The lever"
  below says why.
- **TLB and large pages** — DTLB reach against the working set. At multi-GiB
  footprints page-walk traffic competes with the kernel for the same miss
  capacity.
- **Instruction latency and throughput tables** — for reading a disassembly
  diff, not for driving the change.

### The baselines in this document are Intel, not Zen 5

Everything measured so far ran on an Intel Xeon Platinum 8558U (Emerald Rapids).
Three things do not carry over and must be re-established on the target part
before any Zen 5 result is trusted:

- **Tier scales.** The ladder was first sized against a 260 MiB L3. It is
  recomputed below against the 32 MiB a single core sees on both AMD machines
  under the fair pinning; the multiples changed, the tier assignments did not.
- **Counters.** `L1D_PEND_MISS.PENDING` and `.PENDING_CYCLES` are Intel events.
  The AMD equivalent for outstanding-miss occupancy is a Miss Address Buffer
  event (`ls_alloc_mab_count` on recent parts); confirm the name against the PPR
  for the exact model, and validate it by construction — a true occupancy
  counter reads ~1 at one outstanding miss and ~8 at eight, not an allocation
  rate. Still to do, on both machines.
- **Noise floor.** Re-measure it on each machine; do not carry the Intel figure
  over. Still to do.

The machines are now in the loop (next section). The numbers already in this
document — the reference baseline, the noise floor, the tier costs — are Intel
numbers that exercised the harness. They are not the campaign.

How to change PageRank and know whether it actually got faster, on one
microarchitecture, without being fooled by a cheap measurement.

Everything below was calibrated on the machine in `bench/results/*/provenance.txt`
unless a section says otherwise; re-derive the numbers on a different part before
trusting them.

## The machines

Addresses are set in `bench/hosts.conf`, which is not in version control; see
`bench/hosts.conf.example`. Referred to below as `$ZEN5_HOST` and `$ZEN4_HOST`.

Two single-socket desktop parts. Both run NixOS 26.11 (Zokor), kernel 6.18.41,
SMT on, governor already `performance`, ~125 GiB RAM, 16 cores / 32 threads.

| Role | Machine | CPU | L3 |
| --- | --- | --- | --- |
| **Target** — the only one optimised for | `$ZEN5_HOST` | AMD Ryzen 9 9950X (Zen 5) | 64 MiB total, **32 MiB per CCD** |
| **Reference** — separates Zen 5-specific gains from general ones | `$ZEN4_HOST` | AMD Ryzen 9 7950X3D (Zen 4) | 128 MiB total, **asymmetric** |

The reference exists to *classify* a gain, not to gate it: a change that helps
Zen 5 and not Zen 4 is a microarchitecture-specific gain, one that helps both is
general. Either is accepted on the target's numbers alone — "End condition" has
the rule.

### CCD topology, and the trap in it

A core sees only its own CCD's L3. The two parts differ here, and the difference
is silent:

| Part | CCD0 (cpus 0-7, 16-23) | CCD1 (cpus 8-15, 24-31) |
| --- | --- | --- |
| Zen 5 9950X | 32 MiB | 32 MiB |
| Zen 4 7950X3D | **96 MiB** (3D V-Cache) | 32 MiB |

Pinned to a Zen 4 V-Cache core, the reference compares 96 MiB of L3 against the
target's 32 MiB, and "Zen 5 vs Zen 4" is confounded with "32 MiB vs 96 MiB of
cache". Nothing errors; the working-set multiples in the tier ladder are simply
a third of what the table says.

**The fair reference pinning is Zen 4 CCD1 — `taskset -c 8` — matching the
32 MiB a Zen 5 core sees.** On Zen 5 the CCDs are uniform, so any core sees 32 MiB; **cpu 8 is used there too**, so a single pinning applies to both machines and the runner needs no per-host special case. This keeps the
existing convention. Pinning to a V-Cache core is a separate, deliberate
experiment (what does 3x the L3 buy this kernel?), never the default. Every
result records which CCD it was pinned to; a row without that is not comparable
to anything.

### Build target: each machine is built for itself

The target is built `-march=znver5`, the reference `-march=znver4`. What is
compared between the two machines is the **delta a source change produces on
each**, and compiler flags are held fixed within a machine across iterations, so
that delta is uncontaminated even though the two binaries differ. Forcing one
common binary would protect against a confound that only matters for an absolute
cross-machine ratio, which is not a quantity this campaign uses -- and it would
risk `znver4` code generation on Zen 5 scheduling prefetches worse than `znver5`
would, suppressing the very effect being hunted.

The residual risk is that a source change interacts with code generation
differently on the two targets, so a gain labelled Zen 5-specific is partly a
compiler artefact. It is detectable: rebuild both at one common ISA with
`--march` and see whether the classification survives. Do that before any
Zen 5-specific claim leaves the campaign.

### Toolchain: build once per target, ship the binary

Neither machine has clang, gcc, perf or numactl installed. Consequences:

- **Build centrally, ship binaries.** `shell.nix` in the repo root gives the
  build host its compiler; compile once there and `scp` the same binary to both
  machines. That is the point, not a workaround: the byte-identical binary on
  two parts isolates microarchitecture from code generation. Record the binary's
  checksum with the result. Ship `converter` alongside `pr` and generate the
  graphs on each machine — the generator is seeded (`kRandSeed`), so the same
  binary produces the same graph everywhere, and g27 is too large to copy
  around.
- **perf cannot be shipped** — it is coupled to the running kernel. Get it on
  each machine as needed: `nix-shell -p linuxPackages.perf --run '...'`
  (perf 7.1.5 on both).
- **numactl is absent and not needed.** Single socket, one memory node: there is
  nothing for `--membind` to choose, and `taskset` pinning alone is sufficient.
  `taskset` is present on both.

The driver compiles in place and wraps every run in `numactl --membind`; on
these machines it needs a prebuilt-binary path and the `numactl` wrapper dropped
before the recipes in "Commands" run as written.

## What is measured

**One core.** Serial build, no OpenMP, pinned with `taskset` to one core on a
recorded CCD (single socket, so there is no NUMA node to bind). Thread scheduling
noise is larger than most microarchitectural effects,
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
that the kernel is genuinely in DRAM. The L3 that matters is the one the pinned
core can see: 32 MiB on both machines under the fair pinning ("The machines"),
96 MiB on the Zen 4 V-Cache CCD if that experiment is run.

```
per-core visible L3:  32 MiB = 0.03125 GiB   Zen 5, either CCD; Zen 4 CCD1
                      96 MiB = 0.09375 GiB   Zen 4 CCD0 (V-Cache) -- not the default

  working set (CSR + PageRank arrays)     32 MiB    96 MiB
  g22   0.30 GiB                            9.6x      3.2x
  g24   1.25 GiB                           40x       13.3x   fast tier
  g25   2.50 GiB                           80x       26.7x   fall back here if g24 mis-ranks
  g27   9.82 GiB                          314x      105x     GAPBS standard
```

The earlier worry that g22 was partly cache-resident was a 260 MiB Intel L3
problem (1.2x); at 9.6x of a 32 MiB L3 it does not apply here. g24 stays the fast
tier anyway: it also clears the Zen 4 V-Cache CCD's 96 MiB by ~13x, so one tier
serves both the default pinning and the V-Cache experiment, where g22 at 3.2x
would be back in the regime that flatters a locality-improving change and
penalises one that only pays at real DRAM depth. Start at g24.

The costs in the table were timed on the Intel machine; re-time them on the
target before planning a campaign around them.

**`urand` was wrongly written off as a non-target, 2026-09-18 — corrected
2026-09-19.** This section previously recorded that `urand` could not benefit
from prefetching because it already sustained 49.9 of the 64 demand slots and
had no headroom to fill. That explanation was wrong, and the measurement behind
it was of code that never ran.

`urand` is uniform-random with Poisson(16) degrees. The within-vertex prefetch
splits the loop at `last - D` and fires only for vertices with more than `D`
neighbours. At D=96 that is P = 8.8e-43 — an expected **1e-34** vertices out of
134 million. The prefetch never executed once. The flat ~0.98 attributed to "no
headroom" was the restructured loop's overhead with zero prefetches issued.

Once the flat-CSR prefetch made it fire on every edge, `urand` gained **20.4%**.

**The tell was in the data and was read past.** `urand` sat at 0.979–0.982
across a 100x range of `D`. A parameter spanning two orders of magnitude with no
effect is evidence that the parameter is not reaching the code, before it is
evidence about the machine. Check that a knob is connected before explaining
why the hardware ignores it.

**Keep both synthetic graphs from tier B up.** They behave differently — `kron`'s
power-law degree distribution gives hub locality and lower achieved concurrency;
`urand` has no locality at all and exposes more independent misses. A change can
help one and hurt the other, and a single-graph tier hides that.

Tier D exists for a different reason: real-world graphs have skewed degree
distributions that `kron` only approximates and `urand` not at all. A change tuned
on synthetic data can fail there. It is a pre-publication check, not an iteration
check.

## The lever: software prefetch and the miss-handling budget

PageRank at these scales spends ~99% of its cycles with a miss outstanding
("Reference baseline"), so the quantity being bought is misses in flight, and
the ceiling on that is the core's miss-handling budget. On Zen 5 the budget has
two parts:

| | Outstanding misses | Reached by |
| --- | --- | --- |
| Total the core can sustain | **124** | demand loads and software prefetch together |
| Reachable by demand loads alone | **64** | every in-flight demand load holds a load-queue slot |
| Reachable only by software prefetch | the remaining 60 | prefetch instructions take no load-queue slot |
| PageRank today | **~8** (`kron`) to ~10 (`urand`) | measured on Intel; re-measure on Zen 5 before anything else |

Against a 124 ceiling, ~8 in flight is a very large headroom gap — and the
demand-load path, which is all that ordinary code changes (unrolling, layout,
`-march`) can work on, caps out at 64. Everything above that is reachable only
through software prefetch instructions. That makes **software prefetching the
primary lever of this campaign, not a micro-optimisation**: it is the only way
past the load-queue limit, and the budget it unlocks is about as large as the
one demand loads can use at all.

Before writing the first prefetch, study the load-optimisation chapter of AMD
doc 58455 — specifically its prefetch guidance: prefetch distance (how far ahead
of the consuming load to issue, and what that depends on), which instruction
form to use, and the cases where AMD says prefetching hurts. The indirect gather
of neighbour contributions through the CSR index is the access the hardware
prefetchers cannot follow (see the prefetchers bullet under "Target
microarchitecture"); that is where the headroom is. The sequential CSR walk
itself is not.

**Measurement consequence.** Achieved MLP — outstanding misses per cycle with a
miss, from the validated occupancy counter — is the *leading indicator*: a
prefetch change that worked raises it, and one that did not (wrong distance,
prefetches dropped, lines evicted before use) leaves it flat or lowers it.
`cycles_per_edge_iter` is the *outcome*. Read both at tier B, in that order: MLP
says whether the mechanism engaged, cycles say whether it paid. A cycles gain
with flat MLP came from somewhere else and should be understood before it is
kept.

## The loop

Every step runs on the target (Zen 5) first. The reference (Zen 4, CCD1) sees
the same binary at step 5, to classify the result.

1. **Baseline first, on the tier you are about to use.** Record it. A delta against
   a remembered number is not a measurement.
2. **Change one thing.**
3. **Tier A.** If it is inside the noise floor, it is not a result — either make the
   change bigger or stop.
4. **Tier B** when tier A says something moved. The counters say whether it moved
   for the reason you think: a change that was supposed to raise memory-level
   parallelism and instead raised IPC did something else. For a prefetch change,
   achieved MLP is that check ("The lever").
5. **Same binary on the reference**, tier B. Zen 4 up: the gain is general. Zen 4
   flat or down: it is Zen 5-specific. The decision was already made at step 4;
   this step labels it.
6. **Accept or reject** by the rule in "End condition", then check the stopping
   rule there.
7. **Tier C at checkpoints** — before landing, before claiming, and whenever tier B
   and your model disagree.
8. **Record the result either way**, with the CCD it was pinned to and the
   binary's checksum. A change that did not work is worth one line saying what
   was tried and what it measured, at the place someone would try it again. That
   line is cheaper than repeating the experiment.

## Approaches to test

Ordered by how directly they attack the miss-handling budget. **Software
prefetch is required, not optional** — it is the only technique that reaches
past the 64-slot demand-load ceiling, so a campaign that did not test it would
have left the main lever untried.

### 1. Software prefetch, carefully placed (required)

`Neighborhood::iterator` is a raw `NodeID*`, so the neighbour list is directly
indexable and the lookahead needs no container gymnastics:

```cpp
auto nb = g.in_neigh(u);
const NodeID *first = nb.begin(), *last = nb.end();
for (const NodeID *p = first; p < last; ++p)
  incoming_total += outgoing_contrib[*p];          // the random gather
```

Two implementation notes. **Sweep `D` by rebuilding, not by branching** — pass
it as `-DPR_PREFETCH_DIST=N` so the compiler sees a constant and `N=0` compiles
back to the unmodified loop, which keeps the baseline honest. And **split the
loop rather than bounds-checking inside it**: a `p + D < last` test in the
gather adds a branch between the independent loads, which is the one thing
measured to cost achieved MLP. Run the main body to `last - D` and handle the
tail separately.

Pull-direction PageRank gathers `outgoing_contrib[v]` for every in-neighbour
`v` of `u` (not `scores[]` — `scores[u]` is written sequentially in `u` and
streams).
The neighbour list is contiguous, so the addresses of future gathers are
readable well before the gathers themselves issue. That is the property
prefetching needs, and it is why this kernel is a good fit for the technique.

Two distinct sites, to be tested separately before being combined:

- **Within a vertex.** While processing neighbour `i`, prefetch
  `outgoing_contrib[neigh[i + D]]`. `D` is the prefetch distance and the primary
  knob:
  too short and the line has not arrived, too long and it is evicted or the
  prefetch is wasted on a vertex whose scan ends first. Sweep `D`; do not guess
  it. Short neighbour lists are the hazard — a power-law graph like `kron` has
  many vertices with fewer than `D` neighbours, where every prefetch is waste.
- **Across vertices.** While processing `u`, prefetch the head of `u+1`'s
  neighbour list and its offset entry, so the next vertex's scan does not begin
  with a cold miss.

Variants that need measuring rather than assuming: the temporal hint
(`_mm_prefetch` `_MM_HINT_T0/T1/T2/NTA`), whether prefetching the offsets array
pays separately from the contribution array, and whether a prefetch issued for an
already-resident line costs more than it saves. Consult doc 58455's
load-optimisation chapter for AMD's guidance on form, distance and the cases
where it says prefetching hurts — then measure, because the guide describes the
machine, not this access pattern.

The measurement signature of a prefetch that worked: achieved MLP rises while
`cycles_per_edge_iter` falls. MLP rising with cycles flat means the prefetches
are issuing but not covering demand misses — wrong distance, or the wrong lines.

### 2. Data layout and working-set reduction

Narrowing the score type, reordering vertices for locality, or blocking the scan
so a slice of `scores[]` stays resident. These reduce the misses rather than
overlapping them, so they compose with prefetching rather than competing.

### 3. Loop structure

Unrolling or interleaving several vertices' gathers to expose more independent
misses to the demand path. This is capped by the 64-slot load queue, which is
precisely why it cannot substitute for prefetching.

## End condition

The loop has a stopping rule, written down before iteration 1, so it does not
run until someone loses interest. Four parts: the first two are the real ones,
the third is the backstop, the fourth is what each iteration is judged by.

**1. Diminishing returns (primary).** Stop when three consecutive iterations —
accepted or rejected — each moved `cycles_per_edge_iter` on the target graph by
less than 2%. 2% is the measured noise floor, so below it nothing is
distinguishable from noise. Three in a row rather than one, because a single
flat iteration is usually a bad idea rather than an exhausted lever.

**2. Headroom (secondary).** The quantity being bought is misses held *past the
load queue*, so the headroom signals are `pct_ge64` and IPC — **not mean MLP**.
Stop when either:

- `pct_ge64` exceeds ~80%, i.e. the kernel is above the demand-load ceiling on
  most cycles and little room remains between there and the part's limit; or
- `pct_cyc_miss` falls well below ~99%, i.e. the kernel is no longer
  miss-bound and the next lever is a different one — a new campaign with its own
  baseline, not another iteration of this one.

> **Do not stop on mean MLP.** Iteration 1 *lowered* it, 35.66 to 27.92, while
> cutting cycles 14% and raising IPC 51%. Prefetch converts demand misses into
> hits — the line arrives before the load issues — so occupancy-cycles per edge
> fell a third even as the kernel got faster and reached deeper bursts. A rule
> written on mean MLP scores that a failure. It is a mechanism indicator, and a
> falling mean beside a rising `pct_ge64` is the signature of prefetch working,
> not failing.

**3. Hard caps.** So the loop terminates even if neither of the above trips:

| Cap | Value | Counts |
| --- | --- | --- |
| Iterations | 24 | every change tried, accepted or rejected |
| Wall clock | 10 working days from the first Zen 5 baseline | calendar time, including baselines, noise-floor and fast-tier validation |

Whichever trips first ends the loop. The values are set at campaign start and
recorded alongside the baseline; they change between campaigns, never mid-loop,
because a cap that moves when it is about to trip is not a cap.

**4. Per-iteration accept/reject.** A change is accepted only if it beats the
noise floor on the target machine at tier B: `cycles_per_edge_iter` down by more
than the floor on both synthetic graphs, or on one with the other flat. A change
that trades `kron` against `urand` is not accepted without a written reason. The
reference machine does not vote:

| Zen 5 (target) | Zen 4 (reference, CCD1) | Verdict | Label |
| --- | --- | --- | --- |
| better | better | accepted | *general* |
| better | flat or **worse** | accepted | *Zen 5-specific* |
| flat or worse | anything | rejected | — |

The second row is the one to be deliberate about. It still lands — Zen 5 is the
only target — but the label is what says the gain came from the
microarchitecture (its miss budget, its prefetch handling) rather than from the
code being better in general, and a later reader needs that to know whether to
expect it anywhere else. The Zen 4 reference exists to *classify* gains, not to
gate them; gating on it would optimise for the average of two parts, and the
campaign has one target.

When the loop ends, the last accepted binary goes through tier C on both
machines and that row is the number of record. The criterion that tripped, and
the values it tripped at, are written into the results log next to it.

## Validating the fast tier

> **Measured, 2026-09-18: g24 fails this check.** The same binary sustains
> MLP 16.0 on kron at g24 and 35.7 at g27 — less than half the concurrency,
> despite g24 clearing L3 by 40x and being memory-bound on 99% of cycles.
> Working-set multiples predict whether a kernel is memory-bound, not how much
> concurrency is available to it. Move the fast tier to g25 or above and redo
> the ranking check against g27 before trusting a tier-B accept.



A fast tier is only valid if it ranks changes the same way the slow tier does.
**Check this once, before the campaign, not per iteration.**

Take two or three builds known to differ — `-O2` against `-O3`, or two `-march`
values — and confirm g24 orders them the same as g27. If the ordering disagrees,
move the fast tier to g25 and re-check. Do this on the target, under the fair
pinning; the Intel validation does not carry over, and it counts against the
wall-clock cap.

This is the step that gets skipped, and skipping it means every subsequent
iteration is fast and possibly wrong.

## Measurement identity

A number is comparable only to one taken with the byte-identical command, on the
same machine, on the same CCD, in the same state. The driver stamps each run with
compiler version, flags, commit (marked DIRTY if the tree is not clean), CPU
model, governor, THP setting, SMT state and pinning. Before comparing two rows,
diff their `provenance.txt`.

The shipped-binary setup adds two things to the identity. The compiler fields
describe the build host, not the measuring machine, so they travel with the
binary; and the binary's checksum is what ties a Zen 5 row to its Zen 4 row —
two rows with different checksums are two experiments, not one comparison. The
pinned cpu is already stamped; on Zen 4 read it as a CCD (cpus 8-15 and 24-31
are the 32 MiB CCD) and treat a row from the other CCD as a different machine.

**Check the governor before any A/B.** Both machines are already at
`performance`; the check stays because at `powersave` the frequency drifts
between runs and a small delta may be governor noise rather than the change:

```
cat /sys/devices/system/cpu/cpu1/cpufreq/scaling_governor
sudo cpupower -c 1 frequency-set -g performance    # only if it is not
```

The driver warns when the governor is not `performance`, but does not change it —
changing machine state silently would make old results incomparable without
anything in the record saying so.

## Noise floor

Measured run-to-run on the Intel machine at `powersave`, same binary, same graph:

- `cycles_per_edge_iter` ~1.4%
- achieved MLP ~1%

**A delta under ~2% is not a result** until the governor is fixed and the run
repeated. Re-establish this floor after any change to machine state, and after
moving to a different tier — and once per machine before the campaign. The 2%
that the accept rule and the diminishing-returns stop in "End condition" both use
is this figure, and it is owed a Zen 5 measurement at `performance` under the
fair pinning before either rule is applied.

## Hazards

Each of these produces a confident, wrong number rather than an error.

- **Graph too small.** Covered above. The failure is silent and directional.
- **Wrong CCD on the reference.** Pinned to a Zen 4 V-Cache core the working set
  sees 96 MiB of L3, not 32 MiB, and every tier multiple is a third of what the
  ladder says. Nothing errors. `taskset -c 8` is the default; a V-Cache row is
  labelled as the experiment it is.
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
- **Counters differ by vendor.** The driver's event names are Intel. On AMD they
  will either error or, worse, resolve to a similarly-named event measuring
  something else. Validate any occupancy counter by construction before quoting
  a number from it.
- **Different binaries on the two machines.** A binary compiled on each machine
  (`-march=native` resolves to a different target on each) compares code
  generation as well as microarchitecture. Ship one binary; check the checksum
  in both rows.
- **A `-march` the reference cannot execute.** Each machine is built for itself
  -- `znver5` on the target, `znver4` on the reference -- so this does not arise
  in normal use. It does if `--march` is used to force one common binary: a
  `znver5` build can fault on the 7950X3D. Forcing a common ISA is a deliberate
  cross-check, not the default.

## Reference baseline

Intel Xeon Platinum 8558U, `-march=native`, serial, cpu 1, node 0, `powersave`,
g22 (the tier since superseded by g24 — kept as the first datapoint, not as a
target). The Zen 5 and Zen 4 CCD1 baselines replace this table once they exist:

| graph | edges | iters | cycles/edge/iter | IPC | MLP | % cyc w/ miss | LLC MPKI |
| --- | --- | --- | --- | --- | --- | --- | --- |
| kron | 64.2M | 6 | 17.26 | 0.667 | 7.97 | 99.1% | 3.12 |
| urand | 67.1M | 4 | 18.04 | 0.642 | 9.66 | 99.2% | 4.19 |

Both kernels spend ~99% of cycles with at least one miss outstanding: PageRank at
this scale is memory-bound, and the lever is concurrency, not instruction count.
The MLP column is the ~8 that "The lever" sets against a budget of 124.

## Commands

On the build host (`nix-shell` in the repo root):

```
just pagerank-one <march> kron 5      # tier A
just pagerank <march>                 # tier B
just pagerank-standard <march>        # tier C
just pagerank-matrix "<march> ..."    # build matrix
just pagerank-summary                 # every result so far
bench/mlp-by-kernel.sh                # achieved MLP across all GAPBS kernels
```

Shipping a build to the two machines and pinning it there:

```
sha256sum bench/build/<march>/pr                          # goes in the result row
scp bench/build/<march>/{pr,converter} "$ZEN5_HOST":   # target, Zen 5
scp bench/build/<march>/{pr,converter} "$ZEN4_HOST":      # reference, Zen 4

./converter -g24 -k16 -b kron-g24.sg    # once per machine; seeded, so identical everywhere

# target: cpu 8 -- CCDs are uniform on Zen 5, so this matches the reference pinning
nix-shell -p linuxPackages.perf --run 'perf stat -e <events> -- taskset -c 8 ./pr -f kron-g24.sg ...'
# reference: cpu 8 -- CCD1, the 32 MiB one. cpus 0-7 / 16-23 are the 96 MiB V-Cache CCD.
nix-shell -p linuxPackages.perf --run 'perf stat -e <events> -- taskset -c 8 ./pr -f kron-g24.sg ...'
```

The `just` recipes assume a local compiler and `numactl`, which the two machines
do not have; until the driver grows a prebuilt-binary mode they are build-host
commands and the measurement side is the block above.
