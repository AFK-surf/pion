#include "all.h"

/*
 * Direct 64-bit x86_64 ELF64 relocatable object (.o) emitter for amd64_sysv.
 * Self-contained ELF64 definitions (compiles cleanly on Linux and macOS).
 */

/* ---- ELF64 constants & wire structures ---- */

#define EI_NIDENT 16

#define ELFCLASS64   2
#define ELFDATA2LSB  1
#define EV_CURRENT   1
#define ELFOSABI_NONE 0

#define ET_REL     1
#define EM_X86_64 62

#define SHT_NULL     0u
#define SHT_PROGBITS 1u
#define SHT_SYMTAB   2u
#define SHT_STRTAB   3u
#define SHT_RELA     4u
#define SHT_NOBITS   8u

#define SHF_WRITE     0x1ULL
#define SHF_ALLOC     0x2ULL
#define SHF_EXECINSTR 0x4ULL
#define SHF_INFO_LINK 0x40ULL
#define SHF_TLS       0x400ULL

#define SHN_UNDEF  0u
#define SHN_COMMON 0xfff2u

#define STB_LOCAL  0u
#define STB_GLOBAL 1u

#define STT_NOTYPE  0u
#define STT_OBJECT  1u
#define STT_FUNC    2u
#define STT_SECTION 3u
#define STT_TLS     6u

#define ELF64_ST_INFO(b, t) ((uint8_t)(((b) << 4) | ((t) & 0xfu)))
#define ELF64_R_INFO(s, t)  ((((uint64_t)(s)) << 32) | ((uint64_t)(t) & 0xffffffffULL))

#define R_X86_64_64       1u
#define R_X86_64_PC32     2u
#define R_X86_64_PLT32    4u
#define R_X86_64_GOTPCREL 9u
#define R_X86_64_32       10u
#define R_X86_64_32S      11u
#define R_X86_64_GOTTPOFF 22u
#define R_X86_64_TPOFF32  23u

typedef struct {
	uint8_t  e_ident[EI_NIDENT];
	uint16_t e_type;
	uint16_t e_machine;
	uint32_t e_version;
	uint64_t e_entry;
	uint64_t e_phoff;
	uint64_t e_shoff;
	uint32_t e_flags;
	uint16_t e_ehsize;
	uint16_t e_phentsize;
	uint16_t e_phnum;
	uint16_t e_shentsize;
	uint16_t e_shnum;
	uint16_t e_shstrndx;
} Elf64_Ehdr;

typedef struct {
	uint32_t sh_name;
	uint32_t sh_type;
	uint64_t sh_flags;
	uint64_t sh_addr;
	uint64_t sh_offset;
	uint64_t sh_size;
	uint32_t sh_link;
	uint32_t sh_info;
	uint64_t sh_addralign;
	uint64_t sh_entsize;
} Elf64_Shdr;

typedef struct {
	uint32_t st_name;
	uint8_t  st_info;
	uint8_t  st_other;
	uint16_t st_shndx;
	uint64_t st_value;
	uint64_t st_size;
} Elf64_Sym;

typedef struct {
	uint64_t r_offset;
	uint64_t r_info;
	int64_t  r_addend;
} Elf64_Rela;

MAKESURE(elf64_ehdr_size, sizeof(Elf64_Ehdr) == 64);
MAKESURE(elf64_shdr_size, sizeof(Elf64_Shdr) == 64);
MAKESURE(elf64_sym_size,  sizeof(Elf64_Sym)  == 24);
MAKESURE(elf64_rela_size, sizeof(Elf64_Rela) == 24);

/* ---- Dynamic buffers, sections, symbols ---- */

#define SYM_NONE 0xffffffffu

typedef struct {
	uint8_t *data;
	size_t len;
	size_t cap;
} Buf;

typedef struct {
	uint64_t offset;
	uint32_t sym_idx;
	uint32_t type;
	int64_t  addend;
} Reloc;

typedef struct {
	char *name;
	uint32_t type;
	uint64_t flags;
	uint64_t align;
	int is_nobits;
	int has_sym;
	Buf buf;
	uint64_t nb_size;
	Reloc *relocs;
	size_t nrelocs;
	size_t cap_relocs;
	/* Layout fields filled in finish() */
	uint32_t out_shndx;
	uint32_t sh_name_off;
	uint32_t rela_sh_name_off;
	uint64_t fileoff;
	uint64_t rela_fileoff;
} Sec;

typedef struct {
	char *name;
	int defined;
	int is_export;
	int is_common;
	uint8_t st_type;
	int sec_idx;
	uint64_t offset;       /* offset in section, or alignment if common */
	uint64_t size;         /* st_size */
} SymEnt;

typedef struct {
	uint32_t disp_off;     /* offset of 4-byte rel32 in .text */
	uint32_t next_pc;      /* offset of instruction after branch */
	uint32_t target_bid;
	uint8_t is_cond;       /* 1 = jcc (0f 8x -> 7x), 0 = jmp (e9 -> eb) */
	uint8_t cc;            /* condition code for jcc */
} BrFixup;

typedef struct {
	uint32_t entry_off;
	uint32_t tbl_base_off;
	uint32_t target_bid;
} JtblFixup;

enum {
	SEC_TEXT = 0,
	SEC_RODATA,
	SEC_DATA,
	SEC_BSS,
	SEC_TDATA,
	SEC_TBSS,
	SEC_BUILTIN_COUNT
};

typedef struct {
	Sec *secs;
	size_t nsecs;
	size_t cap_secs;
	int cur_text_sec;

	SymEnt *syms;
	size_t nsyms;
	size_t cap_syms;

	uint32_t *sym_ht;
	size_t sym_ht_cap;

	/* Current data definition state */
	char *dat_name;
	Lnk dat_lnk;
	char *dat_sec_str;
	char *dat_secf_str;
	int dat_sec_idx;
	int64_t dat_zero;
	uint32_t dat_sym_idx;
	uint64_t dat_start_off;
} ElfObj;

static ElfObj E0;

static void
buf_reserve(Buf *b, size_t extra)
{
	size_t need = b->len + extra;
	if (need <= b->cap)
		return;
	size_t ncap = b->cap ? b->cap * 2 : 256;
	while (ncap < need)
		ncap *= 2;
	b->data = realloc(b->data, ncap);
	if (!b->data)
		die("elf: out of memory");
	b->cap = ncap;
}

static void
buf_put(Buf *b, const void *src, size_t n)
{
	if (n == 0)
		return;
	buf_reserve(b, n);
	memcpy(b->data + b->len, src, n);
	b->len += n;
}

static void
buf_put_zeros(Buf *b, size_t n)
{
	if (n == 0)
		return;
	buf_reserve(b, n);
	memset(b->data + b->len, 0, n);
	b->len += n;
}

static inline void
buf_put_u8(Buf *b, uint8_t v)
{
	buf_reserve(b, 1);
	b->data[b->len++] = v;
}

static inline void
buf_put_u16(Buf *b, uint16_t v)
{
	uint8_t t[2];
	t[0] = (uint8_t)(v & 0xffu);
	t[1] = (uint8_t)((v >> 8) & 0xffu);
	buf_put(b, t, 2);
}

static inline void
buf_put_u32(Buf *b, uint32_t v)
{
	uint8_t t[4];
	t[0] = (uint8_t)(v & 0xffu);
	t[1] = (uint8_t)((v >> 8) & 0xffu);
	t[2] = (uint8_t)((v >> 16) & 0xffu);
	t[3] = (uint8_t)((v >> 24) & 0xffu);
	buf_put(b, t, 4);
}

static inline void
buf_put_u64(Buf *b, uint64_t v)
{
	uint8_t t[8];
	t[0] = (uint8_t)(v & 0xffu);
	t[1] = (uint8_t)((v >> 8) & 0xffu);
	t[2] = (uint8_t)((v >> 16) & 0xffu);
	t[3] = (uint8_t)((v >> 24) & 0xffu);
	t[4] = (uint8_t)((v >> 32) & 0xffu);
	t[5] = (uint8_t)((v >> 40) & 0xffu);
	t[6] = (uint8_t)((v >> 48) & 0xffu);
	t[7] = (uint8_t)((v >> 56) & 0xffu);
	buf_put(b, t, 8);
}

static inline void
patch_u32(uint8_t *p, uint32_t v)
{
	p[0] = (uint8_t)(v & 0xffu);
	p[1] = (uint8_t)((v >> 8) & 0xffu);
	p[2] = (uint8_t)((v >> 16) & 0xffu);
	p[3] = (uint8_t)((v >> 24) & 0xffu);
}

static uint64_t
align_up(uint64_t v, uint64_t a)
{
	if (a <= 1)
		return v;
	return (v + a - 1) & ~(a - 1);
}

static int
add_sec(const char *name, uint32_t type, uint64_t flags, uint64_t align, int is_nobits)
{
	if (E0.nsecs == E0.cap_secs) {
		E0.cap_secs = E0.cap_secs ? E0.cap_secs * 2 : 16;
		E0.secs = realloc(E0.secs, E0.cap_secs * sizeof *E0.secs);
		if (!E0.secs)
			die("elf: out of memory");
	}
	Sec *s = &E0.secs[E0.nsecs];
	memset(s, 0, sizeof *s);
	size_t nlen = strlen(name) + 1;
	s->name = emalloc(nlen);
	memcpy(s->name, name, nlen);
	s->type = type;
	s->flags = flags;
	s->align = align ? align : 1;
	s->is_nobits = is_nobits;
	return (int)(E0.nsecs++);
}

static void
make_subsec_name(char *dst, size_t cap, const char *prefix, const char *raw)
{
	size_t plen = strlen(prefix);
	if (plen + 1 >= cap) {
		dst[0] = '\0';
		return;
	}
	memcpy(dst, prefix, plen);
	const char *p = raw;
	size_t rlen = strlen(raw);
	if (rlen >= 2 && p[0] == '"' && p[rlen - 1] == '"') {
		p++;
		rlen -= 2;
	}
	size_t avail = cap - plen - 1;
	if (rlen > avail)
		rlen = avail;
	memcpy(dst + plen, p, rlen);
	dst[plen + rlen] = '\0';
}

static uint64_t
sec_size(const Sec *s)
{
	return s->is_nobits ? s->nb_size : (uint64_t)s->buf.len;
}

static void
emit_nops(Buf *b, size_t n)
{
	static const uint8_t nop1[] = { 0x90 };
	static const uint8_t nop2[] = { 0x66, 0x90 };
	static const uint8_t nop3[] = { 0x0f, 0x1f, 0x00 };
	static const uint8_t nop4[] = { 0x0f, 0x1f, 0x40, 0x00 };
	static const uint8_t nop5[] = { 0x0f, 0x1f, 0x44, 0x00, 0x00 };
	static const uint8_t nop6[] = { 0x66, 0x0f, 0x1f, 0x44, 0x00, 0x00 };
	static const uint8_t nop7[] = { 0x0f, 0x1f, 0x80, 0x00, 0x00, 0x00, 0x00 };
	static const uint8_t nop8[] = { 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 };
	static const uint8_t nop9[] = { 0x66, 0x0f, 0x1f, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00 };
	static const uint8_t *const nops[10] = {
		NULL, nop1, nop2, nop3, nop4, nop5, nop6, nop7, nop8, nop9
	};
	buf_reserve(b, n);
	while (n > 0) {
		size_t k = n > 9 ? 9 : n;
		memcpy(b->data + b->len, nops[k], k);
		b->len += k;
		n -= k;
	}
}

static void
sec_align(int sec_idx, uint64_t align_bytes)
{
	Sec *s = &E0.secs[sec_idx];
	if (align_bytes <= 1)
		return;
	/* Round align_bytes up to power of two if needed */
	uint64_t a = 1;
	while (a < align_bytes && a < (1ULL << 20))
		a <<= 1;
	if (a > s->align)
		s->align = a;
	uint64_t cur = sec_size(s);
	uint64_t nxt = align_up(cur, a);
	if (nxt > cur) {
		if (s->is_nobits) {
			s->nb_size = nxt;
		} else if (s->flags & SHF_EXECINSTR) {
			emit_nops(&s->buf, (size_t)(nxt - cur));
		} else {
			buf_put_zeros(&s->buf, (size_t)(nxt - cur));
		}
	}
}

static void
sec_add_reloc(int sec_idx, uint64_t offset, uint32_t sym_idx, uint32_t type, int64_t addend)
{
	Sec *s = &E0.secs[sec_idx];
	if (s->nrelocs == s->cap_relocs) {
		s->cap_relocs = s->cap_relocs ? s->cap_relocs * 2 : 64;
		s->relocs = realloc(s->relocs, s->cap_relocs * sizeof *s->relocs);
		if (!s->relocs)
			die("elf: out of memory");
	}
	Reloc *r = &s->relocs[s->nrelocs++];
	r->offset = offset;
	r->sym_idx = sym_idx;
	r->type = type;
	r->addend = addend;
}

/* ---- Symbol table ---- */

static uint32_t
fnv1a(const char *s)
{
	uint32_t h = 2166136261u;
	for (; *s; s++) {
		h ^= (uint8_t)*s;
		h *= 16777619u;
	}
	return h;
}

static void
sym_ht_rehash(size_t ncap)
{
	uint32_t *nt = calloc(ncap, sizeof *nt);
	if (!nt)
		die("elf: out of memory");
	size_t mask = ncap - 1;
	for (size_t i = 0; i < E0.nsyms; i++) {
		size_t sl = fnv1a(E0.syms[i].name) & mask;
		while (nt[sl] != 0)
			sl = (sl + 1) & mask;
		nt[sl] = (uint32_t)(i + 1);
	}
	free(E0.sym_ht);
	E0.sym_ht = nt;
	E0.sym_ht_cap = ncap;
}

static uint32_t
sym_intern(const char *name)
{
	if (E0.sym_ht_cap == 0)
		sym_ht_rehash(256);
	else if ((E0.nsyms + 1) * 2 > E0.sym_ht_cap)
		sym_ht_rehash(E0.sym_ht_cap * 2);

	size_t mask = E0.sym_ht_cap - 1;
	size_t sl = fnv1a(name) & mask;
	while (E0.sym_ht[sl] != 0) {
		uint32_t idx = E0.sym_ht[sl] - 1;
		if (strcmp(E0.syms[idx].name, name) == 0)
			return idx;
		sl = (sl + 1) & mask;
	}

	if (E0.nsyms == E0.cap_syms) {
		E0.cap_syms = E0.cap_syms ? E0.cap_syms * 2 : 128;
		E0.syms = realloc(E0.syms, E0.cap_syms * sizeof *E0.syms);
		if (!E0.syms)
			die("elf: out of memory");
	}
	uint32_t idx = (uint32_t)E0.nsyms++;
	SymEnt *e = &E0.syms[idx];
	memset(e, 0, sizeof *e);
	size_t nlen = strlen(name) + 1;
	e->name = emalloc(nlen);
	memcpy(e->name, name, nlen);
	e->sec_idx = -1;
	e->st_type = STT_NOTYPE;
	E0.sym_ht[sl] = idx + 1;
	return idx;
}

static char *
format_elf_sym(const char *raw, char *buf, size_t bufsz)
{
	size_t len = strlen(raw);
	if (len >= 2 && raw[0] == '"' && raw[len - 1] == '"') {
		size_t inner = len - 2;
		if (inner + 1 > bufsz)
			die("elf: symbol name too long: %s", raw);
		memcpy(buf, raw + 1, inner);
		buf[inner] = '\0';
	} else {
		size_t plen = strlen(T.assym);
		if (plen + len + 1 > bufsz)
			die("elf: symbol name too long: %s", raw);
		memcpy(buf, T.assym, plen);
		memcpy(buf + plen, raw, len);
		buf[plen + len] = '\0';
	}
	return buf;
}

static uint32_t
sym_ref_qbe(const char *raw)
{
	char buf[1024];
	return sym_intern(format_elf_sym(raw, buf, sizeof buf));
}

static uint32_t
sym_define(const char *raw, int sec_idx, uint64_t offset, int is_export, uint8_t st_type)
{
	uint32_t idx = sym_ref_qbe(raw);
	SymEnt *e = &E0.syms[idx];
	e->defined = 1;
	e->is_common = 0;
	e->sec_idx = sec_idx;
	e->offset = offset;
	e->st_type = st_type;
	if (sec_idx >= 0)
		E0.secs[sec_idx].has_sym = 1;
	if (is_export)
		e->is_export = 1;
	return idx;
}

/* ---- x86_64 register encoding ---- */

static const uint8_t gpr_hw[XMM15 + 1] = {
	[RAX] = 0,  [RCX] = 1,  [RDX] = 2,  [RBX] = 3,
	[RSP] = 4,  [RBP] = 5,  [RSI] = 6,  [RDI] = 7,
	[R8 ] = 8,  [R9 ] = 9,  [R10] = 10, [R11] = 11,
	[R12] = 12, [R13] = 13, [R14] = 14, [R15] = 15,
};

static inline uint8_t
hw_reg(int r)
{
	if (r >= XMM0 && r <= XMM15)
		return (uint8_t)(r - XMM0);
	if (r >= RAX && r <= RSP)
		return gpr_hw[r];
	die("elf: invalid register %d", r);
}

static inline int
is_xmm(int r)
{
	return r >= XMM0 && r <= XMM15;
}

static inline Buf *
text_buf(void)
{
	return &E0.secs[E0.cur_text_sec].buf;
}

static inline uint32_t
text_pos(void)
{
	size_t len = E0.secs[E0.cur_text_sec].buf.len;
	if (len > UINT32_MAX)
		die("elf: .text section exceeds 4GiB");
	return (uint32_t)len;
}

static inline void
emit_u8(uint8_t b)
{
	buf_put_u8(text_buf(), b);
}

static inline void
emit_u16(uint16_t v)
{
	buf_put_u16(text_buf(), v);
}

static inline void
emit_u32(uint32_t v)
{
	buf_put_u32(text_buf(), v);
}

static inline void
emit_u64(uint64_t v)
{
	buf_put_u64(text_buf(), v);
}

/* x86_64 condition codes (for jcc, setcc, cmovcc) */
enum {
	CC_O  = 0x0, CC_NO = 0x1,
	CC_B  = 0x2, CC_AE = 0x3,
	CC_Z  = 0x4, CC_NZ = 0x5,
	CC_BE = 0x6, CC_A  = 0x7,
	CC_S  = 0x8, CC_NS = 0x9,
	CC_P  = 0xa, CC_NP = 0xb,
	CC_L  = 0xc, CC_GE = 0xd,
	CC_LE = 0xe, CC_G  = 0xf,
};

static const uint8_t cmp_cc[NCmp][2] = {
	[Ciule]      = { CC_BE, CC_A  },
	[Ciult]      = { CC_B,  CC_AE },
	[Cisle]      = { CC_LE, CC_G  },
	[Cislt]      = { CC_L,  CC_GE },
	[Cisgt]      = { CC_G,  CC_LE },
	[Cisge]      = { CC_GE, CC_L  },
	[Ciugt]      = { CC_A,  CC_BE },
	[Ciuge]      = { CC_AE, CC_B  },
	[Cieq]       = { CC_Z,  CC_NZ },
	[Cine]       = { CC_NZ, CC_Z  },
	[NCmpI+Cfeq] = { CC_Z,  CC_NZ },
	[NCmpI+Cfne] = { CC_NZ, CC_Z  },
	[NCmpI+Cfgt] = { CC_A,  CC_BE },
	[NCmpI+Cfge] = { CC_AE, CC_B  },
	[NCmpI+Cfo]  = { CC_NP, CC_P  },
	[NCmpI+Cfuo] = { CC_P,  CC_NP },
};

/* ---- Function emission state ---- */

typedef struct {
	Fn *fn;
	int fp;
	uint64_t fsz;
	int nclob;
	BrFixup *fixups;
	size_t nfixups;
	size_t cap_fixups;
	JtblFixup *jtfixups;
	size_t njtfixups;
	size_t cap_jtfixups;
} EF;

static void
ef_add_fixup(EF *e, uint32_t disp_off, uint32_t next_pc, uint32_t target_bid,
             uint8_t is_cond, uint8_t cc)
{
	if (e->nfixups == e->cap_fixups) {
		e->cap_fixups = e->cap_fixups ? e->cap_fixups * 2 : 64;
		e->fixups = realloc(e->fixups, e->cap_fixups * sizeof *e->fixups);
		if (!e->fixups)
			die("elf: out of memory");
	}
	BrFixup *f = &e->fixups[e->nfixups++];
	f->disp_off = disp_off;
	f->next_pc = next_pc;
	f->target_bid = target_bid;
	f->is_cond = is_cond;
	f->cc = cc;
}

static void
ef_add_jtfixup(EF *e, uint32_t entry_off, uint32_t tbl_base_off, uint32_t target_bid)
{
	if (e->njtfixups == e->cap_jtfixups) {
		e->cap_jtfixups = e->cap_jtfixups ? e->cap_jtfixups * 2 : 64;
		e->jtfixups = realloc(e->jtfixups, e->cap_jtfixups * sizeof *e->jtfixups);
		if (!e->jtfixups)
			die("elf: out of memory");
	}
	JtblFixup *f = &e->jtfixups[e->njtfixups++];
	f->entry_off = entry_off;
	f->tbl_base_off = tbl_base_off;
	f->target_bid = target_bid;
}

static int64_t
slot(Ref r, EF *e)
{
	int64_t s = rsval(r);
	assert(s <= e->fn->slot);
	if (s < 0) {
		if (e->fp == RSP)
			return 4LL * -s - 8LL + (int64_t)e->fsz + (int64_t)e->nclob * 8LL;
		else
			return 4LL * -s;
	} else if (e->fp == RSP) {
		return 4LL * s + (int64_t)e->nclob * 8LL;
	} else if (e->fn->vararg) {
		return -176LL + -4LL * ((int64_t)e->fn->slot - s);
	} else {
		return -4LL * ((int64_t)e->fn->slot - s);
	}
}

static void
sysv_framesz(EF *e)
{
	uint64_t i, o, f;

	o = 0;
	if (!e->fn->leaf) {
		for (i = 0, o = 0; i < NCLR_SYSV; i++)
			o ^= e->fn->reg >> amd64_sysv_rclob[i];
		o &= 1;
	}
	f = (uint64_t)e->fn->slot;
	f = (f + 3) & ~(uint64_t)3;
	if (f > 0 && e->fp == RSP && e->fn->salign == 4)
		f += 2;
	e->fsz = 4 * f + 8 * o + 176 * (uint64_t)e->fn->vararg;
}

/* ---- Unified x86_64 Operand & ModRM/SIB/REX Encoder ---- */

typedef struct {
	int is_mem;
	uint8_t reg;       /* if !is_mem: hw reg 0..15 */
	/* if is_mem: */
	int base;          /* -1 if none, else 0..15 */
	int index;         /* -1 if none, else 0..15 */
	int scale;         /* 1, 2, 4, 8 */
	int64_t disp;
	uint32_t sym;      /* SYM_NONE if none */
	uint32_t rel_type; /* R_X86_64_* */
	int is_rip;
	int seg_fs;
} RmOp;

static RmOp
rm_reg(uint8_t r)
{
	RmOp o;
	memset(&o, 0, sizeof o);
	o.is_mem = 0;
	o.reg = r;
	o.base = -1;
	o.index = -1;
	o.sym = SYM_NONE;
	return o;
}

static RmOp
rm_base_disp(int base, int64_t disp)
{
	RmOp o;
	memset(&o, 0, sizeof o);
	o.is_mem = 1;
	o.base = base;
	o.index = -1;
	o.scale = 1;
	o.disp = disp;
	o.sym = SYM_NONE;
	return o;
}

static RmOp
rm_rip_sym(uint32_t sym, uint32_t rel_type, int64_t disp)
{
	RmOp o;
	memset(&o, 0, sizeof o);
	o.is_mem = 1;
	o.base = -1;
	o.index = -1;
	o.scale = 1;
	o.disp = disp;
	o.sym = sym;
	o.rel_type = rel_type;
	o.is_rip = 1;
	return o;
}

static RmOp
ref_to_rm(Ref r, int as_mem, EF *e)
{
	RmOp o;
	memset(&o, 0, sizeof o);
	o.base = -1;
	o.index = -1;
	o.scale = 1;
	o.sym = SYM_NONE;

	switch (rtype(r)) {
	case RTmp:
		assert(isreg(r));
		if (as_mem) {
			o.is_mem = 1;
			o.base = (int)hw_reg(r.val);
		} else {
			o.is_mem = 0;
			o.reg = hw_reg(r.val);
		}
		return o;
	case RSlot:
		o.is_mem = 1;
		o.base = (int)hw_reg(e->fp);
		o.disp = slot(r, e);
		if (o.disp < INT32_MIN || o.disp > INT32_MAX)
			die("elf: stack slot displacement out of disp32 range");
		return o;
	case RMem: {
		Addr a = e->fn->mem[r.val];
		Con off;
		if (rtype(a.base) == RSlot) {
			int64_t so = slot(a.base, e);
			int64_t cur = (a.offset.type == CUndef) ? 0 : a.offset.bits.i;
			if (so < INT32_MIN || so > INT32_MAX
			|| cur < INT32_MIN || cur > INT32_MAX
			|| cur + so < INT32_MIN || cur + so > INT32_MAX)
				die("elf: stack displacement out of disp32 range");
			off.type = CBits;
			off.bits.i = so;
			addcon(&a.offset, &off, 1);
			a.base = TMP(e->fp);
		}
		o.is_mem = 1;
		if (!req(a.base, R)) {
			assert(isreg(a.base));
			o.base = (int)hw_reg(a.base.val);
		}
		if (!req(a.index, R)) {
			assert(isreg(a.index));
			o.index = (int)hw_reg(a.index.val);
			o.scale = a.scale ? a.scale : 1;
		}
		if (a.offset.type == CBits) {
			o.disp = a.offset.bits.i;
		} else if (a.offset.type == CAddr) {
			o.sym = sym_ref_qbe(str(a.offset.sym.id));
			o.disp = a.offset.bits.i;
			if (a.offset.sym.type == SThr) {
				o.seg_fs = 1;
				o.rel_type = R_X86_64_TPOFF32;
			} else if (o.base == -1 && o.index == -1) {
				o.is_rip = 1;
				o.rel_type = R_X86_64_PC32;
			} else {
				o.rel_type = R_X86_64_32S;
			}
		}
		return o;
	}
	case RCon: {
		Con *c = &e->fn->con[r.val];
		assert(as_mem);
		o.is_mem = 1;
		if (c->type == CAddr) {
			o.sym = sym_ref_qbe(str(c->sym.id));
			o.disp = c->bits.i;
			if (c->sym.type == SThr) {
				o.seg_fs = 1;
				o.rel_type = R_X86_64_TPOFF32;
			} else {
				o.is_rip = 1;
				o.rel_type = R_X86_64_PC32;
			}
		} else if (c->type == CBits) {
			o.disp = c->bits.i;
		} else {
			die("elf: invalid memory constant");
		}
		return o;
	}
	default:
		die("elf: invalid ref type %d for rm operand", rtype(r));
	}
}

static inline uint8_t
scale_bits(int sc)
{
	switch (sc) {
	case 1: return 0;
	case 2: return 1;
	case 4: return 2;
	case 8: return 3;
	default: die("elf: invalid SIB scale %d", sc);
	}
}

/*
 * Emit a complete x86_64 ModRM instruction:
 *   [seg_fs] [pfx] [REX] [op0] [op1 if op1>=0] [ModRM] [SIB] [disp] [imm]
 * imm_bytes: 0, 1, 2, or 4 (for RIP-relative addend adjustment).
 * force_rex: set 1 when an 8-bit register operand is SPL/BPL/SIL/DIL (4..7).
 */
static void
emit_modrm(uint8_t pfx, int rex_w, int force_rex,
           uint8_t op0, int op1, uint8_t reg_field, RmOp rm,
           int imm_bytes, uint64_t imm_val)
{
	uint8_t rex = 0;

	if (rm.is_mem && rm.index == 4 && rm.scale == 1 && rm.base != -1 && rm.base != 4) {
		int tmp = rm.base;
		rm.base = rm.index;
		rm.index = tmp;
	}
	if (rm.is_mem && rm.index == 4 && rm.scale == 1 && rm.base == -1) {
		rm.base = 4;
		rm.index = -1;
	}

	if (rex_w)
		rex |= 0x08;
	if (reg_field & 8)
		rex |= 0x04;
	if (!rm.is_mem) {
		if (rm.reg & 8)
			rex |= 0x01;
	} else {
		if (rm.index >= 0 && (rm.index & 8))
			rex |= 0x02;
		if (rm.base >= 0 && (rm.base & 8))
			rex |= 0x01;
	}

	if (rm.is_mem && rm.seg_fs)
		emit_u8(0x64);
	if (pfx)
		emit_u8(pfx);
	if (rex || force_rex)
		emit_u8((uint8_t)(0x40u | rex));

	emit_u8(op0);
	if (op1 >= 0)
		emit_u8((uint8_t)op1);

	uint8_t reg_lo = reg_field & 7u;

	if (!rm.is_mem) {
		emit_u8((uint8_t)(0xc0u | (reg_lo << 3) | (rm.reg & 7u)));
	} else if (rm.is_rip) {
		emit_u8((uint8_t)((reg_lo << 3) | 5u));
		uint32_t disp_off = text_pos();
		if (rm.sym != SYM_NONE) {
			sec_add_reloc(E0.cur_text_sec, disp_off, rm.sym, rm.rel_type,
				rm.disp - 4 - imm_bytes);
			emit_u32(0);
		} else {
			if (rm.disp < INT32_MIN || rm.disp > INT32_MAX)
				die("elf: disp32 overflow");
			emit_u32((uint32_t)(int32_t)rm.disp);
		}
	} else if (rm.base < 0 && rm.index < 0) {
		/* Absolute [disp32] via SIB 0x25 */
		emit_u8((uint8_t)((reg_lo << 3) | 4u));
		emit_u8(0x25);
		uint32_t disp_off = text_pos();
		if (rm.sym != SYM_NONE) {
			sec_add_reloc(E0.cur_text_sec, disp_off, rm.sym, rm.rel_type, rm.disp);
			emit_u32(0);
		} else {
			if (rm.disp < INT32_MIN || rm.disp > INT32_MAX)
				die("elf: disp32 overflow");
			emit_u32((uint32_t)(int32_t)rm.disp);
		}
	} else if (rm.base < 0 && rm.index >= 0) {
		/* [index*scale + disp32] */
		assert((rm.index & 7) != 4 || (rm.index >= 8));
		emit_u8((uint8_t)((reg_lo << 3) | 4u));
		emit_u8((uint8_t)((scale_bits(rm.scale) << 6) | ((rm.index & 7) << 3) | 5u));
		uint32_t disp_off = text_pos();
		if (rm.sym != SYM_NONE) {
			sec_add_reloc(E0.cur_text_sec, disp_off, rm.sym, rm.rel_type, rm.disp);
			emit_u32(0);
		} else {
			if (rm.disp < INT32_MIN || rm.disp > INT32_MAX)
				die("elf: disp32 overflow");
			emit_u32((uint32_t)(int32_t)rm.disp);
		}
	} else {
		/* base >= 0 */
		uint8_t base_lo = (uint8_t)(rm.base & 7);
		int need_sib = (rm.index >= 0) || (base_lo == 4);
		int mod;
		if (rm.sym != SYM_NONE || rm.disp < -128 || rm.disp > 127)
			mod = 2;
		else if (rm.disp != 0 || base_lo == 5)
			mod = 1;
		else
			mod = 0;

		emit_u8((uint8_t)((mod << 6) | (reg_lo << 3) | (need_sib ? 4u : base_lo)));
		if (need_sib) {
			uint8_t idx_lo = (rm.index >= 0) ? (uint8_t)(rm.index & 7) : 4u;
			uint8_t ss = (rm.index >= 0) ? scale_bits(rm.scale) : 0u;
			emit_u8((uint8_t)((ss << 6) | (idx_lo << 3) | base_lo));
		}
		if (mod == 1) {
			emit_u8((uint8_t)(int8_t)rm.disp);
		} else if (mod == 2) {
			uint32_t disp_off = text_pos();
			if (rm.sym != SYM_NONE) {
				sec_add_reloc(E0.cur_text_sec, disp_off, rm.sym, rm.rel_type, rm.disp);
				emit_u32(0);
			} else {
				if (rm.disp < INT32_MIN || rm.disp > INT32_MAX)
					die("elf: disp32 overflow");
				emit_u32((uint32_t)(int32_t)rm.disp);
			}
		}
	}

	switch (imm_bytes) {
	case 0: break;
	case 1: emit_u8((uint8_t)imm_val); break;
	case 2: emit_u16((uint16_t)imm_val); break;
	case 4: emit_u32((uint32_t)imm_val); break;
	default: die("elf: invalid imm_bytes %d", imm_bytes);
	}
}

static inline int
needs_byte_rex(uint8_t r)
{
	return r >= 4 && r <= 7;
}

static inline int
fits_i8(int64_t v)
{
	return v >= -128 && v <= 127;
}

static inline int
fits_i32(int64_t v)
{
	return v >= INT32_MIN && v <= INT32_MAX;
}

/* ---- Instruction encoding helpers ---- */

static void
enc_push_reg(uint8_t r)
{
	if (r & 8)
		emit_u8(0x41);
	emit_u8((uint8_t)(0x50u + (r & 7u)));
}

static void
enc_pop_reg(uint8_t r)
{
	if (r & 8)
		emit_u8(0x41);
	emit_u8((uint8_t)(0x58u + (r & 7u)));
}

static void
enc_alu_imm(int is64, uint8_t grp, RmOp dst, int64_t imm)
{
	if (!is64)
		imm = (int64_t)(int32_t)(uint32_t)imm;
	if (fits_i8(imm)) {
		emit_modrm(0, is64, 0, 0x83, -1, grp, dst, 1, (uint64_t)imm);
	} else {
		assert(fits_i32(imm));
		if (!dst.is_mem && dst.reg == 0) {
			if (is64)
				emit_u8(0x48);
			emit_u8((uint8_t)(grp * 8u + 5u));
			emit_u32((uint32_t)imm);
		} else {
			emit_modrm(0, is64, 0, 0x81, -1, grp, dst, 4, (uint64_t)imm);
		}
	}
}

static void
enc_alu_op(int is64, uint8_t grp, Ref src, Ref dst, EF *e)
{
	RmOp d = ref_to_rm(dst, 0, e);
	if (rtype(src) == RCon) {
		Con *c = &e->fn->con[src.val];
		assert(c->type == CBits);
		enc_alu_imm(is64, grp, d, c->bits.i);
		return;
	}
	RmOp s = ref_to_rm(src, 0, e);
	if (!s.is_mem) {
		/* op r -> r/m */
		emit_modrm(0, is64, 0, (uint8_t)(grp * 8u + 1u), -1, s.reg, d, 0, 0);
	} else {
		/* op m -> r */
		assert(!d.is_mem);
		emit_modrm(0, is64, 0, (uint8_t)(grp * 8u + 3u), -1, d.reg, s, 0, 0);
	}
}

static void
enc_mov_imm_reg(int is64, uint8_t r, int64_t val)
{
	if (!is64) {
		if (r & 8)
			emit_u8(0x41);
		emit_u8((uint8_t)(0xb8u + (r & 7u)));
		emit_u32((uint32_t)val);
	} else if (val >= 0 && val <= (int64_t)UINT32_MAX) {
		/* movl $val32, %r32d zero-extends to 64-bit */
		if (r & 8)
			emit_u8(0x41);
		emit_u8((uint8_t)(0xb8u + (r & 7u)));
		emit_u32((uint32_t)val);
	} else if (fits_i32(val)) {
		emit_modrm(0, 1, 0, 0xc7, -1, 0, rm_reg(r), 4, (uint64_t)val);
	} else {
		/* movabsq $imm64, %r64 */
		emit_u8((uint8_t)(0x48u | ((r & 8) ? 1u : 0u)));
		emit_u8((uint8_t)(0xb8u + (r & 7u)));
		emit_u64((uint64_t)val);
	}
}

static void
enc_sse_bin(int cls, uint8_t op1, Ref src, Ref dst, EF *e)
{
	uint8_t pfx = (cls == Kd) ? 0xf2 : 0xf3;
	RmOp d = ref_to_rm(dst, 0, e);
	RmOp s = ref_to_rm(src, 0, e);
	assert(!d.is_mem);
	emit_modrm(pfx, 0, 0, 0x0f, op1, d.reg, s, 0, 0);
}

static void emitins(Ins i, EF *e);

static void
emitcopy(Ref r1, Ref r2, int k, EF *e)
{
	Ins icp;
	icp.op = Ocopy;
	icp.arg[0] = r2;
	icp.arg[1] = R;
	icp.to = r1;
	icp.cls = k;
	emitins(icp, e);
}

static void
enc_two_addr(int commutes, Ins *i, EF *e)
{
	if (commutes && req(i->arg[1], i->to)) {
		Ref r = i->arg[0];
		i->arg[0] = i->arg[1];
		i->arg[1] = r;
	}
	assert((!req(i->arg[1], i->to) || req(i->arg[0], i->to)) &&
		"elf: cannot convert to 2-address");
	emitcopy(i->to, i->arg[0], i->cls, e);
}

static const uint64_t negmask[4] = {
	[Ks] = 0x80000000ULL,
	[Kd] = 0x8000000000000000ULL,
};

static void
emitins(Ins i, EF *e)
{
	int is64 = KWIDE(i.cls);
	int isfp = KBASE(i.cls);

	switch (i.op) {
	case Onop:
	case Odbgloc:
		break;

	case Oadd:
		enc_two_addr(1, &i, e);
		if (isfp)
			enc_sse_bin(i.cls, 0x58, i.arg[1], i.to, e);
		else
			enc_alu_op(is64, 0, i.arg[1], i.to, e);
		break;

	case Osub:
		if (req(i.to, i.arg[1]) && !req(i.arg[0], i.to)) {
			Ins ineg = { .op = Oneg, .cls = i.cls, .to = i.to, .arg = { i.to, R } };
			emitins(ineg, e);
			if (isfp)
				enc_sse_bin(i.cls, 0x58, i.arg[0], i.to, e);
			else
				enc_alu_op(is64, 0, i.arg[0], i.to, e);
			break;
		}
		enc_two_addr(0, &i, e);
		if (isfp)
			enc_sse_bin(i.cls, 0x5c, i.arg[1], i.to, e);
		else
			enc_alu_op(is64, 5, i.arg[1], i.to, e);
		break;

	case Oneg:
		if (!req(i.to, i.arg[0]))
			emitcopy(i.to, i.arg[0], i.cls, e);
		if (!isfp) {
			RmOp d = ref_to_rm(i.to, 0, e);
			emit_modrm(0, is64, 0, 0xf7, -1, 3, d, 0, 0);
		} else {
			int id = stashbits(negmask[i.cls], 16);
			char sbuf[32];
			snprintf(sbuf, sizeof sbuf, "%sfp%d", T.asloc, id);
			uint32_t sym = sym_intern(sbuf);
			RmOp mem = rm_rip_sym(sym, R_X86_64_PC32, 0);
			assert(isreg(i.to));
			uint8_t pfx = (i.cls == Kd) ? 0x66 : 0x00;
			emit_modrm(pfx, 0, 0, 0x0f, 0x57, hw_reg(i.to.val), mem, 0, 0);
		}
		break;

	case Oand:
		enc_two_addr(1, &i, e);
		enc_alu_op(is64, 4, i.arg[1], i.to, e);
		break;

	case Oor:
		enc_two_addr(1, &i, e);
		enc_alu_op(is64, 1, i.arg[1], i.to, e);
		break;

	case Oxor:
		enc_two_addr(1, &i, e);
		enc_alu_op(is64, 6, i.arg[1], i.to, e);
		break;

	case Oshl:
	case Oshr:
	case Osar:
	case Oror: {
		uint8_t ext = (i.op == Oshl) ? 4 : (i.op == Oshr ? 5 : (i.op == Oror ? 1 : 7));
		enc_two_addr(0, &i, e);
		RmOp d = ref_to_rm(i.to, 0, e);
		if (rtype(i.arg[1]) == RCon) {
			Con *c = &e->fn->con[i.arg[1].val];
			assert(c->type == CBits);
			uint8_t cnt = (uint8_t)(c->bits.i & 0xff);
			if (cnt == 1)
				emit_modrm(0, is64, 0, 0xd1, -1, ext, d, 0, 0);
			else
				emit_modrm(0, is64, 0, 0xc1, -1, ext, d, 1, cnt);
		} else {
			assert(req(i.arg[1], TMP(RCX)));
			emit_modrm(0, is64, 0, 0xd3, -1, ext, d, 0, 0);
		}
		break;
	}

	case Omul:
		if (isfp) {
			enc_two_addr(1, &i, e);
			enc_sse_bin(i.cls, 0x59, i.arg[1], i.to, e);
			break;
		}
		if (rtype(i.arg[1]) == RCon) {
			Ref r = i.arg[0];
			i.arg[0] = i.arg[1];
			i.arg[1] = r;
		}
		if (rtype(i.arg[0]) == RCon && rtype(i.arg[1]) == RTmp && isreg(i.to)) {
			Con *c = &e->fn->con[i.arg[0].val];
			assert(c->type == CBits);
			int64_t v = is64 ? c->bits.i : (int64_t)(int32_t)(uint32_t)c->bits.i;
			RmOp s = ref_to_rm(i.arg[1], 0, e);
			uint8_t d = hw_reg(i.to.val);
			if (fits_i8(v))
				emit_modrm(0, is64, 0, 0x6b, -1, d, s, 1, (uint64_t)v);
			else {
				assert(fits_i32(v));
				emit_modrm(0, is64, 0, 0x69, -1, d, s, 4, (uint64_t)v);
			}
			break;
		}
		enc_two_addr(1, &i, e);
		assert(isreg(i.to));
		if (rtype(i.arg[1]) == RCon) {
			Con *c = &e->fn->con[i.arg[1].val];
			assert(c->type == CBits);
			int64_t v = is64 ? c->bits.i : (int64_t)(int32_t)(uint32_t)c->bits.i;
			uint8_t d = hw_reg(i.to.val);
			if (fits_i8(v))
				emit_modrm(0, is64, 0, 0x6b, -1, d, rm_reg(d), 1, (uint64_t)v);
			else {
				assert(fits_i32(v));
				emit_modrm(0, is64, 0, 0x69, -1, d, rm_reg(d), 4, (uint64_t)v);
			}
		} else {
			RmOp s = ref_to_rm(i.arg[1], 0, e);
			emit_modrm(0, is64, 0, 0x0f, 0xaf, hw_reg(i.to.val), s, 0, 0);
		}
		break;

	case Odiv:
		assert(isfp);
		if (req(i.to, i.arg[1])) {
			emitcopy(TMP(XMM15), i.to, i.cls, e);
			emitcopy(i.to, i.arg[0], i.cls, e);
			i.arg[0] = i.to;
			i.arg[1] = TMP(XMM15);
		}
		enc_two_addr(0, &i, e);
		enc_sse_bin(i.cls, 0x5e, i.arg[1], i.to, e);
		break;

	case Osign:
		if (is64)
			emit_u8(0x48);
		emit_u8(0x99);
		break;

	case Oxdiv:
	case Oxidiv: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		emit_modrm(0, is64, 0, 0xf7, -1, (i.op == Oxdiv) ? 6 : 7, s, 0, 0);
		break;
	}

	case Oximul: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		emit_modrm(0, is64, 0, 0xf7, -1, 5, s, 0, 0);
		break;
	}

	case Ostorel:
	case Ostorew:
	case Ostoreh:
	case Ostoreb: {
		RmOp m = ref_to_rm(i.arg[1], 1, e);
		if (rtype(i.arg[0]) == RCon) {
			Con *c = &e->fn->con[i.arg[0].val];
			assert(c->type == CBits);
			switch (i.op) {
			case Ostorel:
				assert(fits_i32(c->bits.i));
				emit_modrm(0, 1, 0, 0xc7, -1, 0, m, 4, (uint64_t)c->bits.i);
				break;
			case Ostorew:
				emit_modrm(0, 0, 0, 0xc7, -1, 0, m, 4, (uint64_t)c->bits.i);
				break;
			case Ostoreh:
				emit_modrm(0x66, 0, 0, 0xc7, -1, 0, m, 2, (uint64_t)c->bits.i);
				break;
			case Ostoreb:
				emit_modrm(0, 0, 0, 0xc6, -1, 0, m, 1, (uint64_t)c->bits.i);
				break;
			}
		} else {
			assert(isreg(i.arg[0]));
			uint8_t r = hw_reg(i.arg[0].val);
			if (is_xmm(i.arg[0].val)) {
				switch (i.op) {
				case Ostorel: emit_modrm(0x66, 0, 0, 0x0f, 0xd6, r, m, 0, 0); break; /* movq %xmm, m64 */
				case Ostorew: emit_modrm(0x66, 0, 0, 0x0f, 0x7e, r, m, 0, 0); break; /* movd %xmm, m32 */
				default: die("elf: invalid xmm store op %s", optab[i.op].name);
				}
			} else {
				switch (i.op) {
				case Ostorel: emit_modrm(0, 1, 0, 0x89, -1, r, m, 0, 0); break;
				case Ostorew: emit_modrm(0, 0, 0, 0x89, -1, r, m, 0, 0); break;
				case Ostoreh: emit_modrm(0x66, 0, 0, 0x89, -1, r, m, 0, 0); break;
				case Ostoreb: emit_modrm(0, 0, needs_byte_rex(r), 0x88, -1, r, m, 0, 0); break;
				}
			}
		}
		break;
	}

	case Ostores:
	case Ostored: {
		RmOp m = ref_to_rm(i.arg[1], 1, e);
		assert(isreg(i.arg[0]));
		assert(is_xmm(i.arg[0].val));
		uint8_t r = hw_reg(i.arg[0].val);
		uint8_t pfx = (i.op == Ostored) ? 0xf2 : 0xf3;
		emit_modrm(pfx, 0, 0, 0x0f, 0x11, r, m, 0, 0);
		break;
	}

	case Oload: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		uint8_t d = hw_reg(i.to.val);
		if (isfp) {
			assert(is_xmm(i.to.val));
			uint8_t pfx = (i.cls == Kd) ? 0xf2 : 0xf3;
			emit_modrm(pfx, 0, 0, 0x0f, 0x10, d, m, 0, 0);
		} else {
			assert(!is_xmm(i.to.val));
			emit_modrm(0, is64, 0, 0x8b, -1, d, m, 0, 0);
		}
		break;
	}

	case Oloadsw: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		uint8_t d = hw_reg(i.to.val);
		if (i.cls == Kl)
			emit_modrm(0, 1, 0, 0x63, -1, d, m, 0, 0);
		else
			emit_modrm(0, 0, 0, 0x8b, -1, d, m, 0, 0);
		break;
	}

	case Oloaduw: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		emit_modrm(0, 0, 0, 0x8b, -1, hw_reg(i.to.val), m, 0, 0);
		break;
	}

	case Oloadsh: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xbf, hw_reg(i.to.val), m, 0, 0);
		break;
	}

	case Oloaduh: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xb7, hw_reg(i.to.val), m, 0, 0);
		break;
	}

	case Oloadsb: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xbe, hw_reg(i.to.val), m, 0, 0);
		break;
	}

	case Oloadub: {
		RmOp m = ref_to_rm(i.arg[0], 1, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xb6, hw_reg(i.to.val), m, 0, 0);
		break;
	}

	case Oextsw: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0, 1, 0, 0x63, -1, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oextuw: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0, 0, 0, 0x8b, -1, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oextsh: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xbf, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oextuh: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0, is64, 0, 0x0f, 0xb7, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oextsb: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		int frex = (!s.is_mem && needs_byte_rex(s.reg));
		emit_modrm(0, is64, frex, 0x0f, 0xbe, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oextub: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		int frex = (!s.is_mem && needs_byte_rex(s.reg));
		emit_modrm(0, is64, frex, 0x0f, 0xb6, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oexts: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0xf3, 0, 0, 0x0f, 0x5a, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Otruncd: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		emit_modrm(0xf2, 0, 0, 0x0f, 0x5a, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Osqrt: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		uint8_t pfx = (i.cls == Kd) ? 0xf2 : 0xf3;
		emit_modrm(pfx, 0, 0, 0x0f, 0x51, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Ostosi:
	case Odtosi: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		uint8_t pfx = (i.op == Odtosi) ? 0xf2 : 0xf3;
		emit_modrm(pfx, is64, 0, 0x0f, 0x2c, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Oswtof:
	case Osltof: {
		RmOp s = ref_to_rm(i.arg[0], 0, e);
		assert(isreg(i.to));
		uint8_t pfx = (i.cls == Kd) ? 0xf2 : 0xf3;
		int w = (i.op == Osltof) ? 1 : 0;
		emit_modrm(pfx, w, 0, 0x0f, 0x2a, hw_reg(i.to.val), s, 0, 0);
		break;
	}

	case Ocast:
		if (!isfp) {
			/* float (xmm or slot) -> int (gpr or slot) */
			RmOp d = ref_to_rm(i.to, 0, e);
			if (isreg(i.arg[0])) {
				emit_modrm(0x66, 1, 0, 0x0f, 0x7e, hw_reg(i.arg[0].val), d, 0, 0);
			} else {
				RmOp s = ref_to_rm(i.arg[0], 0, e);
				assert(!d.is_mem);
				emit_modrm(0, 1, 0, 0x8b, -1, d.reg, s, 0, 0);
			}
		} else {
			/* int (gpr or slot) -> float (xmm or slot) */
			RmOp s = ref_to_rm(i.arg[0], 0, e);
			if (isreg(i.to)) {
				emit_modrm(0x66, 1, 0, 0x0f, 0x6e, hw_reg(i.to.val), s, 0, 0);
			} else {
				RmOp d = ref_to_rm(i.to, 0, e);
				assert(!s.is_mem);
				emit_modrm(0, 1, 0, 0x89, -1, s.reg, d, 0, 0);
			}
		}
		break;

	case Ocopy: {
		assert(rtype(i.to) != RMem);
		if (req(i.to, R) || req(i.arg[0], R) || req(i.to, i.arg[0]))
			break;
		int t0 = rtype(i.arg[0]);
		if (i.cls == Kl && t0 == RCon && e->fn->con[i.arg[0].val].type == CBits) {
			int64_t val = e->fn->con[i.arg[0].val].bits.i;
			if (isreg(i.to)) {
				enc_mov_imm_reg(1, hw_reg(i.to.val), val);
				break;
			}
			if (rtype(i.to) == RSlot) {
				RmOp m = ref_to_rm(i.to, 0, e);
				if (fits_i32(val)) {
					emit_modrm(0, 1, 0, 0xc7, -1, 0, m, 4, (uint64_t)val);
				} else {
					emit_modrm(0, 0, 0, 0xc7, -1, 0, m, 4, (uint64_t)(uint32_t)val);
					m.disp += 4;
					emit_modrm(0, 0, 0, 0xc7, -1, 0, m, 4, (uint64_t)(uint32_t)((uint64_t)val >> 32));
				}
				break;
			}
		}
		if (isreg(i.to) && t0 == RCon && e->fn->con[i.arg[0].val].type == CAddr) {
			RmOp m = ref_to_rm(i.arg[0], 1, e);
			emit_modrm(0, is64, 0, 0x8d, -1, hw_reg(i.to.val), m, 0, 0);
			break;
		}
		if (rtype(i.to) == RSlot && (t0 == RSlot || t0 == RMem)) {
			int fk = KWIDE(i.cls) ? Kd : Ks;
			emitcopy(TMP(XMM15), i.arg[0], fk, e);
			emitcopy(i.to, TMP(XMM15), fk, e);
			break;
		}
		if (isfp) {
			uint8_t pfx = (i.cls == Kd) ? 0xf2 : 0xf3;
			if (isreg(i.to)) {
				assert(is_xmm(i.to.val));
				if (isreg(i.arg[0]))
					assert(is_xmm(i.arg[0].val));
				RmOp s = ref_to_rm(i.arg[0], 0, e);
				emit_modrm(pfx, 0, 0, 0x0f, 0x10, hw_reg(i.to.val), s, 0, 0);
			} else {
				RmOp d = ref_to_rm(i.to, 0, e);
				assert(isreg(i.arg[0]));
				assert(is_xmm(i.arg[0].val));
				emit_modrm(pfx, 0, 0, 0x0f, 0x11, hw_reg(i.arg[0].val), d, 0, 0);
			}
		} else {
			if (t0 == RCon) {
				Con *c = &e->fn->con[i.arg[0].val];
				assert(c->type == CBits);
				if (isreg(i.to)) {
					assert(!is_xmm(i.to.val));
					enc_mov_imm_reg(is64, hw_reg(i.to.val), c->bits.i);
				} else {
					RmOp d = ref_to_rm(i.to, 0, e);
					emit_modrm(0, is64, 0, 0xc7, -1, 0, d, 4, (uint64_t)c->bits.i);
				}
			} else if (isreg(i.arg[0])) {
				assert(!is_xmm(i.arg[0].val));
				if (isreg(i.to))
					assert(!is_xmm(i.to.val));
				RmOp d = ref_to_rm(i.to, 0, e);
				emit_modrm(0, is64, 0, 0x89, -1, hw_reg(i.arg[0].val), d, 0, 0);
			} else {
				RmOp s = ref_to_rm(i.arg[0], 0, e);
				assert(isreg(i.to));
				assert(!is_xmm(i.to.val));
				emit_modrm(0, is64, 0, 0x8b, -1, hw_reg(i.to.val), s, 0, 0);
			}
		}
		break;
	}

	case Oaddr:
		assert(isreg(i.to));
		if (rtype(i.arg[0]) == RCon) {
			Con *con = &e->fn->con[i.arg[0].val];
			assert(con->type == CAddr);
			uint8_t d = hw_reg(i.to.val);
			uint32_t sym = sym_ref_qbe(str(con->sym.id));
			switch (con->sym.type) {
			case SThr: {
				/* movq %fs:0, %d */
				RmOp fs0;
				memset(&fs0, 0, sizeof fs0);
				fs0.is_mem = 1;
				fs0.base = -1;
				fs0.index = -1;
				fs0.scale = 1;
				fs0.disp = 0;
				fs0.sym = SYM_NONE;
				fs0.seg_fs = 1;
				emit_modrm(0, 1, 0, 0x8b, -1, d, fs0, 0, 0);
				/* leaq sym@tpoff[+off](%d), %d */
				RmOp m = rm_base_disp((int)d, con->bits.i);
				m.sym = sym;
				m.rel_type = R_X86_64_TPOFF32;
				emit_modrm(0, 1, 0, 0x8d, -1, d, m, 0, 0);
				break;
			}
			case SExtThr: {
				assert(!con->bits.i);
				RmOp fs0;
				memset(&fs0, 0, sizeof fs0);
				fs0.is_mem = 1;
				fs0.base = -1;
				fs0.index = -1;
				fs0.scale = 1;
				fs0.disp = 0;
				fs0.sym = SYM_NONE;
				fs0.seg_fs = 1;
				emit_modrm(0, 1, 0, 0x8b, -1, d, fs0, 0, 0);
				/* addq sym@gottpoff(%rip), %d */
				RmOp m = rm_rip_sym(sym, R_X86_64_GOTTPOFF, 0);
				emit_modrm(0, 1, 0, 0x03, -1, d, m, 0, 0);
				break;
			}
			case SExt: {
				assert(!con->bits.i);
				/* movq sym@gotpcrel(%rip), %d */
				RmOp m = rm_rip_sym(sym, R_X86_64_GOTPCREL, 0);
				emit_modrm(0, 1, 0, 0x8b, -1, d, m, 0, 0);
				break;
			}
			default: {
				/* leaq sym[+off](%rip), %d */
				RmOp m = rm_rip_sym(sym, R_X86_64_PC32, con->bits.i);
				emit_modrm(0, is64, 0, 0x8d, -1, d, m, 0, 0);
				break;
			}
			}
		} else {
			RmOp m = ref_to_rm(i.arg[0], 1, e);
			emit_modrm(0, is64, 0, 0x8d, -1, hw_reg(i.to.val), m, 0, 0);
		}
		break;

	case Oswap:
		if (isfp) {
			emitcopy(TMP(XMM15), i.arg[0], i.cls, e);
			emitcopy(i.arg[0], i.arg[1], i.cls, e);
			emitcopy(i.arg[1], TMP(XMM15), i.cls, e);
		} else {
			RmOp a = ref_to_rm(i.arg[0], 0, e);
			RmOp b = ref_to_rm(i.arg[1], 0, e);
			if (!a.is_mem)
				emit_modrm(0, is64, 0, 0x87, -1, a.reg, b, 0, 0);
			else {
				assert(!b.is_mem);
				emit_modrm(0, is64, 0, 0x87, -1, b.reg, a, 0, 0);
			}
		}
		break;

	case Oxcmp:
		if (isfp) {
			/* ucomiss/ucomisd %S0, %S1 -> reg=arg[1], rm=arg[0] */
			uint8_t pfx = (i.cls == Kd) ? 0x66 : 0x00;
			RmOp s0 = ref_to_rm(i.arg[0], 0, e);
			assert(isreg(i.arg[1]));
			emit_modrm(pfx, 0, 0, 0x0f, 0x2e, hw_reg(i.arg[1].val), s0, 0, 0);
		} else {
			/* cmp%k %0, %1 -> compute %1 - %0; cmp $0, %r == test %r, %r */
			if (rtype(i.arg[0]) == RCon && isreg(i.arg[1])) {
				Con *c = &e->fn->con[i.arg[0].val];
				if (c->type == CBits
				&& (is64 ? c->bits.i : (int64_t)(int32_t)(uint32_t)c->bits.i) == 0) {
					RmOp d = rm_reg(hw_reg(i.arg[1].val));
					emit_modrm(0, is64, 0, 0x85, -1, d.reg, d, 0, 0);
					break;
				}
			}
			enc_alu_op(is64, 7, i.arg[0], i.arg[1], e);
		}
		break;

	case Oxtest:
		if (rtype(i.arg[0]) == RCon) {
			Con *c = &e->fn->con[i.arg[0].val];
			assert(c->type == CBits);
			int64_t v = is64 ? c->bits.i : (int64_t)(int32_t)(uint32_t)c->bits.i;
			assert(fits_i32(v));
			RmOp d = ref_to_rm(i.arg[1], 0, e);
			emit_modrm(0, is64, 0, 0xf7, -1, 0, d, 4, (uint64_t)v);
		} else {
			RmOp a = ref_to_rm(i.arg[0], 0, e);
			RmOp b = ref_to_rm(i.arg[1], 0, e);
			if (!a.is_mem)
				emit_modrm(0, is64, 0, 0x85, -1, a.reg, b, 0, 0);
			else {
				assert(!b.is_mem);
				emit_modrm(0, is64, 0, 0x85, -1, b.reg, a, 0, 0);
			}
		}
		break;

	case Ocall:
		switch (rtype(i.arg[0])) {
		case RCon: {
			Con *con = &e->fn->con[i.arg[0].val];
			assert(con->type == CAddr);
			uint32_t sym = sym_ref_qbe(str(con->sym.id));
			emit_u8(0xe8);
			uint32_t disp_off = text_pos();
			sec_add_reloc(E0.cur_text_sec, disp_off, sym, R_X86_64_PLT32, con->bits.i - 4);
			emit_u32(0);
			break;
		}
		case RTmp: {
			assert(isreg(i.arg[0]));
			RmOp t = rm_reg(hw_reg(i.arg[0].val));
			emit_modrm(0, 0, 0, 0xff, -1, 2, t, 0, 0);
			break;
		}
		default:
			die("elf: invalid call argument");
		}
		break;

	case Osalloc:
		assert(e->fp == RBP);
		enc_alu_op(1, 5, i.arg[0], TMP(RSP), e);
		if (!req(i.to, R))
			emitcopy(i.to, TMP(RSP), Kl, e);
		break;

	default:
		if (INRANGE(i.op, Oflag, Oflag1)) {
			int c = i.op - Oflag;
			uint8_t cc = cmp_cc[c][0];
			assert(isreg(i.to));
			uint8_t d = hw_reg(i.to.val);
			int frex = needs_byte_rex(d);
			/* setcc %dl */
			emit_modrm(0, 0, frex, 0x0f, (int)(0x90u | cc), 0, rm_reg(d), 0, 0);
			/* movzb%k %dl, %d */
			emit_modrm(0, is64, frex, 0x0f, 0xb6, d, rm_reg(d), 0, 0);
			break;
		}
		if (isxsel(i.op)) {
			int c = i.op - Oxsel;
			assert(isreg(i.to));
			uint8_t d = hw_reg(i.to.val);
			if (req(i.to, i.arg[1])) {
				uint8_t cc = cmp_cc[c][0];
				RmOp s = ref_to_rm(i.arg[0], 0, e);
				emit_modrm(0, is64, 0, 0x0f, (int)(0x40u | cc), d, s, 0, 0);
			} else {
				if (!req(i.to, i.arg[0]))
					emitcopy(i.to, i.arg[0], i.cls, e);
				uint8_t cc = cmp_cc[c][1];
				RmOp s = ref_to_rm(i.arg[1], 0, e);
				emit_modrm(0, is64, 0, 0x0f, (int)(0x40u | cc), d, s, 0, 0);
			}
			break;
		}
		die("elf: unhandled op %s(%c)", optab[i.op].name, "wlsd"[i.cls]);
	}
}

/* ---- Inline PIC Jump Table ---- */

static void
emitjtbl(Blk *b, EF *e)
{
	uint8_t idx_hw;

	if (rtype(b->jmp.arg) == RSlot) {
		RmOp m = ref_to_rm(b->jmp.arg, 1, e);
		idx_hw = hw_reg(R10);
		/* movl slot(%fp), %r10d (zero-extends to %r10) */
		emit_modrm(0, 0, 0, 0x8b, -1, idx_hw, m, 0, 0);
	} else {
		assert(isreg(b->jmp.arg));
		idx_hw = hw_reg(b->jmp.arg.val);
	}

	/* cmpl $njtbl, %idx_d */
	enc_alu_imm(0, 7, rm_reg(idx_hw), (int64_t)(int32_t)b->njtbl);

	/* jae default_blk (b->s1) */
	emit_u8(0x0f);
	emit_u8((uint8_t)(0x80u | CC_AE));
	uint32_t jae_disp = text_pos();
	emit_u32(0);
	ef_add_fixup(e, jae_disp, text_pos(), b->s1->id, 1, CC_AE);

	/* leaq tbl(%rip), %r11 */
	uint8_t r11 = hw_reg(R11);
	uint8_t r10 = hw_reg(R10);
	/* 4C 8D 1D <disp32> */
	emit_u8(0x4c);
	emit_u8(0x8d);
	emit_u8((uint8_t)(((r11 & 7u) << 3) | 5u));
	uint32_t lea_disp_off = text_pos();
	emit_u32(0);
	uint32_t lea_next_pc = text_pos();

	/* Ensure %r10 holds zero-extended 32-bit index */
	if (rtype(b->jmp.arg) != RSlot)
		emit_modrm(0, 0, 0, 0x89, -1, idx_hw, rm_reg(r10), 0, 0);

	/* movslq (%r11,%r10,4), %r10 */
	RmOp tbl_elem;
	memset(&tbl_elem, 0, sizeof tbl_elem);
	tbl_elem.is_mem = 1;
	tbl_elem.base = (int)r11;
	tbl_elem.index = (int)r10;
	tbl_elem.scale = 4;
	tbl_elem.sym = SYM_NONE;
	emit_modrm(0, 1, 0, 0x63, -1, r10, tbl_elem, 0, 0);

	/* addq %r10, %r11 */
	emit_modrm(0, 1, 0, 0x01, -1, r10, rm_reg(r11), 0, 0);

	/* jmpq *%r11 */
	emit_modrm(0, 0, 0, 0xff, -1, 4, rm_reg(r11), 0, 0);

	/* Align inline 32-bit offset table to 4 bytes */
	sec_align(E0.cur_text_sec, 4);
	uint32_t tbl_base_off = text_pos();

	/* Patch leaq disp32 */
	patch_u32(text_buf()->data + lea_disp_off,
		(uint32_t)(int32_t)(tbl_base_off - lea_next_pc));

	for (uint32_t jk = 0; jk < b->njtbl; jk++) {
		uint32_t entry_off = text_pos();
		ef_add_jtfixup(e, entry_off, tbl_base_off, b->jtbl[jk]->id);
		emit_u32(0);
	}
}

/* ---- Function emission ---- */

static int resolve_custom_sec(const char *sec_str, const char *secf_str);

void
amd64_elf_fn(Fn *fn)
{
	EF e;
	memset(&e, 0, sizeof e);
	e.fn = fn;

	uint64_t al = fn->lnk.align > 0 ? (uint64_t)fn->lnk.align : 16ULL;
	if (al < 16)
		al = 16;
	int fn_sec = SEC_TEXT;
	if (fn->lnk.sec) {
		fn_sec = resolve_custom_sec(fn->lnk.sec, fn->lnk.secf);
	} else if (E0.nsecs < 28000 && fn->name[0] != '\0') {
		char sname[224];
		make_subsec_name(sname, sizeof sname, ".text.", fn->name);
		fn_sec = add_sec(sname, SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, al, 0);
	}
	E0.cur_text_sec = fn_sec;
	sec_align(E0.cur_text_sec, al);

	uint64_t fn_start = sec_size(&E0.secs[E0.cur_text_sec]);
	int exclusive_sec = (fn->lnk.sec == NULL && E0.cur_text_sec != SEC_TEXT
		&& fn_start == 0 && E0.secs[E0.cur_text_sec].nrelocs == 0);
	int has_inner_align = 0;
	int has_jtbl = 0;
	uint32_t fn_sym = sym_define(fn->name, E0.cur_text_sec, fn_start, fn->lnk.export, STT_FUNC);

	/* endbr64 */
	emit_u8(0xf3);
	emit_u8(0x0f);
	emit_u8(0x1e);
	emit_u8(0xfa);

	if (!fn->leaf || fn->vararg || fn->dynalloc) {
		e.fp = RBP;
		enc_push_reg(hw_reg(RBP));
		/* movq %rsp, %rbp */
		emit_modrm(0, 1, 0, 0x89, -1, hw_reg(RSP), rm_reg(hw_reg(RBP)), 0, 0);
	} else {
		e.fp = RSP;
	}

	sysv_framesz(&e);
	if (e.fsz) {
		if (e.fsz <= (uint64_t)INT32_MAX) {
			enc_alu_imm(1, 5, rm_reg(hw_reg(RSP)), (int64_t)e.fsz);
		} else {
			enc_mov_imm_reg(1, hw_reg(R11), (int64_t)e.fsz);
			emit_modrm(0, 1, 0, 0x29, -1, hw_reg(R11), rm_reg(hw_reg(RSP)), 0, 0);
		}
	}

	if (fn->vararg) {
		int o = -176;
		for (int *r = amd64_sysv_rsave; r < &amd64_sysv_rsave[6]; r++, o += 8) {
			emit_modrm(0, 1, 0, 0x89, -1, hw_reg(*r), rm_base_disp(hw_reg(RBP), o), 0, 0);
		}
		for (int n = 0; n < 8; n++, o += 16) {
			/* movaps %xmmN, o(%rbp) */
			emit_modrm(0, 0, 0, 0x0f, 0x29, (uint8_t)n, rm_base_disp(hw_reg(RBP), o), 0, 0);
		}
	}

	for (int *r = amd64_sysv_rclob; r < &amd64_sysv_rclob[NCLR_SYSV]; r++) {
		if (fn->reg & BIT(*r)) {
			enc_push_reg(hw_reg(*r));
			e.nclob++;
		}
	}

	uint32_t *blk_off = emalloc((fn->nblk ? fn->nblk : 1) * sizeof *blk_off);
	int lbl = 0;

	for (Blk *b = fn->start; b; b = b->link) {
		if (lbl || b->npred > 1) {
			uint p;
			for (p = 0; p < b->npred; p++)
				if (b->pred[p]->id >= b->id)
					break;
			if (p != b->npred) {
				has_inner_align = 1;
				sec_align(E0.cur_text_sec, 16);
			}
		}
		blk_off[b->id] = text_pos();

		for (Ins *i = b->ins; i != &b->ins[b->nins]; i++)
			emitins(*i, &e);

		lbl = 1;
		switch (b->jmp.type) {
		case Jhlt:
			emit_u8(0x0f);
			emit_u8(0x0b);
			break;

		case Jret0:
			if (fn->dynalloc) {
				/* movq %rbp, %rsp */
				emit_modrm(0, 1, 0, 0x89, -1, hw_reg(RBP), rm_reg(hw_reg(RSP)), 0, 0);
				uint64_t tot = e.fsz + (uint64_t)e.nclob * 8;
				if (tot) {
					if (tot <= (uint64_t)INT32_MAX) {
						enc_alu_imm(1, 5, rm_reg(hw_reg(RSP)), (int64_t)tot);
					} else {
						enc_mov_imm_reg(1, hw_reg(R11), (int64_t)tot);
						emit_modrm(0, 1, 0, 0x29, -1, hw_reg(R11), rm_reg(hw_reg(RSP)), 0, 0);
					}
				}
			}
			for (int *r = &amd64_sysv_rclob[NCLR_SYSV]; r > amd64_sysv_rclob; ) {
				if (fn->reg & BIT(*--r))
					enc_pop_reg(hw_reg(*r));
			}
			if (e.fp == RBP) {
				emit_u8(0xc9); /* leave */
			} else if (e.fsz) {
				if (e.fsz <= (uint64_t)INT32_MAX) {
					enc_alu_imm(1, 0, rm_reg(hw_reg(RSP)), (int64_t)e.fsz);
				} else {
					enc_mov_imm_reg(1, hw_reg(R11), (int64_t)e.fsz);
					emit_modrm(0, 1, 0, 0x01, -1, hw_reg(R11), rm_reg(hw_reg(RSP)), 0, 0);
				}
			}
			emit_u8(0xc3); /* ret */
			break;

		case Jjmp:
		Jmp:
			if (b->s1 != b->link) {
				emit_u8(0xe9);
				uint32_t disp_off = text_pos();
				emit_u32(0);
				ef_add_fixup(&e, disp_off, text_pos(), b->s1->id, 0, 0);
			} else {
				lbl = 0;
			}
			break;

		case Jjtbl:
			has_jtbl = 1;
			emitjtbl(b, &e);
			break;

		default: {
			int c = b->jmp.type - Jjf;
			if (0 <= c && c < NCmp) {
				int n;
				if (b->link == b->s2) {
					Blk *s = b->s1;
					b->s1 = b->s2;
					b->s2 = s;
					n = 0;
				} else {
					n = 1;
				}
				uint8_t cc = cmp_cc[c][n];
				emit_u8(0x0f);
				emit_u8((uint8_t)(0x80u | cc));
				uint32_t disp_off = text_pos();
				emit_u32(0);
				ef_add_fixup(&e, disp_off, text_pos(), b->s2->id, 1, cc);
				goto Jmp;
			}
			die("elf: unhandled jump %d", b->jmp.type);
		}
		}
	}

	uint8_t *code = text_buf()->data;

	if (exclusive_sec && !has_inner_align && !has_jtbl && e.nfixups > 0) {
		size_t nf = e.nfixups;
		uint32_t orig_len = text_pos();
		uint8_t *is_short = calloc(nf, 1);
		uint32_t *pref = emalloc((nf + 1) * sizeof *pref);
		uint32_t *new_blk = emalloc((fn->nblk ? fn->nblk : 1) * sizeof *new_blk);
		uint32_t *new_next = emalloc(nf * sizeof *new_next);
		if (!is_short)
			die("elf: out of memory");

		int changed = 1;
		while (changed) {
			changed = 0;
			pref[0] = 0;
			for (size_t k = 0; k < nf; k++) {
				uint32_t sh = is_short[k] ? (e.fixups[k].is_cond ? 4u : 3u) : 0u;
				pref[k + 1] = pref[k] + sh;
				new_next[k] = e.fixups[k].next_pc - pref[k + 1];
			}
			for (uint32_t bid = 0; bid < fn->nblk; bid++) {
				uint32_t orig = blk_off[bid];
				size_t lo = 0, hi = nf;
				while (lo < hi) {
					size_t mid = lo + (hi - lo) / 2;
					if (e.fixups[mid].next_pc <= orig)
						lo = mid + 1;
					else
						hi = mid;
				}
				new_blk[bid] = orig - pref[lo];
			}
			for (size_t k = 0; k < nf; k++) {
				int64_t diff = (int64_t)new_blk[e.fixups[k].target_bid] - (int64_t)new_next[k];
				if (!is_short[k] && fits_i8(diff)) {
					is_short[k] = 1;
					changed = 1;
				} else if (is_short[k] && !fits_i8(diff)) {
					is_short[k] = 0;
					changed = 1;
				}
			}
		}

		if (pref[nf] > 0) {
			uint8_t *dst = code;
			uint32_t src_pos = 0;
			for (size_t k = 0; k < nf; k++) {
				BrFixup *f = &e.fixups[k];
				uint32_t op_off = f->disp_off - (f->is_cond ? 2u : 1u);
				size_t chunk = (size_t)(op_off - src_pos);
				if (chunk)
					memmove(dst, code + src_pos, chunk);
				dst += chunk;
				int64_t diff = (int64_t)new_blk[f->target_bid] - (int64_t)new_next[k];
				if (is_short[k]) {
					assert(fits_i8(diff));
					*dst++ = f->is_cond ? (uint8_t)(0x70u | f->cc) : 0xeb;
					*dst++ = (uint8_t)(int8_t)diff;
				} else {
					if (!fits_i32(diff))
						die("elf: branch out of 2GB range in %s", fn->name);
					if (f->is_cond) {
						*dst++ = 0x0f;
						*dst++ = (uint8_t)(0x80u | f->cc);
					} else {
						*dst++ = 0xe9;
					}
					patch_u32(dst, (uint32_t)(int32_t)diff);
					dst += 4;
				}
				assert((uint32_t)(dst - code) == new_next[k]);
				src_pos = f->next_pc;
			}
			size_t tail = (size_t)(orig_len - src_pos);
			if (tail)
				memmove(dst, code + src_pos, tail);
			dst += tail;
			text_buf()->len = (size_t)(dst - code);

			Sec *sec = &E0.secs[E0.cur_text_sec];
			for (size_t r = 0; r < sec->nrelocs; r++) {
				uint64_t roff = sec->relocs[r].offset;
				size_t lo = 0, hi = nf;
				while (lo < hi) {
					size_t mid = lo + (hi - lo) / 2;
					if ((uint64_t)e.fixups[mid].next_pc <= roff)
						lo = mid + 1;
					else
						hi = mid;
				}
				sec->relocs[r].offset = roff - pref[lo];
			}
		} else {
			for (size_t k = 0; k < nf; k++) {
				BrFixup *f = &e.fixups[k];
				int64_t diff = (int64_t)blk_off[f->target_bid] - (int64_t)f->next_pc;
				if (!fits_i32(diff))
					die("elf: branch out of 2GB range in %s", fn->name);
				patch_u32(code + f->disp_off, (uint32_t)(int32_t)diff);
			}
		}

		free(is_short);
		free(pref);
		free(new_blk);
		free(new_next);
	} else {
		/* Patch branch rel32 displacements */
		for (size_t k = 0; k < e.nfixups; k++) {
			BrFixup *f = &e.fixups[k];
			int64_t diff = (int64_t)blk_off[f->target_bid] - (int64_t)f->next_pc;
			if (!fits_i32(diff))
				die("elf: branch out of 2GB range in %s", fn->name);
			patch_u32(code + f->disp_off, (uint32_t)(int32_t)diff);
		}
	}

	/* Patch inline jump table entries */
	for (size_t k = 0; k < e.njtfixups; k++) {
		JtblFixup *jf = &e.jtfixups[k];
		int64_t diff = (int64_t)blk_off[jf->target_bid] - (int64_t)jf->tbl_base_off;
		if (!fits_i32(diff))
			die("elf: jtbl offset out of range in %s", fn->name);
		patch_u32(code + jf->entry_off, (uint32_t)(int32_t)diff);
	}

	E0.syms[fn_sym].size = sec_size(&E0.secs[E0.cur_text_sec]) - fn_start;

	free(blk_off);
	free(e.fixups);
	free(e.jtfixups);
}

/* ---- Data section emission ---- */

static int
resolve_custom_sec(const char *sec_str, const char *secf_str)
{
	char name[128];
	const char *p = sec_str;
	if (*p == '"')
		p++;
	size_t i = 0;
	while (*p && *p != '"' && *p != ',' && i + 1 < sizeof name)
		name[i++] = *p++;
	name[i] = '\0';

	if (strcmp(name, ".text") == 0)   return SEC_TEXT;
	if (strcmp(name, ".rodata") == 0) return SEC_RODATA;
	if (strcmp(name, ".data") == 0)   return SEC_DATA;
	if (strcmp(name, ".bss") == 0)    return SEC_BSS;
	if (strcmp(name, ".tdata") == 0)  return SEC_TDATA;
	if (strcmp(name, ".tbss") == 0)   return SEC_TBSS;

	for (size_t k = 0; k < E0.nsecs; k++) {
		if (strcmp(E0.secs[k].name, name) == 0)
			return (int)k;
	}

	uint64_t flags = SHF_ALLOC;
	if (secf_str) {
		for (const char *q = secf_str; *q; q++) {
			if (*q == 'w') flags |= SHF_WRITE;
			if (*q == 'x') flags |= SHF_EXECINSTR;
			if (*q == 'T') flags |= SHF_TLS;
		}
	} else {
		flags |= SHF_WRITE;
	}
	return add_sec(name, SHT_PROGBITS, flags, 1, 0);
}

static void
emit_ascii_str(Buf *b, const char *s)
{
	size_t len = strlen(s);
	const char *p = s;
	const char *end = s + len;
	if (len >= 2 && s[0] == '"' && s[len - 1] == '"') {
		p++;
		end--;
	}
	while (p < end) {
		if (*p == '\\' && p + 1 < end) {
			p++;
			switch (*p) {
			case 'n':  buf_put_u8(b, '\n'); p++; break;
			case 't':  buf_put_u8(b, '\t'); p++; break;
			case 'r':  buf_put_u8(b, '\r'); p++; break;
			case 'b':  buf_put_u8(b, '\b'); p++; break;
			case 'f':  buf_put_u8(b, '\f'); p++; break;
			case 'v':  buf_put_u8(b, '\v'); p++; break;
			case 'a':  buf_put_u8(b, '\a'); p++; break;
			case '\\': buf_put_u8(b, '\\'); p++; break;
			case '"':  buf_put_u8(b, '"');  p++; break;
			case '\'': buf_put_u8(b, '\''); p++; break;
			case 'x': {
				p++;
				uint32_t v = 0;
				while (p < end) {
					char c = *p;
					if (c >= '0' && c <= '9') v = (v << 4) | (uint32_t)(c - '0');
					else if (c >= 'a' && c <= 'f') v = (v << 4) | (uint32_t)(c - 'a' + 10);
					else if (c >= 'A' && c <= 'F') v = (v << 4) | (uint32_t)(c - 'A' + 10);
					else break;
					p++;
				}
				buf_put_u8(b, (uint8_t)v);
				break;
			}
			default:
				if (*p >= '0' && *p <= '7') {
					uint32_t v = 0;
					for (int d = 0; d < 3 && p < end && *p >= '0' && *p <= '7'; d++, p++)
						v = (v << 3) | (uint32_t)(*p - '0');
					buf_put_u8(b, (uint8_t)v);
				} else {
					buf_put_u8(b, (uint8_t)*p++);
				}
				break;
			}
		} else {
			buf_put_u8(b, (uint8_t)*p++);
		}
	}
}

static int
dat_open_sec(int default_sec)
{
	int sec_idx = default_sec;
	uint64_t al = E0.dat_lnk.align > 0 ? (uint64_t)E0.dat_lnk.align : 1ULL;

	if (E0.dat_sec_str) {
		sec_idx = resolve_custom_sec(E0.dat_sec_str, E0.dat_secf_str);
	} else if (!E0.dat_lnk.thread && !E0.dat_lnk.common && E0.nsecs < 28000 &&
	    E0.dat_name && E0.dat_name[0] != '\0' &&
	    (default_sec == SEC_RODATA || default_sec == SEC_DATA || default_sec == SEC_BSS)) {
		char sname[224];
		if (default_sec == SEC_RODATA) {
			make_subsec_name(sname, sizeof sname, ".rodata.", E0.dat_name);
			sec_idx = add_sec(sname, SHT_PROGBITS, SHF_ALLOC, al, 0);
		} else if (default_sec == SEC_DATA) {
			make_subsec_name(sname, sizeof sname, ".data.", E0.dat_name);
			sec_idx = add_sec(sname, SHT_PROGBITS, SHF_ALLOC | SHF_WRITE, al, 0);
		} else {
			make_subsec_name(sname, sizeof sname, ".bss.", E0.dat_name);
			sec_idx = add_sec(sname, SHT_NOBITS, SHF_ALLOC | SHF_WRITE, al, 1);
		}
	}

	sec_align(sec_idx, al);
	E0.dat_start_off = sec_size(&E0.secs[sec_idx]);
	uint8_t st_type = E0.dat_lnk.thread ? STT_TLS : STT_OBJECT;
	E0.dat_sym_idx = sym_define(E0.dat_name, sec_idx, E0.dat_start_off, E0.dat_lnk.export, st_type);
	return sec_idx;
}

void
amd64_elf_dat(Dat *d)
{
	switch (d->type) {
	case DStart:
		free(E0.dat_name);
		free(E0.dat_sec_str);
		free(E0.dat_secf_str);
		E0.dat_name = emalloc(strlen(d->name) + 1);
		strcpy(E0.dat_name, d->name);
		E0.dat_lnk = *d->lnk;
		E0.dat_sec_str = d->lnk->sec ? emalloc(strlen(d->lnk->sec) + 1) : 0;
		if (E0.dat_sec_str) strcpy(E0.dat_sec_str, d->lnk->sec);
		E0.dat_secf_str = d->lnk->secf ? emalloc(strlen(d->lnk->secf) + 1) : 0;
		if (E0.dat_secf_str) strcpy(E0.dat_secf_str, d->lnk->secf);
		E0.dat_sec_idx = -1;
		E0.dat_zero = 0;
		E0.dat_sym_idx = SYM_NONE;
		E0.dat_start_off = 0;
		break;

	case DEnd:
		if (E0.dat_lnk.common) {
			if (E0.dat_zero == -1)
				die("elf: invalid common data definition");
			uint32_t idx = sym_ref_qbe(E0.dat_name);
			SymEnt *e = &E0.syms[idx];
			e->defined = 0;
			e->is_common = 1;
			e->is_export = 1;
			e->st_type = STT_OBJECT;
			e->offset = E0.dat_lnk.align > 0 ? (uint64_t)E0.dat_lnk.align : 1ULL;
			e->size = (uint64_t)E0.dat_zero;
		} else if (E0.dat_zero != -1) {
			int def_sec = E0.dat_lnk.thread ? SEC_TBSS : SEC_BSS;
			int sec_idx = dat_open_sec(def_sec);
			Sec *s = &E0.secs[sec_idx];
			if (s->is_nobits)
				s->nb_size += (uint64_t)E0.dat_zero;
			else
				buf_put_zeros(&s->buf, (size_t)E0.dat_zero);
			if (E0.dat_sym_idx != SYM_NONE)
				E0.syms[E0.dat_sym_idx].size = (uint64_t)E0.dat_zero;
		} else if (E0.dat_sym_idx != SYM_NONE && E0.dat_sec_idx >= 0) {
			E0.syms[E0.dat_sym_idx].size =
				sec_size(&E0.secs[E0.dat_sec_idx]) - E0.dat_start_off;
		}
		free(E0.dat_name); E0.dat_name = 0;
		free(E0.dat_sec_str); E0.dat_sec_str = 0;
		free(E0.dat_secf_str); E0.dat_secf_str = 0;
		break;

	case DZ:
		if (E0.dat_zero != -1) {
			E0.dat_zero += d->u.num;
		} else {
			buf_put_zeros(&E0.secs[E0.dat_sec_idx].buf, (size_t)d->u.num);
		}
		break;

	default:
		if (E0.dat_zero != -1) {
			int def_sec = E0.dat_lnk.thread ? SEC_TDATA : SEC_DATA;
			E0.dat_sec_idx = dat_open_sec(def_sec);
			if (E0.dat_zero > 0)
				buf_put_zeros(&E0.secs[E0.dat_sec_idx].buf, (size_t)E0.dat_zero);
			E0.dat_zero = -1;
		}
		if (d->isstr) {
			if (d->type != DB)
				err("strings only supported for 'b' currently");
			emit_ascii_str(&E0.secs[E0.dat_sec_idx].buf, d->u.str);
		} else if (d->isref) {
			uint32_t sym = sym_ref_qbe(d->u.ref.name);
			uint64_t off = (uint64_t)E0.secs[E0.dat_sec_idx].buf.len;
			if (d->type == DL) {
				sec_add_reloc(E0.dat_sec_idx, off, sym, R_X86_64_64, d->u.ref.off);
				buf_put_u64(&E0.secs[E0.dat_sec_idx].buf, 0);
			} else if (d->type == DW) {
				sec_add_reloc(E0.dat_sec_idx, off, sym, R_X86_64_32, d->u.ref.off);
				buf_put_u32(&E0.secs[E0.dat_sec_idx].buf, 0);
			} else {
				die("elf: unsupported ref data width %d", d->type);
			}
		} else {
			Buf *b = &E0.secs[E0.dat_sec_idx].buf;
			switch (d->type) {
			case DB: buf_put_u8(b, (uint8_t)d->u.num); break;
			case DH: buf_put_u16(b, (uint16_t)d->u.num); break;
			case DW: buf_put_u32(b, (uint32_t)d->u.num); break;
			case DL: buf_put_u64(b, (uint64_t)d->u.num); break;
			default: die("elf: unexpected dat type %d", d->type);
			}
		}
		break;
	}
}

/* ---- Stashed floating-point literal pool ---- */

static void
emit_stash_cb(int id, bits n, int size, void *ctx)
{
	(void)ctx;
	char name[64];
	snprintf(name, sizeof name, "\"%sfp%d\"", T.asloc, id);
	sec_align(SEC_RODATA, (uint64_t)size);
	uint64_t off = sec_size(&E0.secs[SEC_RODATA]);
	uint32_t sym = sym_define(name, SEC_RODATA, off, 0, STT_OBJECT);
	E0.syms[sym].size = (uint64_t)size;
	if (size == 16) {
		buf_put_u64(&E0.secs[SEC_RODATA].buf, (uint64_t)n);
		buf_put_u64(&E0.secs[SEC_RODATA].buf, 0);
	} else if (size == 8) {
		buf_put_u64(&E0.secs[SEC_RODATA].buf, (uint64_t)n);
	} else {
		buf_put_u32(&E0.secs[SEC_RODATA].buf, (uint32_t)n);
	}
}

/* ---- Public lifecycle ---- */

void
amd64_elf_begin(void)
{
	memset(&E0, 0, sizeof E0);
	add_sec(".text",   SHT_PROGBITS, SHF_ALLOC | SHF_EXECINSTR, 16, 0);
	add_sec(".rodata", SHT_PROGBITS, SHF_ALLOC,                  1, 0);
	add_sec(".data",   SHT_PROGBITS, SHF_ALLOC | SHF_WRITE,      1, 0);
	add_sec(".bss",    SHT_NOBITS,   SHF_ALLOC | SHF_WRITE,      1, 1);
	add_sec(".tdata",  SHT_PROGBITS, SHF_ALLOC | SHF_WRITE | SHF_TLS, 1, 0);
	add_sec(".tbss",   SHT_NOBITS,   SHF_ALLOC | SHF_WRITE | SHF_TLS, 1, 1);
	E0.cur_text_sec = SEC_TEXT;
}

static uint32_t
strtab_add(Buf *st, const char *s)
{
	uint32_t off = (uint32_t)st->len;
	buf_put(st, s, strlen(s) + 1);
	return off;
}

static int
is_pion_internal_sym(const char *n)
{
	return strncmp(n, "pion_pkg_", 9) == 0 ||
		strncmp(n, "pion_const_", 11) == 0 ||
		strncmp(n, "pion_init_consts_", 17) == 0 ||
		strncmp(n, "pion_fn_", 8) == 0 ||
		strncmp(n, "pion_drop_", 10) == 0 ||
		strncmp(n, "pion_wrap_", 10) == 0 ||
		strncmp(n, "pion_vtable_", 12) == 0 ||
		strncmp(n, "pion_eq_", 8) == 0 ||
		strncmp(n, "pion_freeze_", 12) == 0;
}

void
amd64_elf_finish(FILE *outf)
{
	iterstash(emit_stash_cb, 0);

	/*
	 * Assign ELF section indices:
	 *   0: NULL
	 *   1..: active content sections (always include .text)
	 *   then: .note.GNU-stack
	 *   then: .rela.<sec> for each active section with relocs
	 *   then: .symtab, .strtab, .shstrtab
	 */
	Buf shstrtab = { 0 };
	buf_put_u8(&shstrtab, 0);

	uint32_t shndx = 1;
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (sec_size(s) > 0 || s->has_sym || i == SEC_TEXT) {
			s->out_shndx = shndx++;
			s->sh_name_off = strtab_add(&shstrtab, s->name);
		} else {
			s->out_shndx = 0;
		}
	}

	uint32_t gnu_stack_shndx = shndx++;
	uint32_t gnu_stack_name = strtab_add(&shstrtab, ".note.GNU-stack");

	uint32_t n_rela_secs = 0;
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (s->out_shndx && s->nrelocs > 0) {
			char rname[256];
			snprintf(rname, sizeof rname, ".rela%s", s->name);
			s->rela_sh_name_off = strtab_add(&shstrtab, rname);
			shndx++;
			n_rela_secs++;
		}
	}

	uint32_t symtab_shndx = shndx++;
	uint32_t symtab_name = strtab_add(&shstrtab, ".symtab");
	uint32_t strtab_shndx = shndx++;
	uint32_t strtab_name = strtab_add(&shstrtab, ".strtab");
	uint32_t shstrtab_shndx = shndx++;
	uint32_t shstrtab_name = strtab_add(&shstrtab, ".shstrtab");
	uint32_t total_shnum = shndx;

	/* Sort symbols: STB_LOCAL first, then STB_GLOBAL (defined, common, undef) */
	uint32_t *order = emalloc((E0.nsyms ? E0.nsyms : 1) * sizeof *order);
	uint32_t *old_to_new = emalloc((E0.nsyms ? E0.nsyms : 1) * sizeof *old_to_new);
	uint32_t nlocal = 0;
	uint32_t pos = 0;

	/* Entry 0 in .symtab is STN_UNDEF; real symbols start at index 1 */
	for (size_t i = 0; i < E0.nsyms; i++) {
		if (E0.syms[i].defined && !E0.syms[i].is_export) {
			old_to_new[i] = 1u + pos;
			order[pos++] = (uint32_t)i;
			nlocal++;
		}
	}
	for (size_t i = 0; i < E0.nsyms; i++) {
		if (E0.syms[i].defined && E0.syms[i].is_export) {
			old_to_new[i] = 1u + pos;
			order[pos++] = (uint32_t)i;
		}
	}
	for (size_t i = 0; i < E0.nsyms; i++) {
		if (!E0.syms[i].defined) {
			old_to_new[i] = 1u + pos;
			order[pos++] = (uint32_t)i;
		}
	}

	uint32_t total_syms = 1u + pos;
	uint32_t first_global = 1u + nlocal;

	Buf strtab = { 0 };
	buf_put_u8(&strtab, 0);

	Elf64_Sym *esyms = calloc(total_syms, sizeof *esyms);
	if (!esyms)
		die("elf: out of memory");

	for (uint32_t ni = 0; ni < pos; ni++) {
		SymEnt *e = &E0.syms[order[ni]];
		Elf64_Sym *es = &esyms[1u + ni];
		es->st_name = strtab_add(&strtab, e->name);
		if (e->defined) {
			Sec *s = &E0.secs[e->sec_idx];
			uint8_t bind = e->is_export ? STB_GLOBAL : STB_LOCAL;
			es->st_info = ELF64_ST_INFO(bind, e->st_type);
			if (e->is_export && is_pion_internal_sym(e->name))
				es->st_other = 2; /* STV_HIDDEN */
			es->st_shndx = (uint16_t)s->out_shndx;
			es->st_value = e->offset;
			es->st_size = e->size;
		} else if (e->is_common) {
			es->st_info = ELF64_ST_INFO(STB_GLOBAL, e->st_type);
			es->st_shndx = SHN_COMMON;
			es->st_value = e->offset; /* alignment */
			es->st_size = e->size;
		} else {
			es->st_info = ELF64_ST_INFO(STB_GLOBAL, STT_NOTYPE);
			es->st_shndx = SHN_UNDEF;
			es->st_value = 0;
			es->st_size = 0;
		}
	}

	/* File layout */
	uint64_t file_pos = sizeof(Elf64_Ehdr);

	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx)
			continue;
		if (s->is_nobits) {
			s->fileoff = file_pos;
		} else {
			file_pos = align_up(file_pos, s->align);
			s->fileoff = file_pos;
			file_pos += s->buf.len;
		}
	}

	uint64_t gnu_stack_off = file_pos;

	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx || s->nrelocs == 0)
			continue;
		file_pos = align_up(file_pos, 8);
		s->rela_fileoff = file_pos;
		file_pos += s->nrelocs * sizeof(Elf64_Rela);
	}

	file_pos = align_up(file_pos, 8);
	uint64_t symtab_off = file_pos;
	file_pos += (uint64_t)total_syms * sizeof(Elf64_Sym);

	uint64_t strtab_off = file_pos;
	file_pos += strtab.len;

	uint64_t shstrtab_off = file_pos;
	file_pos += shstrtab.len;

	file_pos = align_up(file_pos, 8);
	uint64_t shoff = file_pos;
	uint64_t total_file_size = shoff + (uint64_t)total_shnum * sizeof(Elf64_Shdr);

	/* Assemble output image in memory */
	Buf out = { 0 };
	buf_reserve(&out, (size_t)total_file_size);

	Elf64_Ehdr ehdr;
	memset(&ehdr, 0, sizeof ehdr);
	ehdr.e_ident[0] = 0x7f;
	ehdr.e_ident[1] = 'E';
	ehdr.e_ident[2] = 'L';
	ehdr.e_ident[3] = 'F';
	ehdr.e_ident[4] = ELFCLASS64;
	ehdr.e_ident[5] = ELFDATA2LSB;
	ehdr.e_ident[6] = EV_CURRENT;
	ehdr.e_ident[7] = ELFOSABI_NONE;
	ehdr.e_type = ET_REL;
	ehdr.e_machine = EM_X86_64;
	ehdr.e_version = EV_CURRENT;
	ehdr.e_shoff = shoff;
	ehdr.e_ehsize = sizeof(Elf64_Ehdr);
	ehdr.e_shentsize = sizeof(Elf64_Shdr);
	ehdr.e_shnum = (uint16_t)total_shnum;
	ehdr.e_shstrndx = (uint16_t)shstrtab_shndx;
	buf_put(&out, &ehdr, sizeof ehdr);

	/* Write section contents */
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx || s->is_nobits)
			continue;
		if (out.len < s->fileoff)
			buf_put_zeros(&out, (size_t)(s->fileoff - out.len));
		buf_put(&out, s->buf.data, s->buf.len);
	}

	/* Write .rela.* sections */
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx || s->nrelocs == 0)
			continue;
		if (out.len < s->rela_fileoff)
			buf_put_zeros(&out, (size_t)(s->rela_fileoff - out.len));
		for (size_t r = 0; r < s->nrelocs; r++) {
			Reloc *rel = &s->relocs[r];
			Elf64_Rela er;
			er.r_offset = rel->offset;
			er.r_info = ELF64_R_INFO(old_to_new[rel->sym_idx], rel->type);
			er.r_addend = rel->addend;
			buf_put(&out, &er, sizeof er);
		}
	}

	/* Write .symtab, .strtab, .shstrtab */
	if (out.len < symtab_off)
		buf_put_zeros(&out, (size_t)(symtab_off - out.len));
	buf_put(&out, esyms, (size_t)total_syms * sizeof(Elf64_Sym));
	buf_put(&out, strtab.data, strtab.len);
	buf_put(&out, shstrtab.data, shstrtab.len);

	/* Write Section Header Table */
	if (out.len < shoff)
		buf_put_zeros(&out, (size_t)(shoff - out.len));

	/* [0] SHT_NULL */
	Elf64_Shdr sh;
	memset(&sh, 0, sizeof sh);
	buf_put(&out, &sh, sizeof sh);

	/* Active content sections */
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx)
			continue;
		memset(&sh, 0, sizeof sh);
		sh.sh_name = s->sh_name_off;
		sh.sh_type = s->type;
		sh.sh_flags = s->flags;
		sh.sh_offset = s->fileoff;
		sh.sh_size = sec_size(s);
		sh.sh_addralign = s->align;
		buf_put(&out, &sh, sizeof sh);
	}

	/* .note.GNU-stack */
	memset(&sh, 0, sizeof sh);
	sh.sh_name = gnu_stack_name;
	sh.sh_type = SHT_PROGBITS;
	sh.sh_flags = 0;
	sh.sh_offset = gnu_stack_off;
	sh.sh_size = 0;
	sh.sh_addralign = 1;
	buf_put(&out, &sh, sizeof sh);
	(void)gnu_stack_shndx;

	/* .rela.* sections */
	for (size_t i = 0; i < E0.nsecs; i++) {
		Sec *s = &E0.secs[i];
		if (!s->out_shndx || s->nrelocs == 0)
			continue;
		memset(&sh, 0, sizeof sh);
		sh.sh_name = s->rela_sh_name_off;
		sh.sh_type = SHT_RELA;
		sh.sh_flags = SHF_INFO_LINK;
		sh.sh_offset = s->rela_fileoff;
		sh.sh_size = (uint64_t)s->nrelocs * sizeof(Elf64_Rela);
		sh.sh_link = symtab_shndx;
		sh.sh_info = s->out_shndx;
		sh.sh_addralign = 8;
		sh.sh_entsize = sizeof(Elf64_Rela);
		buf_put(&out, &sh, sizeof sh);
	}
	(void)n_rela_secs;

	/* .symtab */
	memset(&sh, 0, sizeof sh);
	sh.sh_name = symtab_name;
	sh.sh_type = SHT_SYMTAB;
	sh.sh_offset = symtab_off;
	sh.sh_size = (uint64_t)total_syms * sizeof(Elf64_Sym);
	sh.sh_link = strtab_shndx;
	sh.sh_info = first_global;
	sh.sh_addralign = 8;
	sh.sh_entsize = sizeof(Elf64_Sym);
	buf_put(&out, &sh, sizeof sh);

	/* .strtab */
	memset(&sh, 0, sizeof sh);
	sh.sh_name = strtab_name;
	sh.sh_type = SHT_STRTAB;
	sh.sh_offset = strtab_off;
	sh.sh_size = strtab.len;
	sh.sh_addralign = 1;
	buf_put(&out, &sh, sizeof sh);

	/* .shstrtab */
	memset(&sh, 0, sizeof sh);
	sh.sh_name = shstrtab_name;
	sh.sh_type = SHT_STRTAB;
	sh.sh_offset = shstrtab_off;
	sh.sh_size = shstrtab.len;
	sh.sh_addralign = 1;
	buf_put(&out, &sh, sizeof sh);

	if (fwrite(out.data, 1, out.len, outf) != out.len)
		die("elf: failed to write object file");

	/* Cleanup */
	free(out.data);
	free(esyms);
	free(strtab.data);
	free(shstrtab.data);
	free(order);
	free(old_to_new);
	for (size_t i = 0; i < E0.nsecs; i++) {
		free(E0.secs[i].name);
		free(E0.secs[i].buf.data);
		free(E0.secs[i].relocs);
	}
	free(E0.secs);
	for (size_t i = 0; i < E0.nsyms; i++)
		free(E0.syms[i].name);
	free(E0.syms);
	free(E0.sym_ht);
	free(E0.dat_name);
	free(E0.dat_sec_str);
	free(E0.dat_secf_str);
	memset(&E0, 0, sizeof E0);
}
