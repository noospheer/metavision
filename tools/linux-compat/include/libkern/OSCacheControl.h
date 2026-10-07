/* Linux stand-in: flush the instruction cache for a freshly written range. */
#ifndef MV_COMPAT_OSCACHECONTROL_H
#define MV_COMPAT_OSCACHECONTROL_H
#include <stddef.h>
static inline void sys_icache_invalidate(void *p, size_t n) {
    __builtin___clear_cache((char *)p, (char *)p + n);
}
#endif
