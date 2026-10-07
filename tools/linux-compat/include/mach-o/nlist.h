/* Minimal nlist_64 for klepton-ld on Linux (published Mach-O layout). */
#ifndef MV_COMPAT_MACHO_NLIST_H
#define MV_COMPAT_MACHO_NLIST_H
#include <stdint.h>
struct nlist_64 {
    union { uint32_t n_strx; } n_un;
    uint8_t  n_type;
    uint8_t  n_sect;
    uint16_t n_desc;
    uint64_t n_value;
};
#define N_UNDF 0x0
#define N_EXT  0x01
#define N_TYPE 0x0e
#define N_SECT 0xe
#endif
