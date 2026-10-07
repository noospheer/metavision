// mv_shims.h — metavision's additions to Klepton's import resolver.
#ifndef MV_SHIMS_H
#define MV_SHIMS_H
#include <stddef.h>

typedef struct { const char *name; void *fn; } mv_entry;

extern const mv_entry mv_shim_table[];
extern const size_t   mv_shim_count;

// The name's implementation, or NULL. Answers only names in mv_shim_table.
void *mv_lookup(const char *name);
// Chain mv_lookup into kl_shim_override. Runs from a constructor; idempotent.
void  mv_shims_install(void);

#endif
