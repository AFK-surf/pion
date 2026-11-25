/* P127 helpers. p127_fp_scalar_mode(1) unmasks only the divide-by-zero
 * trap (MXCSR.ZM cleared / FPCR.DZE set), which no P127 kernel can raise
 * but which makes the SLP entry test pick the retained scalar graph;
 * p127_fp_scalar_mode(0) restores the default masked state. Each returns 1
 * when the requested state reads back, 0 when the host cannot enable it.
 * p127_clobber_vectors overwrites every SysV XMM register, or on AArch64 all
 * of v0-v7 / v16-v31 and the high halves of v8-v15 (AAPCS64 preserves only
 * their low 64 bits), with seed-dependent garbage. */
#include <stdint.h>

int32_t p127_fp_scalar_mode(int32_t on) {
#if defined(__x86_64__)
  uint32_t csr;
  __asm__ volatile("stmxcsr %0" : "=m"(csr));
  csr = on ? (csr & ~(uint32_t)0x200) : (csr | 0x200);
  __asm__ volatile("ldmxcsr %0" : : "m"(csr));
  __asm__ volatile("stmxcsr %0" : "=m"(csr));
  return on ? !(csr & 0x200) : !!(csr & 0x200);
#elif defined(__aarch64__)
  uint64_t cr;
  __asm__ volatile("mrs %0, fpcr" : "=r"(cr));
  cr = on ? (cr | 0x200) : (cr & ~(uint64_t)0x200);
  __asm__ volatile("msr fpcr, %0" : : "r"(cr));
  __asm__ volatile("mrs %0, fpcr" : "=r"(cr));
  return on ? !!(cr & 0x200) : !(cr & 0x200);
#else
  return 0;
#endif
}

void p127_clobber_vectors(int64_t seed) {
  uint64_t g = 0x9e3779b97f4a7c15ull * (uint64_t)(seed + 1) | 0x7ff0000000000001ull;
#if defined(__x86_64__)
  __asm__ volatile(
      "movq %0, %%xmm0\n\tpunpcklqdq %%xmm0, %%xmm0\n\t"
      "movdqa %%xmm0, %%xmm1\n\tmovdqa %%xmm0, %%xmm2\n\tmovdqa %%xmm0, %%xmm3\n\t"
      "movdqa %%xmm0, %%xmm4\n\tmovdqa %%xmm0, %%xmm5\n\tmovdqa %%xmm0, %%xmm6\n\t"
      "movdqa %%xmm0, %%xmm7\n\tmovdqa %%xmm0, %%xmm8\n\tmovdqa %%xmm0, %%xmm9\n\t"
      "movdqa %%xmm0, %%xmm10\n\tmovdqa %%xmm0, %%xmm11\n\tmovdqa %%xmm0, %%xmm12\n\t"
      "movdqa %%xmm0, %%xmm13\n\tmovdqa %%xmm0, %%xmm14\n\tmovdqa %%xmm0, %%xmm15"
      :
      : "r"(g)
      : "xmm0", "xmm1", "xmm2", "xmm3", "xmm4", "xmm5", "xmm6", "xmm7", "xmm8",
        "xmm9", "xmm10", "xmm11", "xmm12", "xmm13", "xmm14", "xmm15");
#elif defined(__aarch64__)
  /* v8-v15 are listed as clobbered, so the compiler saves and restores their
   * low halves (d8-d15) as the ABI requires; their high halves stay dirty. */
  __asm__ volatile(
      "dup v0.2d, %0\n\tdup v1.2d, %0\n\tdup v2.2d, %0\n\tdup v3.2d, %0\n\t"
      "dup v4.2d, %0\n\tdup v5.2d, %0\n\tdup v6.2d, %0\n\tdup v7.2d, %0\n\t"
      "dup v8.2d, %0\n\tdup v9.2d, %0\n\tdup v10.2d, %0\n\tdup v11.2d, %0\n\t"
      "dup v12.2d, %0\n\tdup v13.2d, %0\n\tdup v14.2d, %0\n\tdup v15.2d, %0\n\t"
      "dup v16.2d, %0\n\tdup v17.2d, %0\n\tdup v18.2d, %0\n\tdup v19.2d, %0\n\t"
      "dup v20.2d, %0\n\tdup v21.2d, %0\n\tdup v22.2d, %0\n\tdup v23.2d, %0\n\t"
      "dup v24.2d, %0\n\tdup v25.2d, %0\n\tdup v26.2d, %0\n\tdup v27.2d, %0\n\t"
      "dup v28.2d, %0\n\tdup v29.2d, %0\n\tdup v30.2d, %0\n\tdup v31.2d, %0"
      :
      : "r"(g)
      : "v0", "v1", "v2", "v3", "v4", "v5", "v6", "v7", "v8", "v9", "v10", "v11",
        "v12", "v13", "v14", "v15", "v16", "v17", "v18", "v19", "v20", "v21",
        "v22", "v23", "v24", "v25", "v26", "v27", "v28", "v29", "v30", "v31");
#else
  (void)g;
#endif
}
