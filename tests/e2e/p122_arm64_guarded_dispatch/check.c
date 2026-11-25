/* P122 C driver: every function of gen_il.py against a C reference.
 * 512 rounds x n in [-1, 32] (34 bounds) per function; each round compares the
 * returned accumulator and all 32 trace slots (untouched slots must keep their
 * 0xa5 fill).  Selectors mix the table indices 0..3, the first index past the
 * table (4), "negative" words (0x80000000, 0xffffffff, other high-bit values)
 * and arbitrary 32-bit values; the accumulator wraps (mul 17, add, sub). */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef uint32_t Fn(uint32_t *, uint32_t *, int, uint32_t);
extern Fn guarded, guarded_rev, dual_bigfirst, dual_bigsecond, reshare, cap31, c_guardcall, c_tablecall,
    c_longguard, c_longtable, c_bigtable, c_sharedtable, c_twopreds, c_noloop;

static unsigned long opaque_calls;

/* Called from c_guardcall / c_tablecall; always 0. */
uint32_t p122_opaque(uint32_t x)
{
    opaque_calls++;
    return x & 0;
}

static uint32_t arm(uint32_t acc, uint32_t op, int *stay)
{
    *stay = op == 0 || op == 2;
    switch (op) {
    case 0: case 2: return acc + op;
    case 1: return acc * 17u;
    case 3: return acc ^ 123u;
    default: return acc - op;
    }
}

/* kind 0: the loop of `guarded`; 1: c_twopreds (only @a stays in the loop);
 * 2: c_noloop; 3: dual_* (selector 4 or i >= n leaves); 4: cap31; 5: reshare. */
static uint32_t ref(int kind, const uint32_t *src, uint32_t *trace, int n, uint32_t acc)
{
    int stay;
    if (kind == 3) {
        for (int i = 0;; ++i) {
            uint32_t sel = i < n ? src[i & 31] : 4u;
            if (sel == 4u)
                return acc;
            acc = arm(acc, sel, &stay);
            trace[i & 31] = acc;
        }
    }
    if (kind == 5) {
        int i = 0, at_b = 0;
        for (;;) {
            if (!at_b) {
                if (!(i < n))
                    return acc;
                switch ((uint32_t)i % 3u) {
                case 0: acc ^= 1u; break;
                case 1: acc += 7u; break;
                default: acc *= 5u; break;
                }
            } else {
                acc ^= 1u;
            }
            uint32_t op = src[i & 31], x = ((i & 1) ? op : op >> 1) & 3u;
            uint32_t sel = i < n ? x : 3u;
            int slot = i & 31;
            i++;
            switch (sel) {
            case 0: acc += sel; at_b = 1; break;
            case 1: acc *= 17u; at_b = 1; break;
            case 2: acc ^= 123u; at_b = 0; break;
            default: acc -= op; at_b = 0; break;
            }
            trace[slot] = acc;
        }
    }
    if (kind == 4) {
        for (int i = 0; i < n; ++i) {
            uint32_t sel = src[i] & 31u;
            acc = sel < 31u ? acc * (2u * sel + 3u) + sel : acc - src[i];
            trace[i] = acc;
        }
        return acc;
    }
    if (kind == 2) {
        switch (src[0] & 3u) {
        case 0: acc *= 3u; break;   /* entry 0 -> @p1 */
        case 1: acc ^= 5u; break;   /* entry 1 -> @p2 */
        default: acc += 1u; break;  /* default -> @p0 */
        }
        if (!(0 < n))
            return acc;
        trace[0] = acc;
        return arm(acc, src[0], &stay);
    }
    for (int i = 0; i < n; ++i) {
        acc = arm(acc, src[i], &stay);
        trace[i] = acc;
        if (kind == 1 && !stay)
            return acc;
    }
    return acc;
}

static const struct { const char *name; Fn *fn; int kind; } fns[] = {
    {"guarded", guarded, 0}, {"guarded_rev", guarded_rev, 0},
    {"dual_bigfirst", dual_bigfirst, 3}, {"dual_bigsecond", dual_bigsecond, 3},
    {"reshare", reshare, 5}, {"cap31", cap31, 4},
    {"c_guardcall", c_guardcall, 0}, {"c_tablecall", c_tablecall, 0},
    {"c_longguard", c_longguard, 0}, {"c_longtable", c_longtable, 0},
    {"c_bigtable", c_bigtable, 0}, {"c_sharedtable", c_sharedtable, 0},
    {"c_twopreds", c_twopreds, 1}, {"c_noloop", c_noloop, 2},
};

int main(void)
{
    uint32_t src[32], got[32], want[32], seed = 0;
    unsigned long checks = 0, bad = 0;
    for (int k = 0; k < 512; ++k) {
        for (int i = 0; i < 32; ++i) {
            seed = seed * 1664525u + 1013904223u;
            switch (seed >> 29) {
            case 0: case 1: case 2: src[i] = (seed >> 7) & 3u; break;
            case 3: src[i] = 4u; break;
            case 4: src[i] = (seed & 1u) ? 0xffffffffu : 0x80000000u; break;
            case 5: src[i] = seed | 0x80000000u; break;
            default: src[i] = seed; break;
            }
        }
        for (unsigned f = 0; f < sizeof fns / sizeof fns[0]; ++f) {
            for (int n = -1; n <= 32; ++n) {
                memset(want, 0xa5, sizeof want);
                memset(got, 0xa5, sizeof got);
                uint32_t r = ref(fns[f].kind, src, want, n, seed);
                uint32_t g = fns[f].fn(src, got, n, seed);
                checks++;
                if (g != r || memcmp(want, got, sizeof got)) {
                    if (bad++ < 8)
                        printf("BAD %s round %d n %d: got %u want %u\n", fns[f].name, k, n, g, r);
                }
            }
        }
    }
    printf("checks %lu bad %lu opaque %s\n", checks, bad, opaque_calls ? "called" : "never called");
    return bad != 0;
}
