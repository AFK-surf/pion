#include "all.h"

/*
 * Direct 64-bit ARM64 Mach-O relocatable object (.o) emitter for arm64_apple.
 * Self-contained Mach-O definitions (compiles cleanly on macOS and Linux).
 */

/* ---- Mach-O 64-bit constants & wire structures ---- */

#define MH_MAGIC_64            0xfeedfacfu
#define CPU_TYPE_ARM64         0x0100000cu
#define CPU_SUBTYPE_ARM64_ALL  0x00000000u
#define MH_OBJECT              0x00000001u
#define MH_SUBSECTIONS_VIA_SYMBOLS 0x00002000u

#define LC_SYMTAB              0x00000002u
#define LC_DYSYMTAB            0x0000000bu
#define LC_SEGMENT_64          0x00000019u
#define LC_BUILD_VERSION       0x00000032u

#define PLATFORM_MACOS         1u

#define S_REGULAR                  0x00000000u
#define S_ZEROFILL                 0x00000001u
#define S_4BYTE_LITERALS           0x00000003u
#define S_8BYTE_LITERALS           0x00000004u
#define S_16BYTE_LITERALS          0x0000000eu
#define S_THREAD_LOCAL_REGULAR     0x00000011u
#define S_THREAD_LOCAL_VARIABLES   0x00000013u
#define S_ATTR_PURE_INSTRUCTIONS   0x80000000u
#define S_ATTR_SOME_INSTRUCTIONS   0x00000400u

#define N_UNDF 0x00u
#define N_EXT  0x01u
#define N_SECT 0x0eu

#define ARM64_RELOC_UNSIGNED            0u
#define ARM64_RELOC_BRANCH26            2u
#define ARM64_RELOC_PAGE21              3u
#define ARM64_RELOC_PAGEOFF12           4u
#define ARM64_RELOC_GOT_LOAD_PAGE21     5u
#define ARM64_RELOC_GOT_LOAD_PAGEOFF12  6u
#define ARM64_RELOC_TLVP_LOAD_PAGE21    8u
#define ARM64_RELOC_TLVP_LOAD_PAGEOFF12 9u
#define ARM64_RELOC_ADDEND              10u

typedef struct {
	uint32_t magic;
	uint32_t cputype;
	uint32_t cpusubtype;
	uint32_t filetype;
	uint32_t ncmds;
	uint32_t sizeofcmds;
	uint32_t flags;
	uint32_t reserved;
} MachHeader64;

typedef struct {
	uint32_t cmd;
	uint32_t cmdsize;
	char segname[16];
	uint64_t vmaddr;
	uint64_t vmsize;
	uint64_t fileoff;
	uint64_t filesize;
	uint32_t maxprot;
	uint32_t initprot;
	uint32_t nsects;
	uint32_t flags;
} SegmentCmd64;

typedef struct {
	char sectname[16];
	char segname[16];
	uint64_t addr;
	uint64_t size;
	uint32_t offset;
	uint32_t align;
	uint32_t reloff;
	uint32_t nreloc;
	uint32_t flags;
	uint32_t reserved1;
	uint32_t reserved2;
	uint32_t reserved3;
} Section64;

typedef struct {
	uint32_t cmd;
	uint32_t cmdsize;
	uint32_t platform;
	uint32_t minos;
	uint32_t sdk;
	uint32_t ntools;
} BuildVerCmd;

typedef struct {
	uint32_t cmd;
	uint32_t cmdsize;
	uint32_t symoff;
	uint32_t nsyms;
	uint32_t stroff;
	uint32_t strsize;
} SymtabCmd;

typedef struct {
	uint32_t cmd;
	uint32_t cmdsize;
	uint32_t ilocalsym;
	uint32_t nlocalsym;
	uint32_t iextdefsym;
	uint32_t nextdefsym;
	uint32_t iundefsym;
	uint32_t nundefsym;
	uint32_t tocoff;
	uint32_t ntoc;
	uint32_t modtaboff;
	uint32_t nmodtab;
	uint32_t extrefsymoff;
	uint32_t nextrefsyms;
	uint32_t indirectsymoff;
	uint32_t nindirectsyms;
	uint32_t extreloff;
	uint32_t nextrel;
	uint32_t locreloff;
	uint32_t nlocrel;
} DysymtabCmd;

typedef struct {
	uint32_t n_strx;
	uint8_t n_type;
	uint8_t n_sect;
	uint16_t n_desc;
	uint64_t n_value;
} Nlist64;

typedef struct {
	int32_t r_address;
	uint32_t r_info;
} RelocInfo;

static inline uint32_t
pack_reloc_info(uint32_t symnum, uint32_t pcrel, uint32_t len, uint32_t ext, uint32_t type)
{
	return (symnum & 0x00ffffffu)
		| ((pcrel & 1u) << 24)
		| ((len & 3u) << 25)
		| ((ext & 1u) << 27)
		| ((type & 0xfu) << 28);
}

/* ---- Dynamic buffers, sections, symbols ---- */

typedef struct {
	uint8_t *data;
	size_t len;
	size_t cap;
} Buf;

typedef struct {
	int32_t offset;
	uint32_t sym_idx;   /* symbol table index (or 24-bit signed addend if type==ADDEND) */
	uint8_t pcrel;
	uint8_t length;
	uint8_t is_extern;
	uint8_t type;
} Reloc;

typedef struct {
	char segname[16];
	char sectname[16];
	uint32_t flags;
	uint32_t align_log2;
	int is_zerofill;
	Buf buf;
	uint64_t zf_size;
	Reloc *relocs;
	size_t nrelocs;
	size_t cap_relocs;
	/* Layout fields filled in finish() */
	int out_sect_num; /* 1-based Mach-O section index, 0 if skipped */
	uint64_t vmaddr;
	uint32_t fileoff;
	uint32_t reloff;
} Sec;

typedef struct {
	char *name;
	int defined;
	int is_export;
	int is_common;
	int sec_idx;
	uint64_t offset;       /* offset in section, or size if common */
	uint32_t common_align; /* log2 alignment if common */
} SymEnt;

typedef struct {
	uint32_t pc_off;
	uint32_t target_bid;
	uint32_t base;
	uint8_t is_imm19;
} BrFixup;

typedef struct {
	uint32_t entry_off;
	uint32_t tbl_base_off;
	uint32_t target_bid;
} JtblFixup;

enum {
	SEC_TEXT = 0,
	SEC_CONST,
	SEC_LIT4,
	SEC_LIT8,
	SEC_LIT16,
	SEC_DATA,
	SEC_BSS,
	SEC_TLVVARS,
	SEC_TLVDATA,
	SEC_BUILTIN_COUNT
};

typedef struct {
	uint32_t macos_ver;
	Sec *secs;
	size_t nsecs;
	size_t cap_secs;

	SymEnt *syms;
	size_t nsyms;
	size_t cap_syms;

	/* Open-addressed hash table for symbol lookup: slot stores sym_idx + 1 (0 = empty) */
	uint32_t *sym_ht;
	size_t sym_ht_cap;

	/* Current data definition state */
	char *dat_name;
	Lnk dat_lnk;
	char *dat_sec_str;
	char *dat_secf_str;
	int dat_sec_idx;
	int64_t dat_zero;
} MachO;

static MachO M;

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
		die("out of memory");
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

static void
buf_put_u8(Buf *b, uint8_t v)
{
	buf_reserve(b, 1);
	b->data[b->len++] = v;
}

static void
buf_put_u16(Buf *b, uint16_t v)
{
	uint8_t t[2];
	t[0] = (uint8_t)(v & 0xffu);
	t[1] = (uint8_t)((v >> 8) & 0xffu);
	buf_put(b, t, 2);
}

static void
buf_put_u32(Buf *b, uint32_t v)
{
	uint8_t t[4];
	t[0] = (uint8_t)(v & 0xffu);
	t[1] = (uint8_t)((v >> 8) & 0xffu);
	t[2] = (uint8_t)((v >> 16) & 0xffu);
	t[3] = (uint8_t)((v >> 24) & 0xffu);
	buf_put(b, t, 4);
}

static void
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

static uint32_t
log2_align(uint32_t a)
{
	uint32_t lg = 0;
	if (a <= 1)
		return 0;
	while ((1u << lg) < a && lg < 16)
		lg++;
	return lg;
}

static uint64_t
align_up(uint64_t v, uint64_t a)
{
	if (a <= 1)
		return v;
	return (v + a - 1) & ~(a - 1);
}

static int
add_sec(const char *seg, const char *sect, uint32_t flags, uint32_t align_log2, int is_zf)
{
	if (M.nsecs == M.cap_secs) {
		M.cap_secs = M.cap_secs ? M.cap_secs * 2 : 16;
		M.secs = realloc(M.secs, M.cap_secs * sizeof *M.secs);
		if (!M.secs)
			die("out of memory");
	}
	Sec *s = &M.secs[M.nsecs];
	memset(s, 0, sizeof *s);
	strncpy(s->segname, seg, 16);
	strncpy(s->sectname, sect, 16);
	s->flags = flags;
	s->align_log2 = align_log2;
	s->is_zerofill = is_zf;
	return (int)(M.nsecs++);
}

static uint64_t
sec_size(const Sec *s)
{
	return s->is_zerofill ? s->zf_size : (uint64_t)s->buf.len;
}

static void
sec_align(int sec_idx, uint32_t align_bytes)
{
	Sec *s = &M.secs[sec_idx];
	uint32_t lg = log2_align(align_bytes);
	if (lg > s->align_log2)
		s->align_log2 = lg;
	uint64_t a = 1ULL << lg;
	uint64_t cur = sec_size(s);
	uint64_t nxt = align_up(cur, a);
	if (nxt > cur) {
		if (s->is_zerofill)
			s->zf_size = nxt;
		else
			buf_put_zeros(&s->buf, (size_t)(nxt - cur));
	}
}

static void
sec_add_reloc(int sec_idx, int32_t offset, uint32_t sym_idx, uint8_t pcrel, uint8_t len, uint8_t is_ext, uint8_t type)
{
	Sec *s = &M.secs[sec_idx];
	if (s->nrelocs == s->cap_relocs) {
		s->cap_relocs = s->cap_relocs ? s->cap_relocs * 2 : 64;
		s->relocs = realloc(s->relocs, s->cap_relocs * sizeof *s->relocs);
		if (!s->relocs)
			die("out of memory");
	}
	Reloc *r = &s->relocs[s->nrelocs++];
	r->offset = offset;
	r->sym_idx = sym_idx;
	r->pcrel = pcrel;
	r->length = len;
	r->is_extern = is_ext;
	r->type = type;
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
		die("out of memory");
	size_t mask = ncap - 1;
	for (size_t i = 0; i < M.nsyms; i++) {
		size_t slot = fnv1a(M.syms[i].name) & mask;
		while (nt[slot] != 0)
			slot = (slot + 1) & mask;
		nt[slot] = (uint32_t)(i + 1);
	}
	free(M.sym_ht);
	M.sym_ht = nt;
	M.sym_ht_cap = ncap;
}

static uint32_t
sym_intern(const char *name)
{
	if (M.sym_ht_cap == 0)
		sym_ht_rehash(256);
	else if ((M.nsyms + 1) * 2 > M.sym_ht_cap)
		sym_ht_rehash(M.sym_ht_cap * 2);

	size_t mask = M.sym_ht_cap - 1;
	size_t slot = fnv1a(name) & mask;
	while (M.sym_ht[slot] != 0) {
		uint32_t idx = M.sym_ht[slot] - 1;
		if (strcmp(M.syms[idx].name, name) == 0)
			return idx;
		slot = (slot + 1) & mask;
	}

	if (M.nsyms == M.cap_syms) {
		M.cap_syms = M.cap_syms ? M.cap_syms * 2 : 128;
		M.syms = realloc(M.syms, M.cap_syms * sizeof *M.syms);
		if (!M.syms)
			die("out of memory");
	}
	uint32_t idx = (uint32_t)M.nsyms++;
	SymEnt *e = &M.syms[idx];
	memset(e, 0, sizeof *e);
	size_t nlen = strlen(name) + 1;
	e->name = emalloc(nlen);
	memcpy(e->name, name, nlen);
	e->sec_idx = -1;
	M.sym_ht[slot] = idx + 1;
	return idx;
}

static char *
format_macho_sym(const char *raw, const char *sfx, char *buf, size_t bufsz)
{
	size_t len = strlen(raw);
	size_t slen = strlen(sfx);
	if (len >= 2 && raw[0] == '"' && raw[len - 1] == '"') {
		size_t inner = len - 2;
		if (inner + slen + 1 > bufsz)
			die("symbol name too long: %s", raw);
		memcpy(buf, raw + 1, inner);
		memcpy(buf + inner, sfx, slen);
		buf[inner + slen] = '\0';
	} else {
		size_t plen = strlen(T.assym);
		if (plen + len + slen + 1 > bufsz)
			die("symbol name too long: %s", raw);
		memcpy(buf, T.assym, plen);
		memcpy(buf + plen, raw, len);
		memcpy(buf + plen + len, sfx, slen);
		buf[plen + len + slen] = '\0';
	}
	return buf;
}

static uint32_t
sym_ref_qbe(const char *raw, const char *sfx)
{
	char buf[1024];
	return sym_intern(format_macho_sym(raw, sfx, buf, sizeof buf));
}

static uint32_t
sym_define(const char *raw, const char *sfx, int sec_idx, uint64_t offset, int is_export)
{
	uint32_t idx = sym_ref_qbe(raw, sfx);
	SymEnt *e = &M.syms[idx];
	e->defined = 1;
	e->is_common = 0;
	e->sec_idx = sec_idx;
	e->offset = offset;
	if (is_export)
		e->is_export = 1;
	return idx;
}

/* ---- ARM64 instruction encoding ---- */

enum {
	V31 = 0x1fffffff,
};

static inline uint32_t
greg(int r)
{
	if (r == SP)
		return 31u;
	if (R0 <= r && r <= LR)
		return (uint32_t)(r - R0);
	die("macho: invalid gpr %d", r);
}

static inline uint32_t
freg(int r)
{
	if (r == V31)
		return 31u;
	if (V0 <= r && r <= V30)
		return (uint32_t)(r - V0);
	die("macho: invalid fpr %d", r);
}

static inline void
emit_u32(uint32_t insn)
{
	buf_put_u32(&M.secs[SEC_TEXT].buf, insn);
}

static inline uint32_t
text_pos(void)
{
	return (uint32_t)M.secs[SEC_TEXT].buf.len;
}

/* ARM64 condition codes */
enum {
	CC_EQ = 0x0, CC_NE = 0x1,
	CC_CS = 0x2, CC_CC = 0x3,
	CC_MI = 0x4, CC_PL = 0x5,
	CC_VS = 0x6, CC_VC = 0x7,
	CC_HI = 0x8, CC_LS = 0x9,
	CC_GE = 0xa, CC_LT = 0xb,
	CC_GT = 0xc, CC_LE = 0xd,
};

static const uint8_t cmp_cc[NCmp][2] = {
	[Cieq]       = { CC_EQ, CC_NE },
	[Cine]       = { CC_NE, CC_EQ },
	[Cisge]      = { CC_GE, CC_LT },
	[Cisgt]      = { CC_GT, CC_LE },
	[Cisle]      = { CC_LE, CC_GT },
	[Cislt]      = { CC_LT, CC_GE },
	[Ciuge]      = { CC_CS, CC_CC },
	[Ciugt]      = { CC_HI, CC_LS },
	[Ciule]      = { CC_LS, CC_HI },
	[Ciult]      = { CC_CC, CC_CS },
	[NCmpI+Cfeq] = { CC_EQ, CC_NE },
	[NCmpI+Cfge] = { CC_GE, CC_LT },
	[NCmpI+Cfgt] = { CC_GT, CC_LE },
	[NCmpI+Cfle] = { CC_LS, CC_HI },
	[NCmpI+Cflt] = { CC_MI, CC_PL },
	[NCmpI+Cfne] = { CC_NE, CC_EQ },
	[NCmpI+Cfo]  = { CC_VC, CC_VS },
	[NCmpI+Cfuo] = { CC_VS, CC_VC },
};

static int
encode_logimm(uint64_t v, int is64, uint32_t *out_n, uint32_t *out_immr, uint32_t *out_imms)
{
	uint64_t val = is64 ? v : (v & 0xffffffffULL);
	int max_esize = is64 ? 64 : 32;
	if (val == 0 || (is64 ? val == ~0ULL : val == 0xffffffffULL))
		return 0;

	int esize = max_esize;
	for (int s = 2; s < max_esize; s <<= 1) {
		uint64_t mask = (1ULL << s) - 1;
		uint64_t pat = val & mask;
		uint64_t rep = 0;
		for (int pos = 0; pos < max_esize; pos += s)
			rep |= pat << pos;
		if (rep == val) {
			esize = s;
			break;
		}
	}

	uint64_t emask = (esize == 64) ? ~0ULL : ((1ULL << esize) - 1);
	uint64_t elem = val & emask;
	int rot = 0;
	while (rot < esize) {
		if ((elem & 1ULL) && !(elem & (1ULL << (esize - 1))))
			break;
		elem = ((elem >> 1) | ((elem & 1ULL) << (esize - 1))) & emask;
		rot++;
	}

	int ones = 0;
	uint64_t tmp = elem;
	while (tmp & 1ULL) {
		ones++;
		tmp >>= 1;
	}
	if (tmp != 0 || ones == 0 || ones == esize)
		return 0;

	uint32_t immr = (uint32_t)((esize - rot) % esize);
	uint32_t N = (esize == 64) ? 1u : 0u;
	uint32_t imms = (esize == 64)
		? (uint32_t)(ones - 1)
		: (uint32_t)(((~(uint32_t)(esize * 2 - 1)) & 0x3fu) | (uint32_t)(ones - 1));

	*out_n = N;
	*out_immr = immr;
	*out_imms = imms;
	return 1;
}

static uint32_t
encode_fp8(Con *c, int k)
{
	uint32_t sign, exp, frac, bbit;
	if (k == Kd) {
		uint64_t b = (uint64_t)c->bits.i;
		sign = (uint32_t)((b >> 63) & 1u);
		exp = (uint32_t)((b >> 52) & 0x7ffu);
		frac = (uint32_t)((b >> 48) & 0xfu);
		bbit = ((exp >> 10) & 1u) ^ 1u;
	} else {
		uint32_t b = (uint32_t)c->bits.i;
		sign = (b >> 31) & 1u;
		exp = (b >> 23) & 0xffu;
		frac = (b >> 19) & 0xfu;
		bbit = ((exp >> 7) & 1u) ^ 1u;
	}
	return (sign << 7) | (bbit << 6) | ((exp & 3u) << 4) | frac;
}

/* Instruction helpers */
static void enc_add_imm(int is64, uint32_t rd, uint32_t rn, uint64_t imm)
{
	uint32_t sf = is64 ? 1u : 0u;
	uint32_t sh = 0, imm12;
	if (imm & 0xfff000ULL) {
		assert(!(imm & ~0xfff000ULL));
		sh = 1;
		imm12 = (uint32_t)(imm >> 12);
	} else {
		assert(!(imm & ~0xfffULL));
		imm12 = (uint32_t)imm;
	}
	emit_u32(0x11000000u | (sf << 31) | (sh << 22) | (imm12 << 10) | (rn << 5) | rd);
}

static void enc_sub_imm(int is64, uint32_t rd, uint32_t rn, uint64_t imm)
{
	uint32_t sf = is64 ? 1u : 0u;
	uint32_t sh = 0, imm12;
	if (imm & 0xfff000ULL) {
		assert(!(imm & ~0xfff000ULL));
		sh = 1;
		imm12 = (uint32_t)(imm >> 12);
	} else {
		assert(!(imm & ~0xfffULL));
		imm12 = (uint32_t)imm;
	}
	emit_u32(0x51000000u | (sf << 31) | (sh << 22) | (imm12 << 10) | (rn << 5) | rd);
}

static void enc_add_reg(int is64, int rd_r, int rn_r, int rm_r)
{
	uint32_t sf = is64 ? 1u : 0u;
	uint32_t rd = greg(rd_r), rn = greg(rn_r), rm = greg(rm_r);
	if (rd_r == SP || rn_r == SP) {
		/* ADD (extended register) UXTX #0 */
		emit_u32(0x0b206000u | (sf << 31) | (rm << 16) | (rn << 5) | rd);
	} else {
		emit_u32(0x0b000000u | (sf << 31) | (rm << 16) | (rn << 5) | rd);
	}
}

static void enc_sub_reg(int is64, int rd_r, int rn_r, int rm_r)
{
	uint32_t sf = is64 ? 1u : 0u;
	uint32_t rd = greg(rd_r), rn = greg(rn_r), rm = greg(rm_r);
	if (rd_r == SP || rn_r == SP) {
		/* SUB (extended register) UXTX #0 */
		emit_u32(0x4b206000u | (sf << 31) | (rm << 16) | (rn << 5) | rd);
	} else {
		emit_u32(0x4b000000u | (sf << 31) | (rm << 16) | (rn << 5) | rd);
	}
}

static void enc_mov_reg(int is64, int rd_r, int rn_r)
{
	uint32_t rd = greg(rd_r), rn = greg(rn_r);
	if (rd_r == SP || rn_r == SP) {
		assert(is64);
		emit_u32(0x91000000u | (rn << 5) | rd);
	} else {
		uint32_t sf = is64 ? 1u : 0u;
		emit_u32(0x2a0003e0u | (sf << 31) | (rn << 16) | rd);
	}
}

static void enc_movz(int is64, uint32_t rd, uint16_t imm16, uint32_t hw)
{
	uint32_t sf = is64 ? 1u : 0u;
	emit_u32(0x52800000u | (sf << 31) | (hw << 21) | ((uint32_t)imm16 << 5) | rd);
}

static void enc_movn(int is64, uint32_t rd, uint16_t imm16, uint32_t hw)
{
	uint32_t sf = is64 ? 1u : 0u;
	emit_u32(0x12800000u | (sf << 31) | (hw << 21) | ((uint32_t)imm16 << 5) | rd);
}

static void enc_movk(int is64, uint32_t rd, uint16_t imm16, uint32_t hw)
{
	uint32_t sf = is64 ? 1u : 0u;
	emit_u32(0x72800000u | (sf << 31) | (hw << 21) | ((uint32_t)imm16 << 5) | rd);
}

static void enc_stp_pre(uint32_t rt, uint32_t rt2, uint32_t rn, int64_t off)
{
	assert((off % 8) == 0 && off >= -512 && off <= 504);
	uint32_t imm7 = (uint32_t)((off / 8) & 0x7f);
	emit_u32(0xa9800000u | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt);
}

static void enc_ldp_post(uint32_t rt, uint32_t rt2, uint32_t rn, int64_t off)
{
	assert((off % 8) == 0 && off >= -512 && off <= 504);
	uint32_t imm7 = (uint32_t)((off / 8) & 0x7f);
	emit_u32(0xa8c00000u | (imm7 << 15) | (rt2 << 10) | (rn << 5) | rt);
}

/* ---- Function emission state ---- */

typedef struct {
	Fn *fn;
	uint64_t frame;
	uint padding;
	BrFixup *fixups;
	size_t nfixups;
	size_t cap_fixups;
	JtblFixup *jtfixups;
	size_t njtfixups;
	size_t cap_jtfixups;
} ME;

static void
me_add_jtfixup(ME *e, uint32_t entry_off, uint32_t tbl_base_off, uint32_t target_bid)
{
	if (e->njtfixups == e->cap_jtfixups) {
		e->cap_jtfixups = e->cap_jtfixups ? e->cap_jtfixups * 2 : 64;
		e->jtfixups = realloc(e->jtfixups, e->cap_jtfixups * sizeof *e->jtfixups);
		if (!e->jtfixups)
			die("out of memory");
	}
	JtblFixup *f = &e->jtfixups[e->njtfixups++];
	f->entry_off = entry_off;
	f->tbl_base_off = tbl_base_off;
	f->target_bid = target_bid;
}

static void
me_add_fixup(ME *e, uint32_t pc_off, uint32_t target_bid, uint32_t base, uint8_t is_imm19)
{
	if (e->nfixups == e->cap_fixups) {
		e->cap_fixups = e->cap_fixups ? e->cap_fixups * 2 : 64;
		e->fixups = realloc(e->fixups, e->cap_fixups * sizeof *e->fixups);
		if (!e->fixups)
			die("out of memory");
	}
	BrFixup *f = &e->fixups[e->nfixups++];
	f->pc_off = pc_off;
	f->target_bid = target_bid;
	f->base = base;
	f->is_imm19 = is_imm19;
}

static uint64_t
me_slot(Ref r, ME *e)
{
	int s = rsval(r);
	if (s == -1)
		return 16 + e->frame;
	if (s < 0)
		return 16 + e->frame - (uint64_t)(s + 2);
	return 16 + e->padding + 4 * (uint64_t)s;
}

static void
me_framelayout(ME *e)
{
	int *r;
	uint o;
	uint64_t f;

	for (o = 0, r = arm64_rclob; *r >= 0; r++)
		o += 1 & (e->fn->reg >> *r);
	f = e->fn->slot;
	f = (f + 3) & -4;
	o += o & 1;
	e->padding = (uint)(4 * (f - e->fn->slot));
	e->frame = 4 * f + 8 * o;
}

static void
me_loadaddr(Con *c, int rd_r)
{
	uint32_t rd = greg(rd_r);
	const char *l = str(c->sym.id);
	uint32_t sym = sym_ref_qbe(l, "");
	int64_t off = c->bits.i;
	uint32_t pc;

	if (off != 0) {
		if (off < -(1LL << 23) || off >= (1LL << 23))
			die("macho: symbol addend out of 24-bit range: %" PRIi64, off);
	}

	switch (c->sym.type) {
	default:
		die("macho: unreachable sym type");
	case SGlo:
		pc = text_pos();
		emit_u32(0x90000000u | rd); /* adrp Xd, sym@page */
		if (off != 0)
			sec_add_reloc(SEC_TEXT, (int32_t)pc, (uint32_t)off & 0x00ffffffu, 0, 2, 0, ARM64_RELOC_ADDEND);
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 1, 2, 1, ARM64_RELOC_PAGE21);

		pc = text_pos();
		emit_u32(0x91000000u | (rd << 5) | rd); /* add Xd, Xd, sym@pageoff */
		if (off != 0)
			sec_add_reloc(SEC_TEXT, (int32_t)pc, (uint32_t)off & 0x00ffffffu, 0, 2, 0, ARM64_RELOC_ADDEND);
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 0, 2, 1, ARM64_RELOC_PAGEOFF12);
		break;
	case SExtThr:
	case SThr:
		pc = text_pos();
		emit_u32(0x90000000u | rd); /* adrp Xd, sym@tlvppage */
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 1, 2, 1, ARM64_RELOC_TLVP_LOAD_PAGE21);

		pc = text_pos();
		emit_u32(0xf9400000u | (rd << 5) | rd); /* ldr Xd, [Xd, sym@tlvppageoff] */
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 0, 2, 1, ARM64_RELOC_TLVP_LOAD_PAGEOFF12);
		break;
	case SExt:
		pc = text_pos();
		emit_u32(0x90000000u | rd); /* adrp Xd, sym@gotpage */
		if (off != 0)
			sec_add_reloc(SEC_TEXT, (int32_t)pc, (uint32_t)off & 0x00ffffffu, 0, 2, 0, ARM64_RELOC_ADDEND);
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 1, 2, 1, ARM64_RELOC_GOT_LOAD_PAGE21);

		pc = text_pos();
		emit_u32(0xf9400000u | (rd << 5) | rd); /* ldr Xd, [Xd, sym@gotpageoff] */
		if (off != 0)
			sec_add_reloc(SEC_TEXT, (int32_t)pc, (uint32_t)off & 0x00ffffffu, 0, 2, 0, ARM64_RELOC_ADDEND);
		sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 0, 2, 1, ARM64_RELOC_GOT_LOAD_PAGEOFF12);
		break;
	}
}

static void
me_loadcon(Con *c, int r, int k)
{
	int64_t n = c->bits.i;
	int w = KWIDE(k);

	if (c->type == CAddr) {
		me_loadaddr(c, r);
		return;
	}
	assert(c->type == CBits);
	if (KBASE(k) == 1) {
		uint32_t rd = freg(r);
		assert(arm64_fpimm(c, k));
		if (k == Kd) {
			if (n == 0) {
				emit_u32(0x9e6703e0u | rd); /* fmov Dd, xzr */
				return;
			}
			uint32_t imm8 = encode_fp8(c, Kd);
			emit_u32(0x1e601000u | (imm8 << 13) | rd);
		} else {
			if ((uint32_t)n == 0) {
				emit_u32(0x1e2703e0u | rd); /* fmov Sd, wzr */
				return;
			}
			uint32_t imm8 = encode_fp8(c, Ks);
			emit_u32(0x1e201000u | (imm8 << 13) | rd);
		}
		return;
	}

	uint32_t rd = greg(r);
	if (!w)
		n = (int32_t)n;
	if (n >= 0 && n <= 0xffff) {
		enc_movz(w, rd, (uint16_t)n, 0);
	} else if ((n | 0xffff) == -1) {
		enc_movn(w, rd, (uint16_t)(~n & 0xffff), 0);
	} else if (arm64_logimm((uint64_t)n, k)) {
		uint32_t N, immr, imms;
		int ok = encode_logimm((uint64_t)n, w, &N, &immr, &imms);
		assert(ok);
		uint32_t sf = w ? 1u : 0u;
		/* orr rd, xzr/wzr, #imm */
		emit_u32(0x320003e0u | (sf << 31) | (N << 22) | (immr << 16) | (imms << 10) | rd);
	} else {
		enc_movz(w, rd, (uint16_t)(n & 0xffff), 0);
		uint64_t u = w ? (uint64_t)n : (uint64_t)(uint32_t)n;
		int64_t sn = n;
		for (int sh = 16; (sn >>= 16) != 0; sh += 16) {
			if ((!w && sh == 32) || sh == 64)
				break;
			enc_movk(w, rd, (uint16_t)((u >> sh) & 0xffffu), (uint32_t)(sh / 16));
		}
	}
}

static void me_emitins(Ins *i, ME *e);

static int
me_fixarg(Ref *pr, int sz, int t, ME *e)
{
	Ref r = *pr;
	if (rtype(r) == RSlot) {
		uint64_t s = me_slot(r, e);
		if (s > (uint64_t)sz * 4095u) {
			if (t < 0)
				return 1;
			Ins i = { .op = Oaddr, .cls = Kl, .to = TMP(t), .arg = { r, R } };
			me_emitins(&i, e);
			*pr = TMP(t);
		}
	}
	return 0;
}

static void
me_emit_mem(uint32_t imm_base_op, uint32_t reg_base_op, uint32_t rt, int sz, Ref mref, ME *e)
{
	switch (rtype(mref)) {
	default:
		die("macho: unhandled mem ref");
	case RTmp: {
		uint32_t rn = greg(mref.val);
		emit_u32(imm_base_op | (rn << 5) | rt);
		break;
	}
	case RSlot: {
		uint64_t off = me_slot(mref, e);
		assert((off % (uint64_t)sz) == 0 && off / (uint64_t)sz <= 4095u);
		uint32_t imm12 = (uint32_t)(off / (uint64_t)sz);
		emit_u32(imm_base_op | (imm12 << 10) | (29u << 5) | rt);
		break;
	}
	case RMem: {
		Mem *m = &e->fn->mem[mref.val];
		uint32_t rn = greg(m->base.val);
		if (req(m->index, R)) {
			int64_t off = m->offset.bits.i;
			assert(off >= 0 && (off % sz) == 0 && (off / sz) <= 4095);
			uint32_t imm12 = (uint32_t)(off / sz);
			emit_u32(imm_base_op | (imm12 << 10) | (rn << 5) | rt);
		} else {
			int sxtw = m->scale < 0;
			int sc = sxtw ? -m->scale : m->scale;
			uint32_t rm = greg(m->index.val);
			uint32_t S = (sc > 1) ? 1u : 0u;
			uint32_t op = reg_base_op;
			if (sxtw)
				op = (op & ~(7u << 13)) | (6u << 13);
			emit_u32(op | (rm << 16) | (S << 12) | (rn << 5) | rt);
		}
		break;
	}
	}
}

static void
me_emitins(Ins *i, ME *e)
{
	int k = i->cls;
	int is64 = KWIDE(k);
	uint32_t sf = is64 ? 1u : 0u;
	uint32_t ftype = (k == Kd) ? 1u : 0u;

	if (isload(i->op))
		me_fixarg(&i->arg[0], loadsz(i), IP1, e);
	if (isstore(i->op)) {
		if (me_fixarg(&i->arg[1], storesz(i), -1, e)) {
			if (req(i->arg[0], TMP(IP1))) {
				if (i->op == Ostorel) {
					emit_u32(0x9e670000u | (17u << 5) | 31u); /* fmov d31, x17 */
					i->op = Ostored;
				} else {
					emit_u32(0x1e270000u | (17u << 5) | 31u); /* fmov s31, w17 */
					i->op = Ostores;
				}
				i->arg[0] = TMP(V31);
			}
			me_fixarg(&i->arg[1], storesz(i), IP1, e);
		}
	}

	switch (i->op) {
	default:
		if (i->op >= Oflag && i->op <= Oflag1) {
			int c = (int)i->op - Oflag;
			uint32_t rd = greg(i->to.val);
			uint32_t cc = cmp_cc[c][0];
			/* cset rd, cc == csinc rd, xzr, xzr, inv(cc) */
			emit_u32(0x1a9f07e0u | (sf << 31) | (((cc ^ 1u) & 0xfu) << 12) | rd);
			break;
		}
		if (i->op >= Oxsel && i->op <= Oxsel1) {
			int c = (int)i->op - Oxsel;
			uint32_t rd = greg(i->to.val);
			uint32_t rn = greg(i->arg[0].val);
			uint32_t rm = greg(i->arg[1].val);
			uint32_t cc = cmp_cc[c][0];
			/* csel rd, rn, rm, cc */
			emit_u32(0x1a800000u | (sf << 31) | (rm << 16) | (cc << 12) | (rn << 5) | rd);
			break;
		}
		die("macho: unhandled op %s(%c)", optab[i->op].name, "wlsd"[k]);

	case Onop:
	case Odbgloc:
		break;

	case Oadd:
		if (KBASE(k) == 1) {
			emit_u32(0x1e202800u | (ftype << 22) | (freg(i->arg[1].val) << 16)
				| (freg(i->arg[0].val) << 5) | freg(i->to.val));
		} else if (rtype(i->arg[1]) == RCon) {
			Con *pc = &e->fn->con[i->arg[1].val];
			enc_add_imm(is64, greg(i->to.val), greg(i->arg[0].val), (uint64_t)pc->bits.i);
		} else {
			enc_add_reg(is64, i->to.val, i->arg[0].val, i->arg[1].val);
		}
		break;

	case Osub:
		if (KBASE(k) == 1) {
			emit_u32(0x1e203800u | (ftype << 22) | (freg(i->arg[1].val) << 16)
				| (freg(i->arg[0].val) << 5) | freg(i->to.val));
		} else if (rtype(i->arg[1]) == RCon) {
			Con *pc = &e->fn->con[i->arg[1].val];
			enc_sub_imm(is64, greg(i->to.val), greg(i->arg[0].val), (uint64_t)pc->bits.i);
		} else {
			enc_sub_reg(is64, i->to.val, i->arg[0].val, i->arg[1].val);
		}
		break;

	case Oneg:
		if (KBASE(k) == 1) {
			emit_u32(0x1e214000u | (ftype << 22) | (freg(i->arg[0].val) << 5) | freg(i->to.val));
		} else {
			/* neg rd, rm == sub rd, xzr/wzr, rm */
			emit_u32(0x4b0003e0u | (sf << 31) | (greg(i->arg[0].val) << 16) | greg(i->to.val));
		}
		break;

	case Osqrt:
		emit_u32(0x1e21c000u | (ftype << 22) | (freg(i->arg[0].val) << 5) | freg(i->to.val));
		break;

	case Oand:
	case Oor:
	case Oxor: {
		uint32_t rd = greg(i->to.val);
		uint32_t rn = greg(i->arg[0].val);
		if (rtype(i->arg[1]) == RCon) {
			Con *pc = &e->fn->con[i->arg[1].val];
			uint64_t n = (uint64_t)pc->bits.i;
			if (!is64)
				n = (uint32_t)n;
			uint32_t N, immr, imms;
			int ok = encode_logimm(n, is64, &N, &immr, &imms);
			assert(ok);
			uint32_t base = (i->op == Oand) ? 0x12000000u
				: (i->op == Oor) ? 0x32000000u : 0x52000000u;
			emit_u32(base | (sf << 31) | (N << 22) | (immr << 16) | (imms << 10) | (rn << 5) | rd);
		} else {
			uint32_t rm = greg(i->arg[1].val);
			uint32_t base = (i->op == Oand) ? 0x0a000000u
				: (i->op == Oor) ? 0x2a000000u : 0x4a000000u;
			emit_u32(base | (sf << 31) | (rm << 16) | (rn << 5) | rd);
		}
		break;
	}

	case Oshl:
	case Oshr:
	case Osar: {
		uint32_t rd = greg(i->to.val);
		uint32_t rn = greg(i->arg[0].val);
		if (rtype(i->arg[1]) == RCon) {
			uint32_t width = is64 ? 64u : 32u;
			uint32_t sh = (uint32_t)e->fn->con[i->arg[1].val].bits.i & (width - 1u);
			uint32_t immr, imms, base;
			if (i->op == Oshl) {
				immr = (width - sh) & (width - 1u);
				imms = width - 1u - sh;
				base = 0x53000000u; /* UBFM */
			} else if (i->op == Oshr) {
				immr = sh;
				imms = width - 1u;
				base = 0x53000000u; /* UBFM */
			} else {
				immr = sh;
				imms = width - 1u;
				base = 0x13000000u; /* SBFM */
			}
			emit_u32(base | (sf << 31) | (sf << 22) | (immr << 16) | (imms << 10) | (rn << 5) | rd);
		} else {
			uint32_t rm = greg(i->arg[1].val);
			uint32_t base = (i->op == Oshl) ? 0x1ac02000u
				: (i->op == Oshr) ? 0x1ac02400u : 0x1ac02800u;
			emit_u32(base | (sf << 31) | (rm << 16) | (rn << 5) | rd);
		}
		break;
	}

	case Omul:
		if (KBASE(k) == 1) {
			emit_u32(0x1e200800u | (ftype << 22) | (freg(i->arg[1].val) << 16)
				| (freg(i->arg[0].val) << 5) | freg(i->to.val));
		} else {
			/* mul rd, rn, rm == madd rd, rn, rm, xzr */
			emit_u32(0x1b007c00u | (sf << 31) | (greg(i->arg[1].val) << 16)
				| (greg(i->arg[0].val) << 5) | greg(i->to.val));
		}
		break;

	case Osmulh:
		/* smulh rd, rn, rm */
		emit_u32(0x9b407c00u | (greg(i->arg[1].val) << 16)
			| (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;

	case Odiv:
		if (KBASE(k) == 1) {
			emit_u32(0x1e201800u | (ftype << 22) | (freg(i->arg[1].val) << 16)
				| (freg(i->arg[0].val) << 5) | freg(i->to.val));
		} else {
			emit_u32(0x1ac00c00u | (sf << 31) | (greg(i->arg[1].val) << 16)
				| (greg(i->arg[0].val) << 5) | greg(i->to.val));
		}
		break;

	case Oudiv:
		emit_u32(0x1ac00800u | (sf << 31) | (greg(i->arg[1].val) << 16)
			| (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;

	case Orem:
	case Ourem: {
		uint32_t rd = greg(i->to.val);
		uint32_t rn = greg(i->arg[0].val);
		uint32_t rm = greg(i->arg[1].val);
		uint32_t ip1 = greg(IP1);
		uint32_t divop = (i->op == Orem) ? 0x1ac00c00u : 0x1ac00800u;
		emit_u32(divop | (sf << 31) | (rm << 16) | (rn << 5) | ip1);
		/* msub rd, ip1, rm, rn */
		emit_u32(0x1b008000u | (sf << 31) | (rm << 16) | (rn << 10) | (ip1 << 5) | rd);
		break;
	}

	case Ocopy:
		if (req(i->to, i->arg[0]))
			break;
		if (rtype(i->to) == RSlot) {
			Ref r = i->to;
			if (!isreg(i->arg[0])) {
				i->to = TMP(KBASE(k) == 0 ? IP1 : V31);
				me_emitins(i, e);
				i->arg[0] = i->to;
			}
			i->op = Ostorew + k;
			i->cls = Kw;
			i->arg[1] = r;
			me_emitins(i, e);
			break;
		}
		assert(isreg(i->to) || req(i->to, TMP(V31)));
		switch (rtype(i->arg[0])) {
		case RCon:
			me_loadcon(&e->fn->con[i->arg[0].val], i->to.val, k);
			break;
		case RSlot:
			i->op = Oload;
			me_emitins(i, e);
			break;
		default:
			assert(i->to.val != IP1);
			if (KBASE(k) == 1)
				emit_u32(0x1e204000u | (ftype << 22) | (freg(i->arg[0].val) << 5) | freg(i->to.val));
			else
				enc_mov_reg(is64, i->to.val, i->arg[0].val);
			break;
		}
		break;

	case Oswap:
		if (KBASE(k) == 1) {
			uint32_t r0 = freg(i->arg[0].val);
			uint32_t r1 = freg(i->arg[1].val);
			emit_u32(0x1e204000u | (ftype << 22) | (r0 << 5) | 31u);
			emit_u32(0x1e204000u | (ftype << 22) | (r1 << 5) | r0);
			emit_u32(0x1e204000u | (ftype << 22) | (31u << 5) | r1);
		} else {
			enc_mov_reg(is64, IP1, i->arg[0].val);
			enc_mov_reg(is64, i->arg[0].val, i->arg[1].val);
			enc_mov_reg(is64, i->arg[1].val, IP1);
		}
		break;

	case Ostoreb: me_emit_mem(0x39000000u, 0x38206800u, rtype(i->arg[0]) == RCon ? 31u : greg(i->arg[0].val), 1, i->arg[1], e); break;
	case Ostoreh: me_emit_mem(0x79000000u, 0x78206800u, rtype(i->arg[0]) == RCon ? 31u : greg(i->arg[0].val), 2, i->arg[1], e); break;
	case Ostorew: me_emit_mem(0xb9000000u, 0xb8206800u, rtype(i->arg[0]) == RCon ? 31u : greg(i->arg[0].val), 4, i->arg[1], e); break;
	case Ostorel: me_emit_mem(0xf9000000u, 0xf8206800u, rtype(i->arg[0]) == RCon ? 31u : greg(i->arg[0].val), 8, i->arg[1], e); break;
	case Ostores: me_emit_mem(0xbd000000u, 0xbc206800u, freg(i->arg[0].val), 4, i->arg[1], e); break;
	case Ostored: me_emit_mem(0xfd000000u, 0xfc206800u, freg(i->arg[0].val), 8, i->arg[1], e); break;

	case Oloadsb:
		if (is64)
			me_emit_mem(0x39800000u, 0x38a06800u, greg(i->to.val), 1, i->arg[0], e);
		else
			me_emit_mem(0x39c00000u, 0x38e06800u, greg(i->to.val), 1, i->arg[0], e);
		break;
	case Oloadub:
		me_emit_mem(0x39400000u, 0x38606800u, greg(i->to.val), 1, i->arg[0], e);
		break;
	case Oloadsh:
		if (is64)
			me_emit_mem(0x79800000u, 0x78a06800u, greg(i->to.val), 2, i->arg[0], e);
		else
			me_emit_mem(0x79c00000u, 0x78e06800u, greg(i->to.val), 2, i->arg[0], e);
		break;
	case Oloaduh:
		me_emit_mem(0x79400000u, 0x78606800u, greg(i->to.val), 2, i->arg[0], e);
		break;
	case Oloadsw:
		if (is64)
			me_emit_mem(0xb9800000u, 0xb8a06800u, greg(i->to.val), 4, i->arg[0], e);
		else
			me_emit_mem(0xb9400000u, 0xb8606800u, greg(i->to.val), 4, i->arg[0], e);
		break;
	case Oloaduw:
		me_emit_mem(0xb9400000u, 0xb8606800u, greg(i->to.val), 4, i->arg[0], e);
		break;
	case Oload:
		switch (k) {
		case Kw: me_emit_mem(0xb9400000u, 0xb8606800u, greg(i->to.val), 4, i->arg[0], e); break;
		case Kl: me_emit_mem(0xf9400000u, 0xf8606800u, greg(i->to.val), 8, i->arg[0], e); break;
		case Ks: me_emit_mem(0xbd400000u, 0xbc606800u, freg(i->to.val), 4, i->arg[0], e); break;
		case Kd: me_emit_mem(0xfd400000u, 0xfc606800u, freg(i->to.val), 8, i->arg[0], e); break;
		}
		break;

	case Oextsb:
		emit_u32(0x13001c00u | (sf << 31) | (sf << 22) | (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oextub:
		emit_u32(0x53001c00u | (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oextsh:
		emit_u32(0x13003c00u | (sf << 31) | (sf << 22) | (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oextuh:
		emit_u32(0x53003c00u | (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oextsw:
		emit_u32(0x93407c00u | (greg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oextuw:
		emit_u32(0x2a0003e0u | (greg(i->arg[0].val) << 16) | greg(i->to.val));
		break;

	case Oexts:
		emit_u32(0x1e22c000u | (freg(i->arg[0].val) << 5) | freg(i->to.val));
		break;
	case Otruncd:
		emit_u32(0x1e624000u | (freg(i->arg[0].val) << 5) | freg(i->to.val));
		break;

	case Ocast:
		switch (k) {
		case Kw: emit_u32(0x1e260000u | (freg(i->arg[0].val) << 5) | greg(i->to.val)); break;
		case Kl: emit_u32(0x9e660000u | (freg(i->arg[0].val) << 5) | greg(i->to.val)); break;
		case Ks: emit_u32(0x1e270000u | (greg(i->arg[0].val) << 5) | freg(i->to.val)); break;
		case Kd: emit_u32(0x9e670000u | (greg(i->arg[0].val) << 5) | freg(i->to.val)); break;
		}
		break;

	case Ostosi:
		emit_u32(0x1e380000u | (sf << 31) | (freg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Ostoui:
		emit_u32(0x1e390000u | (sf << 31) | (freg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Odtosi:
		emit_u32(0x1e780000u | (sf << 31) | (freg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Odtoui:
		emit_u32(0x1e790000u | (sf << 31) | (freg(i->arg[0].val) << 5) | greg(i->to.val));
		break;
	case Oswtof:
		emit_u32(0x1e220000u | (ftype << 22) | (greg(i->arg[0].val) << 5) | freg(i->to.val));
		break;
	case Ouwtof:
		emit_u32(0x1e230000u | (ftype << 22) | (greg(i->arg[0].val) << 5) | freg(i->to.val));
		break;
	case Osltof:
		emit_u32(0x9e220000u | (ftype << 22) | (greg(i->arg[0].val) << 5) | freg(i->to.val));
		break;
	case Oultof:
		emit_u32(0x9e230000u | (ftype << 22) | (greg(i->arg[0].val) << 5) | freg(i->to.val));
		break;

	case Oacmp:
	case Oacmn: {
		uint32_t rn = greg(i->arg[0].val);
		if (rtype(i->arg[1]) == RCon) {
			uint64_t n = (uint64_t)e->fn->con[i->arg[1].val].bits.i;
			uint32_t sh = 0, imm12;
			if (n & 0xfff000ULL) {
				assert(!(n & ~0xfff000ULL));
				sh = 1;
				imm12 = (uint32_t)(n >> 12);
			} else {
				assert(!(n & ~0xfffULL));
				imm12 = (uint32_t)n;
			}
			uint32_t base = (i->op == Oacmp) ? 0x7100001fu : 0x3100001fu;
			emit_u32(base | (sf << 31) | (sh << 22) | (imm12 << 10) | (rn << 5));
		} else {
			uint32_t rm = greg(i->arg[1].val);
			uint32_t base = (i->op == Oacmp) ? 0x6b00001fu : 0x2b00001fu;
			emit_u32(base | (sf << 31) | (rm << 16) | (rn << 5));
		}
		break;
	}

	case Oatst: {
		uint32_t rn = greg(i->arg[0].val);
		if (rtype(i->arg[1]) == RCon) {
			uint64_t n = (uint64_t)e->fn->con[i->arg[1].val].bits.i;
			if (!is64)
				n = (uint32_t)n;
			uint32_t N, immr, imms;
			int ok = encode_logimm(n, is64, &N, &immr, &imms);
			assert(ok);
			/* tst rn, #imm == ands wzr/xzr, rn, #imm */
			emit_u32(0x7200001fu | (sf << 31) | (N << 22) | (immr << 16) | (imms << 10) | (rn << 5));
		} else {
			uint32_t rm = greg(i->arg[1].val);
			/* tst rn, rm == ands wzr/xzr, rn, rm */
			emit_u32(0x6a00001fu | (sf << 31) | (rm << 16) | (rn << 5));
		}
		break;
	}

	case Oafcmp: {
		uint32_t rn = freg(i->arg[0].val);
		if (rtype(i->arg[1]) == RCon) {
			emit_u32(0x1e202018u | (ftype << 22) | (rn << 5));
		} else {
			uint32_t rm = freg(i->arg[1].val);
			emit_u32(0x1e202010u | (ftype << 22) | (rm << 16) | (rn << 5));
		}
		break;
	}

	case Oaddr: {
		assert(rtype(i->arg[0]) == RSlot);
		uint32_t rd = greg(i->to.val);
		uint64_t s = me_slot(i->arg[0], e);
		if (s <= 4095) {
			enc_add_imm(1, rd, 29u, s);
		} else if (s <= 65535) {
			enc_movz(1, rd, (uint16_t)s, 0);
			emit_u32(0x8b000000u | (rd << 16) | (29u << 5) | rd);
		} else {
			enc_movz(1, rd, (uint16_t)(s & 0xffffu), 0);
			enc_movk(1, rd, (uint16_t)((s >> 16) & 0xffffu), 1);
			emit_u32(0x8b000000u | (rd << 16) | (29u << 5) | rd);
		}
		break;
	}

	case Ocall:
		if (rtype(i->arg[0]) != RCon) {
			emit_u32(0xd63f0000u | (greg(i->arg[0].val) << 5)); /* blr Xn */
		} else {
			Con *c = &e->fn->con[i->arg[0].val];
			if (c->type != CAddr || (c->sym.type & SThr) || c->bits.i)
				die("macho: invalid call argument");
			uint32_t sym = sym_ref_qbe(str(c->sym.id), "");
			uint32_t pc = text_pos();
			emit_u32(0x94000000u); /* bl sym */
			sec_add_reloc(SEC_TEXT, (int32_t)pc, sym, 1, 2, 1, ARM64_RELOC_BRANCH26);
		}
		break;

	case Osalloc:
		enc_sub_reg(1, SP, SP, i->arg[0].val);
		if (!req(i->to, R))
			enc_mov_reg(1, i->to.val, SP);
		break;
	}
}

static Ins *
me_can_fuse_cbz(Blk *b, Fn *fn)
{
	Ins *p;
	Con *c;

	if (b->jmp.type != Jjfieq && b->jmp.type != Jjfine)
		return 0;
	for (p = &b->ins[b->nins]; p > b->ins;) {
		--p;
		if (p->op == Onop || p->op == Odbgloc)
			continue;
		if (p->op == Oacmp && KBASE(p->cls) == 0
		&& isreg(p->arg[0]) && p->arg[0].val != SP
		&& rtype(p->arg[1]) == RCon) {
			c = &fn->con[p->arg[1].val];
			if (c->type == CBits && c->bits.i == 0)
				return p;
		}
		return 0;
	}
	return 0;
}

static Ins *
me_can_fuse_flag_cbz(Blk *b, Ins *cbz_ins, uint64_t live_out)
{
	Ins *p;

	if (!cbz_ins)
		return 0;
	for (p = cbz_ins; p > b->ins;) {
		--p;
		if (p->op == Onop || p->op == Odbgloc)
			continue;
		if (INRANGE(p->op, Oflag, Oflag1)
		&& req(p->to, cbz_ins->arg[0])
		&& (live_out & BIT(p->to.val)) == 0)
			return p;
		return 0;
	}
	return 0;
}

static int
me_mem_base_off(Ref r, Fn *fn, int *base_out, int64_t *off_out)
{
	if (rtype(r) == RTmp && isreg(r)) {
		*base_out = r.val;
		*off_out = 0;
		return 1;
	}
	if (rtype(r) == RMem) {
		Mem *m = &fn->mem[r.val];
		if (isreg(m->base) && req(m->index, R) && m->offset.type == CBits) {
			*base_out = m->base.val;
			*off_out = m->offset.bits.i;
			return 1;
		}
	}
	return 0;
}

static int
me_w32_def_reg(const Ins *i, int cur_reg)
{
	if (i->op == Onop || i->op == Odbgloc)
		return cur_reg;
	if (i->op == Ocopy && req(i->to, i->arg[0]))
		return cur_reg;
	if (!isreg(i->to) || i->to.val == SP || i->to.val < R0 || i->to.val > LR)
		return -1;
	switch (i->op) {
	case Oloadub:
	case Oloaduh:
	case Oloaduw:
	case Oextub:
	case Oextuh:
	case Oextuw:
		return i->to.val;
	case Oadd:
	case Osub:
	case Oneg:
	case Oand:
	case Oor:
	case Oxor:
	case Oshl:
	case Oshr:
	case Osar:
	case Omul:
	case Odiv:
	case Oudiv:
	case Orem:
	case Ourem:
	case Oload:
	case Oloadsw:
	case Ocast:
	case Ostosi:
	case Ostoui:
	case Odtosi:
	case Odtoui:
	case Ocopy:
		return i->cls == Kw ? i->to.val : -1;
	default:
		if (i->cls == Kw && (INRANGE(i->op, Oflag, Oflag1) || isxsel(i->op)))
			return i->to.val;
		return -1;
	}
}

static uint64_t *
me_compute_gpr_out(Fn *fn)
{
	uint64_t *in = alloc(fn->nblk * sizeof *in);
	uint64_t *out = alloc(fn->nblk * sizeof *out);
	uint64_t call_pres = 0, all_gpr = 0;
	for (int r = R19; r <= LR; r++)
		call_pres |= BIT(r);
	call_pres |= BIT(SP);
	for (int r = R0; r <= LR; r++)
		all_gpr |= BIT(r);
	all_gpr |= BIT(SP);

	int changed;
	do {
		changed = 0;
		for (Blk *b = fn->start; b; b = b->link) {
			uint64_t live = 0;
			if (b->jmp.type == Jret0) {
				live = call_pres;
				if (rtype(b->jmp.arg) == RCall)
					live |= arm64_retregs(b->jmp.arg, 0) & all_gpr;
				else
					live |= BIT(R0) | BIT(R1);
			} else if (b->jmp.type == Jhlt) {
				live = 0;
			} else if (b->jmp.type == Jjtbl) {
				if (b->s1)
					live |= in[b->s1->id];
				for (uint32_t j = 0; j < b->njtbl; j++)
					live |= in[b->jtbl[j]->id];
			} else {
				if (b->s1)
					live |= in[b->s1->id];
				if (b->s2)
					live |= in[b->s2->id];
			}
			if (isreg(b->jmp.arg) && (all_gpr & BIT(b->jmp.arg.val)))
				live |= BIT(b->jmp.arg.val);
			out[b->id] = live;
			for (Ins *ins = &b->ins[b->nins]; ins > b->ins;) {
				--ins;
				if (ins->op == Ocall) {
					live &= call_pres;
					if (rtype(ins->arg[1]) == RCall)
						live |= arm64_argregs(ins->arg[1], 0) & all_gpr;
					else
						live |= BIT(R0) | BIT(R1) | BIT(R2) | BIT(R3) | BIT(R4) | BIT(R5) | BIT(R6) | BIT(R7) | BIT(R8);
					if (isreg(ins->arg[0]) && (all_gpr & BIT(ins->arg[0].val)))
						live |= BIT(ins->arg[0].val);
					continue;
				}
				if (isreg(ins->to) && (all_gpr & BIT(ins->to.val))
				&& ins->op != Osel0 && !isxsel(ins->op))
					live &= ~BIT(ins->to.val);
				for (int j = 0; j < 2; j++) {
					Ref a = ins->arg[j];
					if (isreg(a) && (all_gpr & BIT(a.val)))
						live |= BIT(a.val);
					else if (rtype(a) == RMem) {
						Mem *m = &fn->mem[a.val];
						if (isreg(m->base) && (all_gpr & BIT(m->base.val)))
							live |= BIT(m->base.val);
						if (isreg(m->index) && (all_gpr & BIT(m->index.val)))
							live |= BIT(m->index.val);
					}
				}
			}
			if (live != in[b->id]) {
				in[b->id] = live;
				changed = 1;
			}
		}
	} while (changed);
	return out;
}

static int
me_reg_dead_after(Fn *fn, Ins *start, Ins *end, Ref reg, uint64_t live_out)
{
	for (Ins *ins = start; ins < end; ins++) {
		if (ins->op == Ocall)
			return 0;
		for (int j = 0; j < 2; j++) {
			Ref a = ins->arg[j];
			if (req(a, reg))
				return 0;
			if (rtype(a) == RMem) {
				Mem *m = &fn->mem[a.val];
				if (req(m->base, reg) || req(m->index, reg))
					return 0;
			}
		}
		if (req(ins->to, reg) && ins->op != Osel0 && !isxsel(ins->op))
			return 1;
	}
	return (live_out & BIT(reg.val)) == 0;
}

void
arm64_macho_fn(Fn *fn)
{
	ME e;
	memset(&e, 0, sizeof e);
	e.fn = fn;

	sec_align(SEC_TEXT, 4);
	sym_define(fn->name, "", SEC_TEXT, sec_size(&M.secs[SEC_TEXT]), fn->lnk.export);

	/* hint #34 (bti c) */
	emit_u32(0xd503245fu);
	me_framelayout(&e);

	if (e.frame + 16 <= 512) {
		enc_stp_pre(29, 30, 31, -(int64_t)(e.frame + 16));
	} else if (e.frame <= 4095) {
		enc_sub_imm(1, 31, 31, e.frame);
		enc_stp_pre(29, 30, 31, -16);
	} else if (e.frame <= 65535) {
		enc_movz(1, 16, (uint16_t)e.frame, 0);
		enc_sub_reg(1, SP, SP, IP0);
		enc_stp_pre(29, 30, 31, -16);
	} else {
		enc_movz(1, 16, (uint16_t)(e.frame & 0xffffu), 0);
		enc_movk(1, 16, (uint16_t)((e.frame >> 16) & 0xffffu), 1);
		enc_sub_reg(1, SP, SP, IP0);
		enc_stp_pre(29, 30, 31, -16);
	}
	enc_mov_reg(1, FP, SP);

	int s = (int)((e.frame - e.padding) / 4);
	for (int *r = arm64_rclob; *r >= 0; r++) {
		if (fn->reg & BIT(*r)) {
			s -= 2;
			Ins ins = { .op = *r >= V0 ? Ostored : Ostorel, .cls = Kw, .to = R, .arg = { TMP(*r), SLOT(s) } };
			me_emitins(&ins, &e);
		}
	}

	uint32_t *blk_off = emalloc((size_t)(fn->nblk + 1) * sizeof *blk_off);

	uint64_t *gpr_out = me_compute_gpr_out(fn);
	for (Blk *b = fn->start; b; b = b->link) {
		uint64_t live_out = gpr_out[b->id];
		Ins *cbz_ins = me_can_fuse_cbz(b, fn);
		Ins *flag_ins = me_can_fuse_flag_cbz(b, cbz_ins, live_out);
		int last_w32 = -1;
		blk_off[b->id] = text_pos();
		for (Ins *i = b->ins; i != &b->ins[b->nins]; i++) {
			if (i == cbz_ins || i == flag_ins) {
				last_w32 = -1;
				continue;
			}
			if (i->op == Oextuw && req(i->to, i->arg[0])
			&& isreg(i->to) && i->to.val == last_w32)
				continue;
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins
			&& i->op == Omul && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && isreg(i->arg[1])) {
				Ins *i1 = i + 1;
				if (i1->cls == i->cls && isreg(i1->to)
				&& (req(i1->to, i->to) || me_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to, live_out))) {
					uint32_t sf = (i->cls == Kl) ? 1u : 0u;
					if (i1->op == Osub && isreg(i1->arg[0])
					&& req(i1->arg[1], i->to) && !req(i1->arg[0], i->to)) {
						/* msub rd, rn, rm, ra */
						emit_u32(0x1b008000u | (sf << 31)
							| (greg(i->arg[1].val) << 16)
							| (greg(i1->arg[0].val) << 10)
							| (greg(i->arg[0].val) << 5)
							| greg(i1->to.val));
						if (last_w32 == i->to.val)
							last_w32 = -1;
						last_w32 = me_w32_def_reg(i1, last_w32);
						i++;
						continue;
					}
					if (i1->op == Oadd
					&& ((isreg(i1->arg[0]) && req(i1->arg[1], i->to) && !req(i1->arg[0], i->to))
					 || (isreg(i1->arg[1]) && req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)))) {
						Ref ra = req(i1->arg[1], i->to) ? i1->arg[0] : i1->arg[1];
						/* madd rd, rn, rm, ra */
						emit_u32(0x1b000000u | (sf << 31)
							| (greg(i->arg[1].val) << 16)
							| (greg(ra.val) << 10)
							| (greg(i->arg[0].val) << 5)
							| greg(i1->to.val));
						if (last_w32 == i->to.val)
							last_w32 = -1;
						last_w32 = me_w32_def_reg(i1, last_w32);
						i++;
						continue;
					}
				}
			}
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins
			&& (i->op == Oshl || i->op == Oshr || i->op == Osar) && KBASE(i->cls) == 0
			&& isreg(i->to) && isreg(i->arg[0]) && i->arg[0].val != SP
			&& rtype(i->arg[1]) == RCon) {
				Con *sc = &fn->con[i->arg[1].val];
				if (sc->type == CBits) {
					uint32_t maxsh = (i->cls == Kl) ? 63u : 31u;
					uint32_t sh = (uint32_t)sc->bits.i & maxsh;
					uint32_t sh_type = (i->op == Oshl) ? 0u : (i->op == Oshr ? 1u : 2u);
					Ins *i1 = i + 1;
					if (sh >= 1 && i1->cls == i->cls && isreg(i1->to) && i1->to.val != SP
					&& (req(i1->to, i->to) || me_reg_dead_after(fn, i1 + 1, &b->ins[b->nins], i->to, live_out))) {
						uint32_t sf = (i->cls == Kl) ? 1u : 0u;
						if (i1->op == Oadd
						&& ((isreg(i1->arg[0]) && i1->arg[0].val != SP && req(i1->arg[1], i->to) && !req(i1->arg[0], i->to))
						 || (isreg(i1->arg[1]) && i1->arg[1].val != SP && req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)))) {
							Ref ra = req(i1->arg[1], i->to) ? i1->arg[0] : i1->arg[1];
							/* add rd, ra, rn, <lsl|lsr|asr> #sh */
							emit_u32(0x0b000000u | (sf << 31)
								| (sh_type << 22)
								| (greg(i->arg[0].val) << 16)
								| (sh << 10)
								| (greg(ra.val) << 5)
								| greg(i1->to.val));
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = me_w32_def_reg(i1, last_w32);
							i++;
							continue;
						}
						if (i1->op == Osub && isreg(i1->arg[0]) && i1->arg[0].val != SP
						&& req(i1->arg[1], i->to) && !req(i1->arg[0], i->to)) {
							/* sub rd, ra, rn, <lsl|lsr|asr> #sh */
							emit_u32(0x4b000000u | (sf << 31)
								| (sh_type << 22)
								| (greg(i->arg[0].val) << 16)
								| (sh << 10)
								| (greg(i1->arg[0].val) << 5)
								| greg(i1->to.val));
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = me_w32_def_reg(i1, last_w32);
							i++;
							continue;
						}
					}
				}
			}
			/* Pair adjacent 64-bit or 32-bit loads/stores into ldp/stp */
			if (i + 1 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 1 != flag_ins) {
				Ins *i1 = i + 1;
				int b0, b1;
				int64_t o0, o1;
				if ((i->op == Oload || i->op == Oloaduw) && i1->op == i->op
				&& i->cls == i1->cls
				&& ((i->op == Oload && (i->cls == Kl || i->cls == Kd || i->cls == Kw || i->cls == Ks))
				 || (i->op == Oloaduw && i->cls == Kw))
				&& isreg(i->to) && isreg(i1->to)
				&& i->to.val != SP && i1->to.val != SP
				&& i->to.val != i1->to.val
				&& me_mem_base_off(i->arg[0], fn, &b0, &o0)
				&& me_mem_base_off(i1->arg[0], fn, &b1, &o1)
				&& b0 == b1 && i->to.val != b0) {
					int64_t step = (i->cls == Kl || i->cls == Kd) ? 8 : 4;
					int64_t mino = (step == 8) ? -512 : -256;
					int64_t maxo = (step == 8) ? 504 : 252;
					if (o1 == o0 + step && (o0 & (step - 1)) == 0
					&& o0 >= mino && o0 <= maxo) {
						uint32_t imm7 = (uint32_t)(o0 / step) & 0x7fu;
						if (i->cls == Kl)
							emit_u32(0xa9400000u | (imm7 << 15)
								| (greg(i1->to.val) << 10)
								| (greg(b0) << 5)
								| greg(i->to.val));
						else if (i->cls == Kw)
							emit_u32(0x29400000u | (imm7 << 15)
								| (greg(i1->to.val) << 10)
								| (greg(b0) << 5)
								| greg(i->to.val));
						else if (i->cls == Kd)
							emit_u32(0x6d400000u | (imm7 << 15)
								| (freg(i1->to.val) << 10)
								| (greg(b0) << 5)
								| freg(i->to.val));
						else
							emit_u32(0x2d400000u | (imm7 << 15)
								| (freg(i1->to.val) << 10)
								| (greg(b0) << 5)
								| freg(i->to.val));
						if (last_w32 == i->to.val || last_w32 == i1->to.val)
							last_w32 = -1;
						i++;
						continue;
					}
				}
				if ((i->op == Ostorel || i->op == Ostored || i->op == Ostorew || i->op == Ostores)
				&& i1->op == i->op
				&& isreg(i->arg[0]) && isreg(i1->arg[0])
				&& i->arg[0].val != SP && i1->arg[0].val != SP
				&& me_mem_base_off(i->arg[1], fn, &b0, &o0)
				&& me_mem_base_off(i1->arg[1], fn, &b1, &o1)
				&& b0 == b1) {
					int64_t step = (i->op == Ostorel || i->op == Ostored) ? 8 : 4;
					int64_t mino = (step == 8) ? -512 : -256;
					int64_t maxo = (step == 8) ? 504 : 252;
					if (o1 == o0 + step && (o0 & (step - 1)) == 0
					&& o0 >= mino && o0 <= maxo) {
						uint32_t imm7 = (uint32_t)(o0 / step) & 0x7fu;
						if (i->op == Ostorel)
							emit_u32(0xa9000000u | (imm7 << 15)
								| (greg(i1->arg[0].val) << 10)
								| (greg(b0) << 5)
								| greg(i->arg[0].val));
						else if (i->op == Ostorew)
							emit_u32(0x29000000u | (imm7 << 15)
								| (greg(i1->arg[0].val) << 10)
								| (greg(b0) << 5)
								| greg(i->arg[0].val));
						else if (i->op == Ostored)
							emit_u32(0x6d000000u | (imm7 << 15)
								| (freg(i1->arg[0].val) << 10)
								| (greg(b0) << 5)
								| freg(i->arg[0].val));
						else
							emit_u32(0x2d000000u | (imm7 << 15)
								| (freg(i1->arg[0].val) << 10)
								| (greg(b0) << 5)
								| freg(i->arg[0].val));
						i++;
						continue;
					}
				}
			}
			if (i + 2 < &b->ins[b->nins] && i + 1 != cbz_ins && i + 2 != cbz_ins
			&& i + 1 != flag_ins && i + 2 != flag_ins
			&& i->op == Oadd && KBASE(i->cls) == 0
			&& isreg(i->to) && i->to.val != SP) {
				Ref ra = R;
				int is_inc1 = 0;
				if (isreg(i->arg[0]) && i->arg[0].val != SP && !req(i->arg[0], i->to)
				&& rtype(i->arg[1]) == RCon) {
					Con *ac = &fn->con[i->arg[1].val];
					if (ac->type == CBits && ac->bits.i == 1) {
						ra = i->arg[0];
						is_inc1 = 1;
					}
				} else if (isreg(i->arg[1]) && i->arg[1].val != SP && !req(i->arg[1], i->to)
				&& rtype(i->arg[0]) == RCon) {
					Con *ac = &fn->con[i->arg[0].val];
					if (ac->type == CBits && ac->bits.i == 1) {
						ra = i->arg[1];
						is_inc1 = 1;
					}
				}
				if (is_inc1) {
					Ins *i1 = i + 1;
					Ins *i2 = i + 2;
					if ((i1->op == Oacmp || i1->op == Oacmn || i1->op == Oatst || i1->op == Oafcmp)
					&& !req(i1->arg[0], i->to) && !req(i1->arg[1], i->to)
					&& isxsel(i2->op) && i2->cls == i->cls && req(i2->to, ra)
					&& me_reg_dead_after(fn, i2 + 1, &b->ins[b->nins], i->to, live_out)) {
						int inv = -1;
						if (req(i2->arg[0], i->to) && req(i2->arg[1], ra))
							inv = 0;
						else if (req(i2->arg[0], ra) && req(i2->arg[1], i->to))
							inv = 1;
						if (inv >= 0) {
							uint32_t sf = (i2->cls == Kl) ? 1u : 0u;
							uint32_t r = greg(ra.val);
							uint32_t cc = cmp_cc[(int)i2->op - Oxsel][0];
							uint32_t cond = inv == 0 ? ((cc ^ 1u) & 0xfu) : (cc & 0xfu);
							me_emitins(i1, &e);
							/* csinc rd, ra, ra, cond (alias: cinc rd, ra, inv(cond)) */
							emit_u32(0x1a800400u | (sf << 31) | (r << 16) | (cond << 12) | (r << 5) | r);
							if (last_w32 == i->to.val)
								last_w32 = -1;
							last_w32 = me_w32_def_reg(i2, last_w32);
							i += 2;
							continue;
						}
					}
				}
			}
			int next_w32 = me_w32_def_reg(i, last_w32);
			me_emitins(i, &e);
			last_w32 = next_w32;
		}

		switch (b->jmp.type) {
		case Jhlt:
			emit_u32(0xd4207d00u); /* brk #1000 */
			break;
		case Jret0: {
			int rs = (int)((e.frame - e.padding) / 4);
			for (int *r = arm64_rclob; *r >= 0; r++) {
				if (fn->reg & BIT(*r)) {
					rs -= 2;
					Ins ins = { .op = Oload, .cls = *r >= V0 ? Kd : Kl, .to = TMP(*r), .arg = { SLOT(rs), R } };
					me_emitins(&ins, &e);
				}
			}
			if (fn->dynalloc)
				enc_mov_reg(1, SP, FP);
			uint64_t o = e.frame + 16;
			if (o <= 504) {
				enc_ldp_post(29, 30, 31, (int64_t)o);
			} else if (o - 16 <= 4095) {
				enc_ldp_post(29, 30, 31, 16);
				enc_add_imm(1, 31, 31, o - 16);
			} else if (o - 16 <= 65535) {
				enc_ldp_post(29, 30, 31, 16);
				enc_movz(1, 16, (uint16_t)(o - 16), 0);
				enc_add_reg(1, SP, SP, IP0);
			} else {
				enc_ldp_post(29, 30, 31, 16);
				enc_movz(1, 16, (uint16_t)((o - 16) & 0xffffu), 0);
				enc_movk(1, 16, (uint16_t)(((o - 16) >> 16) & 0xffffu), 1);
				enc_add_reg(1, SP, SP, IP0);
			}
			emit_u32(0xd65f03c0u); /* ret */
			break;
		}
		case Jjmp:
		Jmp:
			if (b->s1 != b->link) {
				me_add_fixup(&e, text_pos(), b->s1->id, 0x14000000u, 0);
				emit_u32(0x14000000u); /* b placeholder */
			}
			break;
		case Jjtbl: {
			uint32_t idx;
			if (rtype(b->jmp.arg) == RSlot) {
				Ins li = { .op = Oload, .cls = Kw, .to = TMP(IP0), .arg = { b->jmp.arg, R } };
				me_emitins(&li, &e);
				idx = greg(IP0);
			} else {
				assert(isreg(b->jmp.arg));
				idx = greg(b->jmp.arg.val);
			}
			if (b->njtbl <= 4095) {
				/* cmp w<idx>, #njtbl (subs wzr, w<idx>, #njtbl) */
				emit_u32(0x7100001fu | (b->njtbl << 10) | (idx << 5));
			} else if (b->njtbl <= 65535) {
				enc_movz(0, 17, (uint16_t)b->njtbl, 0);
				/* cmp w<idx>, w17 (subs wzr, w<idx>, w17) */
				emit_u32(0x6b11001fu | (idx << 5));
			} else {
				enc_movz(0, 17, (uint16_t)(b->njtbl & 0xffffu), 0);
				enc_movk(0, 17, (uint16_t)(b->njtbl >> 16), 1);
				emit_u32(0x6b11001fu | (idx << 5));
			}
			/* b.hs <s1> (cond 0x2 = CS/HS) */
			me_add_fixup(&e, text_pos(), b->s1->id, 0x54000002u, 1);
			emit_u32(0x54000002u);
			/* adr x17, .+16 */
			emit_u32(0x10000091u);
			/* ldrsw x16, [x17, w<idx>, uxtw #2] */
			emit_u32(0xb8a05a30u | (idx << 16));
			/* add x17, x17, x16 */
			emit_u32(0x8b100231u);
			/* br x17 */
			emit_u32(0xd61f0220u);
			uint32_t tbl_base = text_pos();
			for (uint32_t jk = 0; jk < b->njtbl; jk++) {
				me_add_jtfixup(&e, text_pos(), tbl_base, b->jtbl[jk]->id);
				emit_u32(0);
			}
			break;
		}
		default: {
			int c = b->jmp.type - Jjf;
			if (c < 0 || c >= NCmp)
				die("macho: unhandled jump %d", b->jmp.type);
			int inv;
			if (b->link == b->s2) {
				Blk *t = b->s1;
				b->s1 = b->s2;
				b->s2 = t;
				inv = 0;
			} else {
				inv = 1;
			}
			if (flag_ins) {
				int fc = flag_ins->op - Oflag;
				int fn_inv = (c == Cieq) ? (inv ^ 1) : inv;
				uint32_t base = 0x54000000u | cmp_cc[fc][fn_inv];
				me_add_fixup(&e, text_pos(), b->s2->id, base, 1);
				emit_u32(base);
			} else if (cbz_ins) {
				int is_nz = (c == Cine) ^ inv;
				uint32_t sf = KWIDE(cbz_ins->cls) ? 1u : 0u;
				uint32_t rt = greg(cbz_ins->arg[0].val);
				uint32_t base = 0x34000000u | (sf << 31) | ((uint32_t)is_nz << 24) | rt;
				me_add_fixup(&e, text_pos(), b->s2->id, base, 1);
				emit_u32(base);
			} else {
				uint32_t base = 0x54000000u | cmp_cc[c][inv];
				me_add_fixup(&e, text_pos(), b->s2->id, base, 1);
				emit_u32(base); /* b.cc placeholder */
			}
			goto Jmp;
		}
		}
	}

	/* Patch local branches */
	uint8_t *code = M.secs[SEC_TEXT].buf.data;
	for (size_t k = 0; k < e.nfixups; k++) {
		BrFixup *f = &e.fixups[k];
		int64_t diff = ((int64_t)blk_off[f->target_bid] - (int64_t)f->pc_off) / 4;
		uint32_t insn;
		if (f->is_imm19) {
			if (diff < -262144 || diff > 262143)
				die("macho: conditional branch out of 1MB range in %s", fn->name);
			insn = f->base | (((uint32_t)diff & 0x7ffffu) << 5);
		} else {
			if (diff < -33554432 || diff > 33554431)
				die("macho: unconditional branch out of 128MB range in %s", fn->name);
			insn = f->base | ((uint32_t)diff & 0x03ffffffu);
		}
		code[f->pc_off + 0] = (uint8_t)(insn & 0xffu);
		code[f->pc_off + 1] = (uint8_t)((insn >> 8) & 0xffu);
		code[f->pc_off + 2] = (uint8_t)((insn >> 16) & 0xffu);
		code[f->pc_off + 3] = (uint8_t)((insn >> 24) & 0xffu);
	}

	/* Patch jump table entries */
	for (size_t k = 0; k < e.njtfixups; k++) {
		JtblFixup *jf = &e.jtfixups[k];
		int32_t rel = (int32_t)blk_off[jf->target_bid] - (int32_t)jf->tbl_base_off;
		uint32_t u = (uint32_t)rel;
		code[jf->entry_off + 0] = (uint8_t)(u & 0xffu);
		code[jf->entry_off + 1] = (uint8_t)((u >> 8) & 0xffu);
		code[jf->entry_off + 2] = (uint8_t)((u >> 16) & 0xffu);
		code[jf->entry_off + 3] = (uint8_t)((u >> 24) & 0xffu);
	}

	free(blk_off);
	free(e.fixups);
	free(e.jtfixups);
}

/* ---- Data section emission ---- */

static int
resolve_custom_sec(const char *sec_str, const char *secf_str)
{
	char seg[32], sect[32];
	const char *p = sec_str;
	if (*p == '"')
		p++;
	size_t i = 0;
	while (*p && *p != ',' && *p != '"' && i + 1 < sizeof seg)
		seg[i++] = *p++;
	seg[i] = '\0';

	if (*p == ',') {
		p++;
	} else if (secf_str) {
		p = secf_str;
		if (*p == '"')
			p++;
	}
	i = 0;
	while (*p && *p != ',' && *p != '"' && i + 1 < sizeof sect)
		sect[i++] = *p++;
	sect[i] = '\0';

	if (sect[0] == '\0') {
		/* ELF-style single section name fallback */
		if (strcmp(seg, ".rodata") == 0)
			return SEC_CONST;
		if (strcmp(seg, ".data") == 0)
			return SEC_DATA;
		if (strcmp(seg, ".bss") == 0)
			return SEC_BSS;
		return SEC_DATA;
	}

	for (size_t k = 0; k < M.nsecs; k++) {
		if (strncmp(M.secs[k].segname, seg, 16) == 0 &&
		    strncmp(M.secs[k].sectname, sect, 16) == 0)
			return (int)k;
	}
	return add_sec(seg, sect, S_REGULAR, 0, 0);
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
			case 'n': buf_put_u8(b, '\n'); p++; break;
			case 't': buf_put_u8(b, '\t'); p++; break;
			case 'r': buf_put_u8(b, '\r'); p++; break;
			case 'b': buf_put_u8(b, '\b'); p++; break;
			case 'f': buf_put_u8(b, '\f'); p++; break;
			case 'v': buf_put_u8(b, '\v'); p++; break;
			case 'a': buf_put_u8(b, '\a'); p++; break;
			case '\\': buf_put_u8(b, '\\'); p++; break;
			case '"': buf_put_u8(b, '"'); p++; break;
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
	const char *sfx = "";

	if (M.dat_lnk.thread) {
		sec_align(SEC_TLVVARS, 8);
		uint64_t tv_off = sec_size(&M.secs[SEC_TLVVARS]);
		sym_define(M.dat_name, "", SEC_TLVVARS, tv_off, M.dat_lnk.export);
		uint32_t boot_sym = sym_intern("__tlv_bootstrap");
		uint32_t init_sym = sym_ref_qbe(M.dat_name, "$tlv$init");
		sec_add_reloc(SEC_TLVVARS, (int32_t)tv_off, boot_sym, 0, 3, 1, ARM64_RELOC_UNSIGNED);
		buf_put_u64(&M.secs[SEC_TLVVARS].buf, 0);
		buf_put_u64(&M.secs[SEC_TLVVARS].buf, 0);
		sec_add_reloc(SEC_TLVVARS, (int32_t)(tv_off + 16), init_sym, 0, 3, 1, ARM64_RELOC_UNSIGNED);
		buf_put_u64(&M.secs[SEC_TLVVARS].buf, 0);
		sec_idx = SEC_TLVDATA;
		sfx = "$tlv$init";
	} else if (M.dat_sec_str) {
		sec_idx = resolve_custom_sec(M.dat_sec_str, M.dat_secf_str);
	}

	uint32_t al = M.dat_lnk.align > 0 ? (uint32_t)M.dat_lnk.align : 1u;
	sec_align(sec_idx, al);
	sym_define(M.dat_name, sfx, sec_idx, sec_size(&M.secs[sec_idx]),
		M.dat_lnk.thread ? 0 : M.dat_lnk.export);
	return sec_idx;
}

void
arm64_macho_dat(Dat *d)
{
	switch (d->type) {
	case DStart:
		free(M.dat_name);
		free(M.dat_sec_str);
		free(M.dat_secf_str);
		M.dat_name = emalloc(strlen(d->name) + 1);
		strcpy(M.dat_name, d->name);
		M.dat_lnk = *d->lnk;
		M.dat_sec_str = d->lnk->sec ? emalloc(strlen(d->lnk->sec) + 1) : 0;
		if (M.dat_sec_str) strcpy(M.dat_sec_str, d->lnk->sec);
		M.dat_secf_str = d->lnk->secf ? emalloc(strlen(d->lnk->secf) + 1) : 0;
		if (M.dat_secf_str) strcpy(M.dat_secf_str, d->lnk->secf);
		M.dat_sec_idx = -1;
		M.dat_zero = 0;
		break;

	case DEnd:
		if (M.dat_lnk.common) {
			if (M.dat_zero == -1)
				die("macho: invalid common data definition");
			uint32_t idx = sym_ref_qbe(M.dat_name, "");
			SymEnt *e = &M.syms[idx];
			e->defined = 0;
			e->is_common = 1;
			e->is_export = 1;
			e->offset = (uint64_t)M.dat_zero;
			e->common_align = log2_align(M.dat_lnk.align > 0 ? (uint32_t)M.dat_lnk.align : 1u);
		} else if (M.dat_zero != -1) {
			int sec_idx = dat_open_sec(SEC_BSS);
			Sec *s = &M.secs[sec_idx];
			if (s->is_zerofill)
				s->zf_size += (uint64_t)M.dat_zero;
			else
				buf_put_zeros(&s->buf, (size_t)M.dat_zero);
		}
		free(M.dat_name); M.dat_name = 0;
		free(M.dat_sec_str); M.dat_sec_str = 0;
		free(M.dat_secf_str); M.dat_secf_str = 0;
		break;

	case DZ:
		if (M.dat_zero != -1) {
			M.dat_zero += d->u.num;
		} else {
			buf_put_zeros(&M.secs[M.dat_sec_idx].buf, (size_t)d->u.num);
		}
		break;

	default:
		if (M.dat_zero != -1) {
			M.dat_sec_idx = dat_open_sec(SEC_DATA);
			if (M.dat_zero > 0)
				buf_put_zeros(&M.secs[M.dat_sec_idx].buf, (size_t)M.dat_zero);
			M.dat_zero = -1;
		}
		if (d->isstr) {
			if (d->type != DB)
				err("strings only supported for 'b' currently");
			emit_ascii_str(&M.secs[M.dat_sec_idx].buf, d->u.str);
		} else if (d->isref) {
			uint32_t sym = sym_ref_qbe(d->u.ref.name, "");
			int32_t off = (int32_t)M.secs[M.dat_sec_idx].buf.len;
			if (d->type == DL) {
				sec_add_reloc(M.dat_sec_idx, off, sym, 0, 3, 1, ARM64_RELOC_UNSIGNED);
				buf_put_u64(&M.secs[M.dat_sec_idx].buf, (uint64_t)d->u.ref.off);
			} else if (d->type == DW) {
				sec_add_reloc(M.dat_sec_idx, off, sym, 0, 2, 1, ARM64_RELOC_UNSIGNED);
				buf_put_u32(&M.secs[M.dat_sec_idx].buf, (uint32_t)d->u.ref.off);
			} else {
				die("macho: unsupported ref data width %d", d->type);
			}
		} else {
			Buf *b = &M.secs[M.dat_sec_idx].buf;
			switch (d->type) {
			case DB: buf_put_u8(b, (uint8_t)d->u.num); break;
			case DH: buf_put_u16(b, (uint16_t)d->u.num); break;
			case DW: buf_put_u32(b, (uint32_t)d->u.num); break;
			case DL: buf_put_u64(b, (uint64_t)d->u.num); break;
			default: die("macho: unexpected dat type %d", d->type);
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
	if (size == 16) {
		sec_align(SEC_LIT16, 16);
		sym_define(name, "", SEC_LIT16, sec_size(&M.secs[SEC_LIT16]), 0);
		buf_put_u64(&M.secs[SEC_LIT16].buf, (uint64_t)n);
		buf_put_u64(&M.secs[SEC_LIT16].buf, 0);
	} else if (size == 8) {
		sec_align(SEC_LIT8, 8);
		sym_define(name, "", SEC_LIT8, sec_size(&M.secs[SEC_LIT8]), 0);
		buf_put_u64(&M.secs[SEC_LIT8].buf, (uint64_t)n);
	} else {
		sec_align(SEC_LIT4, 4);
		sym_define(name, "", SEC_LIT4, sec_size(&M.secs[SEC_LIT4]), 0);
		buf_put_u32(&M.secs[SEC_LIT4].buf, (uint32_t)n);
	}
}

/* ---- Public lifecycle ---- */

void
arm64_macho_begin(uint32_t macos_ver)
{
	memset(&M, 0, sizeof M);
	M.macos_ver = macos_ver ? macos_ver : (15u << 16);

	add_sec("__TEXT", "__text", S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 2, 0);
	add_sec("__TEXT", "__const", S_REGULAR, 0, 0);
	add_sec("__TEXT", "__literal4", S_4BYTE_LITERALS, 2, 0);
	add_sec("__TEXT", "__literal8", S_8BYTE_LITERALS, 3, 0);
	add_sec("__TEXT", "__literal16", S_16BYTE_LITERALS, 4, 0);
	add_sec("__DATA", "__data", S_REGULAR, 0, 0);
	add_sec("__DATA", "__bss", S_ZEROFILL, 0, 1);
	add_sec("__DATA", "__thread_vars", S_THREAD_LOCAL_VARIABLES, 3, 0);
	add_sec("__DATA", "__thread_data", S_THREAD_LOCAL_REGULAR, 0, 0);
}

void
arm64_macho_finish(FILE *outf)
{
	iterstash(emit_stash_cb, 0);

	/* Ensure at least __text exists so MH_OBJECT is always valid even for empty files */
	uint32_t n_active = 0;
	for (size_t i = 0; i < M.nsecs; i++) {
		if (sec_size(&M.secs[i]) > 0 || i == SEC_TEXT) {
			M.secs[i].out_sect_num = (int)(++n_active);
		} else {
			M.secs[i].out_sect_num = 0;
		}
	}

	/* Load commands sizes */
	uint32_t seg_cmd_size = (uint32_t)(sizeof(SegmentCmd64) + n_active * sizeof(Section64));
	uint32_t bv_cmd_size = (uint32_t)sizeof(BuildVerCmd);
	uint32_t sym_cmd_size = (uint32_t)sizeof(SymtabCmd);
	uint32_t dysym_cmd_size = (uint32_t)sizeof(DysymtabCmd);
	uint32_t sizeofcmds = seg_cmd_size + bv_cmd_size + sym_cmd_size + dysym_cmd_size;

	/* Layout sections in vmaddr and fileoff */
	uint64_t file_pos = align_up((uint64_t)sizeof(MachHeader64) + sizeofcmds, 8);
	uint64_t seg_fileoff = file_pos;
	uint64_t vm_pos = 0;

	/* Non-zerofill sections first in fileoff, all active sections in vmaddr */
	for (size_t i = 0; i < M.nsecs; i++) {
		Sec *s = &M.secs[i];
		if (!s->out_sect_num)
			continue;
		uint64_t al = 1ULL << s->align_log2;
		vm_pos = align_up(vm_pos, al);
		s->vmaddr = vm_pos;
		uint64_t sz = sec_size(s);
		if (!s->is_zerofill) {
			uint64_t fal = al < 8 ? 8 : al;
			file_pos = align_up(file_pos, fal);
			s->fileoff = (uint32_t)file_pos;
			file_pos += sz;
		} else {
			s->fileoff = 0;
		}
		vm_pos += sz;
	}
	uint64_t seg_filesize = file_pos - seg_fileoff;
	uint64_t seg_vmsize = vm_pos;

	/* Layout relocations */
	for (size_t i = 0; i < M.nsecs; i++) {
		Sec *s = &M.secs[i];
		if (!s->out_sect_num || s->nrelocs == 0) {
			s->reloff = 0;
			continue;
		}
		file_pos = align_up(file_pos, 4);
		s->reloff = (uint32_t)file_pos;
		file_pos += s->nrelocs * sizeof(RelocInfo);
	}

	/* Sort symbols into locals, extdefs, undefs (preserving deterministic order) */
	uint32_t *order = emalloc((M.nsyms ? M.nsyms : 1) * sizeof *order);
	uint32_t *old_to_new = emalloc((M.nsyms ? M.nsyms : 1) * sizeof *old_to_new);
	uint32_t nlocal = 0, nextdef = 0, nundef = 0;
	uint32_t pos = 0;

	for (size_t i = 0; i < M.nsyms; i++) {
		if (M.syms[i].defined && !M.syms[i].is_export) {
			old_to_new[i] = pos;
			order[pos++] = (uint32_t)i;
			nlocal++;
		}
	}
	for (size_t i = 0; i < M.nsyms; i++) {
		if (M.syms[i].defined && M.syms[i].is_export) {
			old_to_new[i] = pos;
			order[pos++] = (uint32_t)i;
			nextdef++;
		}
	}
	for (size_t i = 0; i < M.nsyms; i++) {
		if (!M.syms[i].defined) {
			old_to_new[i] = pos;
			order[pos++] = (uint32_t)i;
			nundef++;
		}
	}

	/* Build string table and nlist_64 table */
	Buf strtab = { 0 };
	buf_put_u8(&strtab, 0); /* index 0 = "" */

	Nlist64 *nlists = emalloc((M.nsyms ? M.nsyms : 1) * sizeof *nlists);
	for (uint32_t ni = 0; ni < pos; ni++) {
		SymEnt *e = &M.syms[order[ni]];
		Nlist64 *nl = &nlists[ni];
		memset(nl, 0, sizeof *nl);
		nl->n_strx = (uint32_t)strtab.len;
		buf_put(&strtab, e->name, strlen(e->name) + 1);
		if (e->defined) {
			Sec *s = &M.secs[e->sec_idx];
			nl->n_type = (uint8_t)(N_SECT | (e->is_export ? N_EXT : 0));
			nl->n_sect = (uint8_t)s->out_sect_num;
			nl->n_desc = 0;
			nl->n_value = s->vmaddr + e->offset;
		} else if (e->is_common) {
			nl->n_type = N_UNDF | N_EXT;
			nl->n_sect = 0;
			nl->n_desc = (uint16_t)(e->common_align << 8);
			nl->n_value = e->offset;
		} else {
			nl->n_type = N_UNDF | N_EXT;
			nl->n_sect = 0;
			nl->n_desc = 0;
			nl->n_value = 0;
		}
	}
	while (strtab.len & 3u)
		buf_put_u8(&strtab, 0);

	file_pos = align_up(file_pos, 8);
	uint32_t symoff = (uint32_t)file_pos;
	file_pos += pos * sizeof(Nlist64);
	uint32_t stroff = (uint32_t)file_pos;

	/* Assemble output image in memory and write once */
	Buf out = { 0 };
	buf_reserve(&out, (size_t)(stroff + strtab.len));

	MachHeader64 hdr;
	memset(&hdr, 0, sizeof hdr);
	hdr.magic = MH_MAGIC_64;
	hdr.cputype = CPU_TYPE_ARM64;
	hdr.cpusubtype = CPU_SUBTYPE_ARM64_ALL;
	hdr.filetype = MH_OBJECT;
	hdr.ncmds = 4;
	hdr.sizeofcmds = sizeofcmds;
	hdr.flags = MH_SUBSECTIONS_VIA_SYMBOLS;
	buf_put(&out, &hdr, sizeof hdr);

	SegmentCmd64 seg;
	memset(&seg, 0, sizeof seg);
	seg.cmd = LC_SEGMENT_64;
	seg.cmdsize = seg_cmd_size;
	seg.vmaddr = 0;
	seg.vmsize = seg_vmsize;
	seg.fileoff = seg_fileoff;
	seg.filesize = seg_filesize;
	seg.maxprot = 7;
	seg.initprot = 7;
	seg.nsects = n_active;
	buf_put(&out, &seg, sizeof seg);

	for (size_t i = 0; i < M.nsecs; i++) {
		Sec *s = &M.secs[i];
		if (!s->out_sect_num)
			continue;
		Section64 sh;
		memset(&sh, 0, sizeof sh);
		memcpy(sh.sectname, s->sectname, 16);
		memcpy(sh.segname, s->segname, 16);
		sh.addr = s->vmaddr;
		sh.size = sec_size(s);
		sh.offset = s->fileoff;
		sh.align = s->align_log2;
		sh.reloff = s->reloff;
		sh.nreloc = (uint32_t)s->nrelocs;
		sh.flags = s->flags;
		buf_put(&out, &sh, sizeof sh);
	}

	BuildVerCmd bv;
	memset(&bv, 0, sizeof bv);
	bv.cmd = LC_BUILD_VERSION;
	bv.cmdsize = bv_cmd_size;
	bv.platform = PLATFORM_MACOS;
	bv.minos = M.macos_ver;
	bv.sdk = M.macos_ver;
	bv.ntools = 0;
	buf_put(&out, &bv, sizeof bv);

	SymtabCmd st;
	memset(&st, 0, sizeof st);
	st.cmd = LC_SYMTAB;
	st.cmdsize = sym_cmd_size;
	st.symoff = symoff;
	st.nsyms = pos;
	st.stroff = stroff;
	st.strsize = (uint32_t)strtab.len;
	buf_put(&out, &st, sizeof st);

	DysymtabCmd dst;
	memset(&dst, 0, sizeof dst);
	dst.cmd = LC_DYSYMTAB;
	dst.cmdsize = dysym_cmd_size;
	dst.ilocalsym = 0;
	dst.nlocalsym = nlocal;
	dst.iextdefsym = nlocal;
	dst.nextdefsym = nextdef;
	dst.iundefsym = nlocal + nextdef;
	dst.nundefsym = nundef;
	buf_put(&out, &dst, sizeof dst);

	/* Write section data */
	for (size_t i = 0; i < M.nsecs; i++) {
		Sec *s = &M.secs[i];
		if (!s->out_sect_num || s->is_zerofill)
			continue;
		if (out.len < s->fileoff)
			buf_put_zeros(&out, s->fileoff - out.len);
		buf_put(&out, s->buf.data, s->buf.len);
	}

	/* Write relocation tables */
	for (size_t i = 0; i < M.nsecs; i++) {
		Sec *s = &M.secs[i];
		if (!s->out_sect_num || s->nrelocs == 0)
			continue;
		if (out.len < s->reloff)
			buf_put_zeros(&out, s->reloff - out.len);
		for (size_t r = 0; r < s->nrelocs; r++) {
			Reloc *rel = &s->relocs[r];
			uint32_t snum = rel->is_extern ? old_to_new[rel->sym_idx] : rel->sym_idx;
			RelocInfo ri;
			ri.r_address = rel->offset;
			ri.r_info = pack_reloc_info(snum, rel->pcrel, rel->length, rel->is_extern, rel->type);
			buf_put(&out, &ri, sizeof ri);
		}
	}

	/* Write symbol table and string table */
	if (out.len < symoff)
		buf_put_zeros(&out, symoff - out.len);
	buf_put(&out, nlists, pos * sizeof(Nlist64));
	buf_put(&out, strtab.data, strtab.len);

	if (fwrite(out.data, 1, out.len, outf) != out.len)
		die("macho: failed to write object file");

	/* Cleanup */
	free(out.data);
	free(nlists);
	free(strtab.data);
	free(order);
	free(old_to_new);
	for (size_t i = 0; i < M.nsecs; i++) {
		free(M.secs[i].buf.data);
		free(M.secs[i].relocs);
	}
	free(M.secs);
	for (size_t i = 0; i < M.nsyms; i++)
		free(M.syms[i].name);
	free(M.syms);
	free(M.sym_ht);
	free(M.dat_name);
	free(M.dat_sec_str);
	free(M.dat_secf_str);
	memset(&M, 0, sizeof M);
}
