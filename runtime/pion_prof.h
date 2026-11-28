#ifndef PION_PROF_H
#define PION_PROF_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Profile mode bitmask (shared with compiler/CLI/Wasm32) */
#define PION_PROF_NONE  0u
#define PION_PROF_CPU   1u
#define PION_PROF_ALLOC 2u
#define PION_PROF_RC    4u
#define PION_PROF_ALL   7u

/* Compiled capability bitmask (weakly defined in pion_prof.c as PION_PROF_ALL;
 * binaries compiled with inline RC may override to PION_PROF_CPU | PION_PROF_ALLOC). */
extern uint32_t pion_prof_build_modes;

/* Public profiler lifecycle & bench window API */
void pion_prof_anchor(void);
void pion_prof_init(void);
void pion_prof_flush(void);
void pion_prof_pause(void);
void pion_prof_resume(void);
void pion_prof_reset(void);
void pion_prof_thread_init(void);

/* Internal runtime hooks (invoked from pion_rt.c only under #ifdef PION_PROF) */
void pion_prof_on_alloc(void *obj, uint32_t payload_size, size_t alloc_bytes,
                        uint16_t type_tag, void *drop_fn, int is_large);
void pion_prof_on_retire(void *obj, size_t alloc_bytes, uint16_t type_tag,
                         void *drop_fn, int is_large);
void pion_prof_on_backing_alloc(void *ptr, size_t bytes);
void pion_prof_on_backing_free(void *ptr, size_t bytes);
void pion_prof_on_backing_realloc(int had_old, size_t old_bytes,
                                  void *new_ptr, size_t new_bytes);
void pion_prof_on_reserved_add(size_t bytes);
void pion_prof_on_reserved_sub(size_t bytes);
void pion_prof_on_rc_inc(uint16_t type_tag, int is_atomic, int is_immortal);
void pion_prof_on_rc_dec(uint16_t type_tag, int is_atomic, int is_immortal);
void pion_prof_on_rc_destroy(uint16_t type_tag);
void pion_prof_on_rc_freeze(uint16_t type_tag, int is_immortal);

#ifdef __cplusplus
}
#endif

#endif /* PION_PROF_H */
