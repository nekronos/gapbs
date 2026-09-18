/* Occupancy-counter validator.
 *
 * A performance counter named like an outstanding-miss counter is not
 * necessarily one. An *occupancy* counter accumulates outstanding misses per
 * cycle, so dividing it by cycles gives the average number in flight; an
 * *allocation* counter counts fills and gives a rate. They have similar names
 * on both vendors and reading the wrong one silently produces a plausible,
 * meaningless figure.
 *
 * This chases K independent pointer cycles through a buffer larger than LLC.
 * With K lanes the core has K independent misses available, so a true
 * occupancy counter divided by cycles reads ~K (until the hardware ceiling).
 * Anything that does not track K is not an occupancy counter.
 *
 * Env: VC_LANES (1), VC_BYTES (1 GiB), VC_HITS (8M)
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>

#define LINE 64
#define STRIDE (LINE / (int)sizeof(uint64_t))
#define MAXLANES 256

static size_t envz(const char *n, size_t d) {
  const char *v = getenv(n); return (v && *v) ? strtoull(v, NULL, 10) : d;
}

int main(void) {
  size_t lanes = envz("VC_LANES", 1);
  size_t bytes = envz("VC_BYTES", (size_t)1 << 30);
  size_t hits  = envz("VC_HITS", 8ull << 20);
  if (lanes < 1 || lanes > MAXLANES) { fprintf(stderr, "VC_LANES 1..%d\n", MAXLANES); return 1; }

  size_t nslots = bytes / LINE;
  size_t nelem  = nslots * STRIDE;
  uint64_t *a = mmap(NULL, nelem * sizeof(uint64_t), PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (a == MAP_FAILED) { perror("mmap"); return 1; }
  madvise(a, nelem * sizeof(uint64_t), MADV_HUGEPAGE);
  memset(a, 0, nelem * sizeof(uint64_t));

  uint64_t *perm = malloc(nslots * sizeof(uint64_t));
  for (size_t i = 0; i < nslots; i++) perm[i] = i;
  uint64_t rs = 0x9E3779B97F4A7C15ull;
  for (size_t i = nslots - 1; i > 0; i--) {
    rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17;
    size_t j = rs % (i + 1);
    uint64_t t = perm[i]; perm[i] = perm[j]; perm[j] = t;
  }

  uint64_t start[MAXLANES];
  size_t chunk = nslots / lanes;
  for (size_t c = 0; c < lanes; c++) {
    size_t s = c * chunk, e = s + chunk;
    for (size_t j = s; j + 1 < e; j++) a[perm[j] * STRIDE] = perm[j + 1] * STRIDE;
    a[perm[e - 1] * STRIDE] = perm[s] * STRIDE;
    start[c] = perm[s] * STRIDE;
  }
  free(perm);

  uint64_t p[MAXLANES], sink = 0;
  for (size_t c = 0; c < lanes; c++) p[c] = start[c];
  size_t steps = hits / lanes; if (!steps) steps = 1;
  for (size_t k = 0; k < steps; k++)
    for (size_t c = 0; c < lanes; c++) p[c] = a[p[c]];
  for (size_t c = 0; c < lanes; c++) sink += p[c];
  if (sink == 0x123456789ull) fprintf(stderr, "\n");
  return 0;
}
