#!/bin/sh
# P102: Regression test for the 9 Lean-verified QBE backend codegen optimizations:
#   1. x86-64 cmp $0, %r -> test %r, %r
#   2. x86-64 Kl shl $1/$2/$3 folded into SIB scale 2/4/8 (+ disp32 overflow & CAddr guards)
#   3. x86-64 intra-function short branch rel8 relaxation + reloc shift + >127B long fallback
#   4. x86-64 multi-byte NOP alignment padding
#   5. x86-64 accumulator ALU imm32 short form (05 + 8*g)
#   6. AArch64 prologue/epilogue callee-saved stp/ldp pairing (emit.c & macho.c)
#   7. x86-64 cross-BB SIB index reconstruction (rematindex) + dead shift elimination
#   8. x86-64 short-branch rel8 layout solver with 16-byte loop alignment (relaxloops)
#   9. x86-64 adjacent single-use integer load folding into cmp (foldcompareloads) + safety guards
set -eu

PIONC="${1:-}"
: "$PIONC"
ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
QBE="${PION_QBE:-$ROOT_DIR/out/qbe}"
CC="${CC:-cc}"

if [ ! -x "$QBE" ]; then
  echo "FAIL: QBE binary not found at $QBE" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/opts.ssa" <<'EOF'
data $gval = align 8 { l 1000 }
export data $sib_table = align 8 { l 77 }

export function l $helper(l %x) {
@start
  %r =l add %x, 7
  ret %r
}

# Opt 1: register compare against zero -> test %r, %r
export function l $opt1_cmp0(l %a, w %b) {
@start
  %c1 =w ceql %a, 0
  %c2 =w csltl %a, 0
  %c3 =w cnew %b, 0
  %c4 =w csgew %b, 0
  %s1 =w add %c1, %c2
  %s2 =w add %s1, %c3
  %s3 =w add %s2, %c4
  %res =l extsw %s3
  ret %res
}

# Opt 2: shlq $1/$2/$3 folded into SIB scale 2/4/8, plus live-use preservation
export function l $opt2_sib(l %p16, l %p32, l %p64, l %idx) {
@start
  %o1 =l shl %idx, 1
  %a1 =l add %p16, %o1
  %v1 =w loaduh %a1
  %v1l =l extuw %v1

  %o2 =l shl %idx, 2
  %a2 =l add %p32, %o2
  %v2 =w loaduw %a2
  %v2l =l extuw %v2

  %o3 =l shl %idx, 3
  %a3 =l add %p64, %o3
  %v3 =l loadl %a3

  # Keep %o3 live in another computation to ensure use-count safety
  %s1 =l add %v1l, %v2l
  %s2 =l add %s1, %v3
  %s3 =l add %s2, %o3
  ret %s3
}

# Opt 2 regression A: scaled disp32 overflow (0x20000000 << 3 == 0x100000000) must NOT truncate to disp32=0
export function l $opt2_sib_wide(l %p, l %i) {
@start
  %j =l add %i, 536870912
  %s =l shl %j, 3
  %a =l add %p, %s
  %v =l loadl %a
  ret %v
}

# Opt 2 regression B: scaled symbol address ($sib_table << 3) must NOT drop CAddr relocation
export function l $opt2_sib_sym(l %p, l %i) {
@start
  %j =l add %i, $sib_table
  %s =l shl %j, 3
  %a =l add %p, %s
  %v =l loadl %a
  ret %v
}

# Opt 3A: short branch relaxation + relocation offset adjustment after short branches
export function l $opt3_short_br(l %x) {
@start
  %c =w csltl %x, 0
  jnz %c, @neg, @pos
@neg
  %nx =l sub 0, %x
  %n =l call $helper(l %nx)
  jmp @done
@pos
  %px =l add %x, 1
  %n2 =l call $helper(l %px)
@done
  %v =l phi @neg %n, @pos %n2
  %g =l loadl $gval
  %out =l add %v, %g
  ret %out
}

# Opt 3B: branch spanning >127 bytes must remain rel32 and execute accurately
export function l $opt3_long_br(l %x) {
@start
  %c =w csltl %x, 0
  jnz %c, @far_neg, @pos
@pos
  %a0 =l call $helper(l %x)
  %a1 =l call $helper(l %a0)
  %a2 =l call $helper(l %a1)
  %a3 =l call $helper(l %a2)
  %a4 =l call $helper(l %a3)
  %a5 =l call $helper(l %a4)
  %a6 =l call $helper(l %a5)
  %a7 =l call $helper(l %a6)
  %a8 =l call $helper(l %a7)
  %a9 =l call $helper(l %a8)
  %a10 =l call $helper(l %a9)
  %a11 =l call $helper(l %a10)
  %a12 =l call $helper(l %a11)
  %a13 =l call $helper(l %a12)
  %a14 =l call $helper(l %a13)
  %a15 =l call $helper(l %a14)
  %a16 =l call $helper(l %a15)
  %a17 =l call $helper(l %a16)
  %a18 =l call $helper(l %a17)
  %a19 =l call $helper(l %a18)
  ret %a19
@far_neg
  %r =l sub 0, %x
  ret %r
}

# Opt 4: loop with backedge triggering 16-byte alignment (multi-byte NOPs)
export function l $opt4_loop(l %n) {
@start
  %z =l copy 0
  jmp @loop
@loop
  %i =l phi @start 0, @loop %i1
  %acc =l phi @start %z, @loop %acc1
  %acc1 =l add %acc, %i
  %i1 =l add %i, 1
  %cond =w csltl %i1, %n
  jnz %cond, @loop, @exit
@exit
  ret %acc1
}

# Opt 5: accumulator ALU imm32 short form
export function l $opt5_acc(l %x) {
@start
  %r0 =l call $helper(l %x)
  %r1 =l add %r0, 100000
  %r2 =l xor %r1, 65536
  %c =w ceql %r2, 200000
  %cl =l extuw %c
  %out =l add %r2, %cl
  ret %out
}

# Opt 6: callee-saved GPR + FPR across calls (triggers stp/ldp on arm64)
export function l $opt6_clob(l %a, l %b, l %c, l %d, d %fa, d %fb) {
@start
  %h1 =l call $helper(l %a)
  %h2 =l call $helper(l %b)
  %h3 =l call $helper(l %c)
  %h4 =l call $helper(l %d)
  %s1 =l add %a, %b
  %s2 =l add %c, %d
  %s3 =l add %s1, %s2
  %s4 =l add %h1, %h2
  %s5 =l add %h3, %h4
  %s6 =l add %s3, %s4
  %s7 =l add %s6, %s5
  %fs =d add %fa, %fb
  %fi =l dtosi %fs
  %tot =l add %s7, %fi
  ret %tot
}

# Opt 7A: cross-BB SIB index reconstruction (rematindex) across two distinct successor blocks
# Shared %s in @start cannot be sunk locally; rematindex rewrites both successors to scale-8 SIB
# and eliminates the dead shl instruction.
export function l $opt7_xbb_sib(l %p, l %q, l %idx, w %flag) {
@start
  %s =l shl %idx, 3
  jnz %flag, @left, @right
@left
  %a =l add %p, %s
  %v1 =l loadl %a
  ret %v1
@right
  %b =l add %q, %s
  %v2 =l loadl %b
  ret %v2
}

# Opt 7B: cross-BB SIB live-use preservation (%s still used in arithmetic, so shl must remain live)
export function l $opt7_xbb_sib_live(l %p, l %q, l %idx, w %flag) {
@start
  %s =l shl %idx, 3
  jnz %flag, @left, @right
@left
  %a =l add %p, %s
  %v1 =l loadl %a
  %r1 =l add %v1, %s
  ret %r1
@right
  %b =l add %q, %s
  %v2 =l loadl %b
  ret %v2
}

# Opt 8A: loop with 16-byte alignment, short branches, and inner relocation
export function l $opt8_relax_loop(l %n) {
@start
  jmp @loop
@loop
  %i =l phi @start 0, @next %i1
  %acc =l phi @start 0, @next %acc2
  %odd =l and %i, 1
  %is_odd =w cnel %odd, 0
  jnz %is_odd, @add_call, @add_plain
@add_call
  %h =l call $helper(l %i)
  %acc_c =l add %acc, %h
  jmp @next
@add_plain
  %g =l loadl $gval
  %acc_p =l add %acc, %g
@next
  %acc2 =l phi @add_call %acc_c, @add_plain %acc_p
  %i1 =l add %i, 1
  %cond =w csltl %i1, %n
  jnz %cond, @loop, @exit
@exit
  ret %acc2
}

# Opt 8B: aligned loop with both a far (>127B) branch (must widen to rel32) and a short backedge
export function l $opt8_relax_loop_far(l %n, l %flag) {
@start
  jmp @loop
@loop
  %i =l phi @start 0, @latch %i1
  %acc =l phi @start 0, @latch %acc1
  %c =w cnel %flag, 0
  jnz %c, @far_exit, @body
@body
  %a0 =l call $helper(l %acc)
  %a1 =l call $helper(l %a0)
  %a2 =l call $helper(l %a1)
  %a3 =l call $helper(l %a2)
  %a4 =l call $helper(l %a3)
  %a5 =l call $helper(l %a4)
  %a6 =l call $helper(l %a5)
  %a7 =l call $helper(l %a6)
  %a8 =l call $helper(l %a7)
  %a9 =l call $helper(l %a8)
  %a10 =l call $helper(l %a9)
  %a11 =l call $helper(l %a10)
  %a12 =l call $helper(l %a11)
  %a13 =l call $helper(l %a12)
  %a14 =l call $helper(l %a13)
  %a15 =l call $helper(l %a14)
  %a16 =l call $helper(l %a15)
  %a17 =l call $helper(l %a16)
  %a18 =l call $helper(l %a17)
  %a19 =l call $helper(l %a18)
@latch
  %acc1 =l copy %a19
  %i1 =l add %i, 1
  %cond =w csltl %i1, %n
  jnz %cond, @loop, @done
@done
  ret %acc1
@far_exit
  ret -999
}

# Opt 9A: memory operand cmp folding — 4 independent single-use shapes (no CSE/reuse)
# (a) 32-bit integer load (`load`, which parses as Oload Kw, not Oloadsw) + csltw
export function w $opt9_memcmp_w(l %p32, w %key32) {
@start
  %v =w load %p32
  %c =w csltw %v, %key32
  ret %c
}

# (b) 64-bit SIB scaled load + ceql
export function w $opt9_memcmp_sib(l %p64, l %idx, l %key64) {
@start
  %s =l shl %idx, 3
  %a =l add %p64, %s
  %v =l loadl %a
  %c =w ceql %v, %key64
  ret %c
}

# (c) 64-bit load + cmp against $0 (must stay cmpq $0, (%mem), never mis-encoded as test)
export function w $opt9_memcmp_zero(l %p64) {
@start
  %v =l loadl %p64
  %c =w ceql %v, 0
  ret %c
}

# (d) 64-bit load + cmp against non-zero imm32 (100 = 0x64)
export function w $opt9_memcmp_imm(l %p64) {
@start
  %v =l loadl %p64
  %c =w csgtl %v, 100
  ret %c
}

# Opt 9B: negative safety guards — loadsw vs 64-bit cmp, intervening store alias, multi-use load
export function l $opt9_memcmp_guards(l %p64, l %p32) {
@start
  # Guard 1: loadsw -> 64-bit cmp (sign-extension must not fold as 64-bit load)
  %sw =l loadsw %p32
  %c1 =w ceql %sw, -5
  # Guard 2: intervening store overwrites *p64 before cmp
  %old =l loadl %p64
  storel 9999, %p64
  %c2 =w ceql %old, 42
  # Guard 3: multi-use load must preserve register value
  %m =l loadl %p64
  %c3 =w ceql %m, 9999
  %s1 =w add %c1, %c2
  %s2 =w add %s1, %c3
  %sl =l extsw %s2
  %out =l add %sl, %m
  ret %out
}
EOF

# Opt 2 regression C: 300 live cross-call values pushing stack frame past 1024B
# while accessing p + ((idx - 268435200) << 3) (near INT32_MIN displacement).
# Must not fold into RSlot+disp32 that overflows int32_t after spill().
{
  echo 'export function $opt2_escape(l %p) {'
  echo '@start'
  echo '  ret'
  echo '}'
  echo 'export function l $opt2_item(l %k) {'
  echo '@start'
  echo '  ret %k'
  echo '}'
  echo 'export function l $opt2_sib_pressure(l %idx) {'
  echo '@start'
  echo '  %p =l alloc8 8'
  echo '  storel 7, %p'
  echo '  call $opt2_escape(l %p)'
  k=0
  while [ $k -lt 300 ]; do
    echo "  %v$k =l call \$opt2_item(l $k)"
    k=$((k + 1))
  done
  echo '  %j =l add %idx, -268435200'
  echo '  %s =l shl %j, 3'
  echo '  %a =l add %p, %s'
  echo '  %val =l loadl %a'
  echo '  %acc0 =l add %val, %v0'
  k=1
  while [ $k -lt 300 ]; do
    prev=$((k - 1))
    echo "  %acc$k =l add %acc$prev, %v$k"
    k=$((k + 1))
  done
  echo '  ret %acc299'
  echo '}'
} >> "$TMP_DIR/opts.ssa"

cat > "$TMP_DIR/driver.c" <<'EOF'
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

extern int64_t sib_table;
extern int64_t opt1_cmp0(int64_t a, int32_t b);
extern int64_t opt2_sib(const uint16_t *p16, const uint32_t *p32, const int64_t *p64, int64_t idx);
extern int64_t opt2_sib_wide(uintptr_t p, int64_t i);
extern int64_t opt2_sib_sym(uintptr_t p, int64_t i);
extern int64_t opt2_sib_pressure(int64_t idx);
extern int64_t opt3_short_br(int64_t x);
extern int64_t opt3_long_br(int64_t x);
extern int64_t opt4_loop(int64_t n);
extern int64_t opt5_acc(int64_t x);
extern int64_t opt6_clob(int64_t a, int64_t b, int64_t c, int64_t d, double fa, double fb);
extern int64_t opt7_xbb_sib(const int64_t *p, const int64_t *q, int64_t idx, int32_t flag);
extern int64_t opt7_xbb_sib_live(const int64_t *p, const int64_t *q, int64_t idx, int32_t flag);
extern int64_t opt8_relax_loop(int64_t n);
extern int64_t opt8_relax_loop_far(int64_t n, int64_t flag);
extern int32_t opt9_memcmp_w(const int32_t *p32, int32_t key32);
extern int32_t opt9_memcmp_sib(const int64_t *p64, int64_t idx, int64_t key64);
extern int32_t opt9_memcmp_zero(const int64_t *p64);
extern int32_t opt9_memcmp_imm(const int64_t *p64);
extern int64_t opt9_memcmp_guards(int64_t *p64, const int32_t *p32);

int main(void) {
    /* Opt 1: test zero, positive, negative, INT64_MIN, INT32_MIN */
    if (opt1_cmp0(0, 0) != 2) { fprintf(stderr, "opt1(0,0) failed\n"); return 1; }
    if (opt1_cmp0(-1, -5) != 2) { fprintf(stderr, "opt1(-1,-5) failed\n"); return 1; }
    if (opt1_cmp0(42, 7) != 2) { fprintf(stderr, "opt1(42,7) failed\n"); return 1; }
    if (opt1_cmp0(INT64_MIN, INT32_MIN) != 2) { fprintf(stderr, "opt1(MIN,MIN) failed\n"); return 1; }
    if (opt1_cmp0(0, 5) != 3) { fprintf(stderr, "opt1(0,5) failed\n"); return 1; }

    /* Opt 2: SIB scaling + live use */
    uint16_t a16[4] = {10, 20, 30, 40};
    uint32_t a32[4] = {100, 200, 300, 400};
    int64_t  a64[4] = {1000, 2000, 3000, 4000};
    for (int64_t i = 0; i < 4; i++) {
        int64_t got = opt2_sib(a16, a32, a64, i);
        int64_t exp = (int64_t)a16[i] + (int64_t)a32[i] + a64[i] + (i << 3);
        if (got != exp) {
            fprintf(stderr, "opt2(%lld) got %lld exp %lld\n", (long long)i, (long long)got, (long long)exp);
            return 1;
        }
    }

    /* Opt 2 regressions: wide disp32 overflow (0x20000000 << 3) and scaled CAddr ($sib_table << 3) */
    uintptr_t p_wide = (uintptr_t)a64 - ((uintptr_t)0x20000000ULL << 3);
    if (opt2_sib_wide(p_wide, 2) != 3000) {
        fprintf(stderr, "opt2_sib_wide failed\n");
        return 1;
    }
    uintptr_t p_sym = (uintptr_t)a64 - ((uintptr_t)&sib_table << 3);
    if (opt2_sib_sym(p_sym, 3) != 4000) {
        fprintf(stderr, "opt2_sib_sym failed\n");
        return 1;
    }
    /* Opt 2 regression C: 300 spilled values + near-INT32_MIN slot displacement */
    int64_t r_pres = opt2_sib_pressure(268435200LL);
    int64_t e_pres = 7 + (300LL * 299LL) / 2;
    if (r_pres != e_pres) {
        fprintf(stderr, "opt2_sib_pressure got %lld exp %lld\n", (long long)r_pres, (long long)e_pres);
        return 1;
    }

    /* Opt 3: short branches + relocations + long (>127B) branch */
    if (opt3_short_br(-10) != 10 + 7 + 1000) { fprintf(stderr, "opt3(-10) failed\n"); return 1; }
    if (opt3_short_br(10) != 11 + 7 + 1000) { fprintf(stderr, "opt3(10) failed\n"); return 1; }
    if (opt3_short_br(0) != 1 + 7 + 1000) { fprintf(stderr, "opt3(0) failed\n"); return 1; }
    if (opt3_long_br(-42) != 42) { fprintf(stderr, "opt3_long(-42) failed\n"); return 1; }
    if (opt3_long_br(5) != 5 + 20 * 7) { fprintf(stderr, "opt3_long(5) failed\n"); return 1; }

    /* Opt 4: aligned loop */
    if (opt4_loop(100) != 4950) { fprintf(stderr, "opt4(100) failed\n"); return 1; }

    /* Opt 5: accumulator ALU imm32 */
    int64_t r5 = opt5_acc(10);
    int64_t e5 = ((10 + 7 + 100000) ^ 65536);
    if (r5 != e5) { fprintf(stderr, "opt5(10) got %lld exp %lld\n", (long long)r5, (long long)e5); return 1; }

    /* Opt 6: callee-saved GPR + FPR */
    int64_t r6 = opt6_clob(1, 2, 3, 4, 12.5, 7.5);
    int64_t e6 = (1+2+3+4) + (8+9+10+11) + 20;
    if (r6 != e6) { fprintf(stderr, "opt6 got %lld exp %lld\n", (long long)r6, (long long)e6); return 1; }

    /* Opt 7: cross-BB SIB index reconstruction across two successors + live-use preservation */
    int64_t b64[4] = {10000, 20000, 30000, 40000};
    for (int64_t i = 0; i < 4; i++) {
        if (opt7_xbb_sib(a64, b64, i, 1) != a64[i]) {
            fprintf(stderr, "opt7_xbb_sib(left,%lld) failed\n", (long long)i);
            return 1;
        }
        if (opt7_xbb_sib(a64, b64, i, 0) != b64[i]) {
            fprintf(stderr, "opt7_xbb_sib(right,%lld) failed\n", (long long)i);
            return 1;
        }
        if (opt7_xbb_sib_live(a64, b64, i, 1) != a64[i] + (i << 3)) {
            fprintf(stderr, "opt7_xbb_sib_live(left,%lld) failed\n", (long long)i);
            return 1;
        }
        if (opt7_xbb_sib_live(a64, b64, i, 0) != b64[i]) {
            fprintf(stderr, "opt7_xbb_sib_live(right,%lld) failed\n", (long long)i);
            return 1;
        }
    }

    /* Opt 8: loop alignment + short branch relaxation + far branch widening */
    int64_t r8 = opt8_relax_loop(10);
    /* i=0,2,4,6,8 -> +1000 each (5000); i=1,3,5,7,9 -> +(i+7) = 8+10+12+14+16 = 60 */
    if (r8 != 5060) { fprintf(stderr, "opt8_relax_loop got %lld exp 5060\n", (long long)r8); return 1; }
    if (opt8_relax_loop_far(3, 1) != -999) { fprintf(stderr, "opt8_far(flag=1) failed\n"); return 1; }
    if (opt8_relax_loop_far(3, 0) != 3 * 20 * 7) { fprintf(stderr, "opt8_far(flag=0) failed\n"); return 1; }

    /* Opt 9: memory operand cmp folding (4 independent shapes) + safety guards */
    int64_t m64[4] = {0, 50, 200, 300};
    int32_t m32[2] = {-5, 10};
    if (opt9_memcmp_w(m32, 0) != 1 || opt9_memcmp_w(m32, -5) != 0) {
        fprintf(stderr, "opt9_memcmp_w failed\n"); return 1;
    }
    if (opt9_memcmp_sib(m64, 2, 200) != 1 || opt9_memcmp_sib(m64, 2, 999) != 0) {
        fprintf(stderr, "opt9_memcmp_sib failed\n"); return 1;
    }
    if (opt9_memcmp_zero(&m64[0]) != 1 || opt9_memcmp_zero(&m64[1]) != 0) {
        fprintf(stderr, "opt9_memcmp_zero failed\n"); return 1;
    }
    if (opt9_memcmp_imm(&m64[2]) != 1 || opt9_memcmp_imm(&m64[1]) != 0) {
        fprintf(stderr, "opt9_memcmp_imm failed\n"); return 1;
    }
    int64_t g64 = 42;
    int64_t r9g = opt9_memcmp_guards(&g64, m32);
    if (r9g != 3 + 9999 || g64 != 9999) {
        fprintf(stderr, "opt9_guards got %lld (g64=%lld)\n", (long long)r9g, (long long)g64);
        return 1;
    }

    printf("ALL_OPTS_OK %lld %lld %lld\n", (long long)opt3_short_br(-10), (long long)opt4_loop(100), (long long)r6);
    return 0;
}
EOF

# 0. Verify >1 GiB stack frame (>29-bit SLOT(s) index) fails closed instead of sign-flipping
cat > "$TMP_DIR/slot_ovf.ssa" <<'EOF'
export function l $slot_ovf() {
@start
  %big =l alloc8 1073741824
  %top =l alloc8 8
  storel 42, %top
  call $esc(l %big, l %top)
  %v =l loadl %top
  ret %v
}
EOF
set +e
"$QBE" -t amd64_sysv -o "$TMP_DIR/slot_ovf.s" "$TMP_DIR/slot_ovf.ssa" > "$TMP_DIR/slot_ovf.err" 2>&1
OVF_RC=$?
set -e
if [ "$OVF_RC" -eq 0 ] || ! grep -F 'out of 29-bit range' "$TMP_DIR/slot_ovf.err" >/dev/null; then
  echo "FAIL: >1 GiB stack slot did not fail closed (rc=$OVF_RC): $(cat "$TMP_DIR/slot_ovf.err")" >&2
  exit 1
fi

# 1. Verify AArch64 text assembly has stp/ldp for GPR and FPR pairs
"$QBE" -t arm64 -o "$TMP_DIR/opts_arm64.s" "$TMP_DIR/opts.ssa"
grep -E 'stp[[:space:]]+x[0-9]+, x[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.s" >/dev/null || {
  echo "FAIL: arm64 emit.c did not emit GPR stp pair in prologue" >&2
  cat "$TMP_DIR/opts_arm64.s" >&2
  exit 1
}
grep -E 'ldp[[:space:]]+x[0-9]+, x[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.s" >/dev/null || {
  echo "FAIL: arm64 emit.c did not emit GPR ldp pair in epilogue" >&2
  exit 1
}
grep -E 'stp[[:space:]]+d[0-9]+, d[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.s" >/dev/null || {
  echo "FAIL: arm64 emit.c did not emit FPR stp pair in prologue" >&2
  exit 1
}
grep -E 'ldp[[:space:]]+d[0-9]+, d[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.s" >/dev/null || {
  echo "FAIL: arm64 emit.c did not emit FPR ldp pair in epilogue" >&2
  exit 1
}

# 2. Verify x86-64 direct ELF64 encoding + disassembly + relocations + execution
UNAME_M="$(uname -m)"
if [ "$UNAME_M" = "x86_64" ]; then
  # Verify both text asm (-t amd64_sysv) and direct ELF64 (-t amd64_sysv --obj)
  # succeed without out-of-range disp32 on opt2_sib_pressure
  "$QBE" -t amd64_sysv -o "$TMP_DIR/opts_x64.s" "$TMP_DIR/opts.ssa"
  "$CC" -c "$TMP_DIR/opts_x64.s" -o "$TMP_DIR/opts_x64_asm.o"
  "$CC" -O2 "$TMP_DIR/driver.c" "$TMP_DIR/opts_x64_asm.o" -o "$TMP_DIR/test_x64_asm"
  OUT_X64_ASM="$("$TMP_DIR/test_x64_asm")"
  if [ "$OUT_X64_ASM" != "ALL_OPTS_OK 1017 4950 68" ]; then
    echo "FAIL: x86_64 text-asm execution mismatch: $OUT_X64_ASM" >&2
    exit 1
  fi

  "$QBE" -t amd64_sysv --obj -o "$TMP_DIR/opts_x64.o" "$TMP_DIR/opts.ssa"
  if command -v objdump >/dev/null 2>&1; then
    objdump -dr "$TMP_DIR/opts_x64.o" > "$TMP_DIR/opts_x64.dis"
    # Opt 1: test %r, %r
    awk '/<opt1_cmp0>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E 'test[[:space:]]+%' >/dev/null || {
      echo "FAIL: amd64/elf.c did not emit test %r, %r for cmp \$0" >&2
      awk '/<opt1_cmp0>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 2: all three SIB scales 2, 4, 8 in <opt2_sib>
    for sc in 2 4 8; do
      awk '/<opt2_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -F ",${sc})" >/dev/null || {
        echo "FAIL: amd64/isel.c did not fold shl into SIB scale ${sc} in opt2_sib" >&2
        awk '/<opt2_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
        exit 1
      }
    done
    # Opt 2 regression A: opt2_sib_wide must keep 0x20000000 add (never drop into disp32=0)
    awk '/<opt2_sib_wide>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E '0x20000000|0x100000000' >/dev/null || {
      echo "FAIL: opt2_sib_wide dropped 0x20000000 offset!" >&2
      awk '/<opt2_sib_wide>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 2 regression B: opt2_sib_sym must keep sib_table relocation
    awk '/<opt2_sib_sym>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -F 'sib_table' >/dev/null || {
      echo "FAIL: opt2_sib_sym dropped sib_table relocation!" >&2
      awk '/<opt2_sib_sym>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 3A: short branch eb or 7x in opt3_short_br
    awk '/<opt3_short_br>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E ':[[:space:]]+(eb|7[0-9a-f])[[:space:]]' >/dev/null || {
      echo "FAIL: amd64/elf.c did not relax short branch in opt3_short_br" >&2
      awk '/<opt3_short_br>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 3B: long (>127B) branch stays rel32 (0f 8x) in opt3_long_br
    awk '/<opt3_long_br>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E ':[[:space:]]+0f 8[0-9a-f][[:space:]]' >/dev/null || {
      echo "FAIL: opt3_long_br did not preserve rel32 for >127B jump" >&2
      awk '/<opt3_long_br>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 4: multi-byte NOP alignment padding (0f 1f or 66 90) in opt4_loop
    awk '/<opt4_loop>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E '0f 1f|66 90' >/dev/null || {
      echo "FAIL: amd64/elf.c did not emit multi-byte NOP padding in opt4_loop" >&2
      awk '/<opt4_loop>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 5: accumulator short form (05/2d/35/3d with 48 prefix)
    awk '/<opt5_acc>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E ':[[:space:]]+(48 )?(05|2d|35|3d)[[:space:]]' >/dev/null || {
      echo "FAIL: amd64/elf.c did not emit accumulator imm32 short form in opt5_acc" >&2
      awk '/<opt5_acc>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 7A: cross-BB SIB index reconstruction across two successors (>=2 scale-8 SIBs, 0 shl)
    OPT7_SIB_CNT="$(awk '/<opt7_xbb_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -Fc ',8)' || true)"
    if [ "$OPT7_SIB_CNT" -lt 2 ]; then
      echo "FAIL: amd64/isel.c did not reconstruct >=2 cross-BB scale-8 SIBs in opt7_xbb_sib (got $OPT7_SIB_CNT)" >&2
      awk '/<opt7_xbb_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    fi
    if awk '/<opt7_xbb_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E '\bshl[lq]?\b' >/dev/null; then
      echo "FAIL: amd64/isel.c did not eliminate dead shl in opt7_xbb_sib" >&2
      awk '/<opt7_xbb_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    fi
    # Opt 8A: aligned loop has both multi-byte NOPs and short rel8 branches
    awk '/<opt8_relax_loop>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E ':[[:space:]]+(eb|7[0-9a-f])[[:space:]]' >/dev/null || {
      echo "FAIL: amd64/elf.c did not emit rel8 short branch in aligned opt8_relax_loop" >&2
      awk '/<opt8_relax_loop>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 8B: aligned loop with far >127B jump widens to rel32 (0f 8x)
    awk '/<opt8_relax_loop_far>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E ':[[:space:]]+0f 8[0-9a-f][[:space:]]' >/dev/null || {
      echo "FAIL: opt8_relax_loop_far did not widen >127B branch to rel32" >&2
      awk '/<opt8_relax_loop_far>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 9A(a): 32-bit memory-operand cmp (objdump omits 'l' suffix when reg is 32-bit)
    awk '/<opt9_memcmp_w>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E 'cmpl?[[:space:]]+.*\(' >/dev/null || {
      echo "FAIL: amd64/isel.c did not fold 32-bit load into cmp in opt9_memcmp_w" >&2
      awk '/<opt9_memcmp_w>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 9A(b): 64-bit SIB scaled memory-operand cmp
    awk '/<opt9_memcmp_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E 'cmpq?[[:space:]]+.*,8\)' >/dev/null || {
      echo "FAIL: amd64/isel.c did not fold SIB load into cmp in opt9_memcmp_sib" >&2
      awk '/<opt9_memcmp_sib>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 9A(c): 64-bit cmpq $0x0, (%mem) (not mis-encoded as test)
    awk '/<opt9_memcmp_zero>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E 'cmpq[[:space:]]+\$0x0,.*\(' >/dev/null || {
      echo "FAIL: opt9_memcmp_zero did not emit cmpq \$0x0, (%mem)" >&2
      awk '/<opt9_memcmp_zero>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
    # Opt 9A(d): 64-bit non-zero immediate cmpq $0x64, (%mem)
    awk '/<opt9_memcmp_imm>:/,/^$/' "$TMP_DIR/opts_x64.dis" | grep -E 'cmpq[[:space:]]+\$0x64,.*\(' >/dev/null || {
      echo "FAIL: opt9_memcmp_imm did not emit cmpq \$0x64, (%mem)" >&2
      awk '/<opt9_memcmp_imm>:/,/^$/' "$TMP_DIR/opts_x64.dis" >&2
      exit 1
    }
  fi
  "$CC" -O2 "$TMP_DIR/driver.c" "$TMP_DIR/opts_x64.o" -o "$TMP_DIR/test_x64"
  OUT_X64="$("$TMP_DIR/test_x64")"
  if [ "$OUT_X64" != "ALL_OPTS_OK 1017 4950 68" ]; then
    echo "FAIL: x86_64 execution mismatch: $OUT_X64" >&2
    exit 1
  fi
  echo "[PASS] x86_64 ELF64 encoding + relocs + execution: $OUT_X64"

  # Cross-check AArch64 if cross-gcc + qemu-aarch64 are installed
  if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 && command -v qemu-aarch64 >/dev/null 2>&1; then
    aarch64-linux-gnu-gcc -static -O2 "$TMP_DIR/driver.c" "$TMP_DIR/opts_arm64.s" -o "$TMP_DIR/test_arm64"
    OUT_ARM64="$(qemu-aarch64 "$TMP_DIR/test_arm64")"
    if [ "$OUT_ARM64" != "$OUT_X64" ]; then
      echo "FAIL: aarch64 execution mismatch: $OUT_ARM64 != $OUT_X64" >&2
      exit 1
    fi
    echo "[PASS] aarch64 cross-execution parity: $OUT_ARM64"
  fi
elif [ "$UNAME_M" = "arm64" ] || [ "$UNAME_M" = "aarch64" ]; then
  if [ "$(uname -s)" = "Darwin" ]; then
    "$QBE" -t arm64_apple --obj -o "$TMP_DIR/opts_arm64.o" "$TMP_DIR/opts.ssa"
    if command -v otool >/dev/null 2>&1; then
      otool -tV "$TMP_DIR/opts_arm64.o" > "$TMP_DIR/opts_arm64.dis"
      grep -E 'stp[[:space:]]+x[0-9]+, x[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.dis" >/dev/null || {
        echo "FAIL: arm64/macho.c did not emit GPR stp pair" >&2
        exit 1
      }
      grep -E 'ldp[[:space:]]+x[0-9]+, x[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.dis" >/dev/null || {
        echo "FAIL: arm64/macho.c did not emit GPR ldp pair" >&2
        exit 1
      }
      grep -E 'stp[[:space:]]+d[0-9]+, d[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.dis" >/dev/null || {
        echo "FAIL: arm64/macho.c did not emit FPR stp pair" >&2
        exit 1
      }
      grep -E 'ldp[[:space:]]+d[0-9]+, d[0-9]+, \[x29,' "$TMP_DIR/opts_arm64.dis" >/dev/null || {
        echo "FAIL: arm64/macho.c did not emit FPR ldp pair" >&2
        exit 1
      }
    fi
    "$CC" -O2 "$TMP_DIR/driver.c" "$TMP_DIR/opts_arm64.o" -o "$TMP_DIR/test_arm64"
  else
    "$CC" -O2 "$TMP_DIR/driver.c" "$TMP_DIR/opts_arm64.s" -o "$TMP_DIR/test_arm64"
  fi
  OUT_ARM64="$("$TMP_DIR/test_arm64")"
  if [ "$OUT_ARM64" != "ALL_OPTS_OK 1017 4950 68" ]; then
    echo "FAIL: arm64 execution mismatch: $OUT_ARM64" >&2
    exit 1
  fi
  echo "[PASS] arm64 native Mach-O/asm encoding + execution: $OUT_ARM64"
fi

echo "[PASS] p102_qbe_codegen_opts"
