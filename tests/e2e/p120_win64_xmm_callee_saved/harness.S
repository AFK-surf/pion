/* p120: call one Win64 (Microsoft x64) function with every nonvolatile
 * register loaded with a known pattern and record what it returns.
 *
 * uint64_t p120_call(struct p120_ctx *c), System V convention on every
 * host (driver.c declares it sysv_abi, so a Windows build calls it the same
 * way). struct p120_ctx (driver.c, offsets checked there):
 *     0  fn          8  nstack (unused here: all 8 stack words are copied)
 *    16  args[4]    48  stack[8]
 *   112  gpr_in[8]  176 gpr_out[8]   rbx rbp rdi rsi r12 r13 r14 r15
 *   240  xmm_in[10][16]  400 xmm_out[10][16]   xmm6 .. xmm15
 *   560  rax_out    568 xmm0_out[16]   584 rsp_in   592 rsp_out
 * The call site follows Win64: 32-byte shadow space, stack arguments at
 * 32(%rsp)..., %rsp 16-byte aligned at the call, each register argument
 * in both its GPR (rcx rdx r8 r9) and its XMM (xmm0..xmm3), as for a
 * variadic callee. xmm4 / xmm5 get junk so the callee sees dirty volatile
 * state. */
	.text
	.globl p120_call
p120_call:
	pushq %rbp
	pushq %rbx
	pushq %r12
	pushq %r13
	pushq %r14
	pushq %r15
	pushq %rdi              /* ctx at 96(%rsp) below */
	subq $96, %rsp          /* 32 shadow + 8 stack words; rsp % 16 == 0 */
	movq 48(%rdi), %rax
	movq %rax, 32(%rsp)
	movq 56(%rdi), %rax
	movq %rax, 40(%rsp)
	movq 64(%rdi), %rax
	movq %rax, 48(%rsp)
	movq 72(%rdi), %rax
	movq %rax, 56(%rsp)
	movq 80(%rdi), %rax
	movq %rax, 64(%rsp)
	movq 88(%rdi), %rax
	movq %rax, 72(%rsp)
	movq 96(%rdi), %rax
	movq %rax, 80(%rsp)
	movq 104(%rdi), %rax
	movq %rax, 88(%rsp)
	movq $0x5a5a5a5a5a5a5a5a, %rax
	movq %rax, 0(%rsp)
	movq %rax, 8(%rsp)
	movq %rax, 16(%rsp)
	movq %rax, 24(%rsp)
	movq %rsp, 584(%rdi)
	movups 240(%rdi), %xmm6
	movups 256(%rdi), %xmm7
	movups 272(%rdi), %xmm8
	movups 288(%rdi), %xmm9
	movups 304(%rdi), %xmm10
	movups 320(%rdi), %xmm11
	movups 336(%rdi), %xmm12
	movups 352(%rdi), %xmm13
	movups 368(%rdi), %xmm14
	movups 384(%rdi), %xmm15
	movq %rax, %xmm4
	movq %rax, %xmm5
	movq 16(%rdi), %rcx
	movq 24(%rdi), %rdx
	movq 32(%rdi), %r8
	movq 40(%rdi), %r9
	movq %rcx, %xmm0
	movq %rdx, %xmm1
	movq %r8, %xmm2
	movq %r9, %xmm3
	movq 0(%rdi), %r11
	movq 112(%rdi), %rbx
	movq 120(%rdi), %rbp
	movq 136(%rdi), %rsi
	movq 144(%rdi), %r12
	movq 152(%rdi), %r13
	movq 160(%rdi), %r14
	movq 168(%rdi), %r15
	movq 128(%rdi), %rdi
	callq *%r11
	movq %rax, 0(%rsp)      /* shadow space is ours again */
	movq %rdi, 8(%rsp)
	movq 96(%rsp), %rdi
	movq %rbx, 176(%rdi)
	movq %rbp, 184(%rdi)
	movq 8(%rsp), %rax
	movq %rax, 192(%rdi)
	movq %rsi, 200(%rdi)
	movq %r12, 208(%rdi)
	movq %r13, 216(%rdi)
	movq %r14, 224(%rdi)
	movq %r15, 232(%rdi)
	movups %xmm6, 400(%rdi)
	movups %xmm7, 416(%rdi)
	movups %xmm8, 432(%rdi)
	movups %xmm9, 448(%rdi)
	movups %xmm10, 464(%rdi)
	movups %xmm11, 480(%rdi)
	movups %xmm12, 496(%rdi)
	movups %xmm13, 512(%rdi)
	movups %xmm14, 528(%rdi)
	movups %xmm15, 544(%rdi)
	movq 0(%rsp), %rax
	movq %rax, 560(%rdi)
	movups %xmm0, 568(%rdi)
	movq %rsp, 592(%rdi)
	addq $96, %rsp
	popq %rdi
	popq %r15
	popq %r14
	popq %r13
	popq %r12
	popq %rbx
	popq %rbp
	ret

/* Win64-callable: returns the caller's call-site %rsp mod 16 as seen at
 * entry (8 when the caller kept %rsp 16-byte aligned at the call). */
	.globl p120_rsp
p120_rsp:
	movq %rsp, %rax
	andq $15, %rax
	ret
