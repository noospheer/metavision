/* Minimal Mach-O definitions so klepton-ld builds on Linux.
 * Only what tools/klepton_ld.c and its sources use; layouts and values are the
 * published Mach-O file format (64-bit, little-endian). Not Apple's header. */
#ifndef MV_COMPAT_MACHO_LOADER_H
#define MV_COMPAT_MACHO_LOADER_H
#include <stdint.h>

typedef int32_t cpu_type_t;
typedef int32_t cpu_subtype_t;
typedef int32_t vm_prot_t;

#define CPU_ARCH_ABI64        0x01000000
#define CPU_TYPE_ARM          12
#define CPU_TYPE_ARM64        (CPU_TYPE_ARM | CPU_ARCH_ABI64)
#define CPU_SUBTYPE_ARM64_ALL 0

#define VM_PROT_NONE    0x0
#define VM_PROT_READ    0x1
#define VM_PROT_WRITE   0x2
#define VM_PROT_EXECUTE 0x4

struct mach_header_64 {
    uint32_t      magic;
    cpu_type_t    cputype;
    cpu_subtype_t cpusubtype;
    uint32_t      filetype;
    uint32_t      ncmds;
    uint32_t      sizeofcmds;
    uint32_t      flags;
    uint32_t      reserved;
};
#define MH_MAGIC_64  0xfeedfacf
#define MH_DYLIB     0x6
#define MH_NOUNDEFS  0x1
#define MH_DYLDLINK  0x4
#define MH_TWOLEVEL  0x80

struct load_command { uint32_t cmd, cmdsize; };
#define LC_SYMTAB             0x2
#define LC_DYSYMTAB           0xb
#define LC_LOAD_DYLIB         0xc
#define LC_ID_DYLIB           0xd
#define LC_SEGMENT_64         0x19
#define LC_UUID               0x1b
#define LC_ENCRYPTION_INFO_64 0x2c
#define LC_BUILD_VERSION      0x32

union lc_str { uint32_t offset; };

struct segment_command_64 {
    uint32_t  cmd, cmdsize;
    char      segname[16];
    uint64_t  vmaddr, vmsize, fileoff, filesize;
    vm_prot_t maxprot, initprot;
    uint32_t  nsects, flags;
};

struct section_64 {
    char     sectname[16];
    char     segname[16];
    uint64_t addr, size;
    uint32_t offset, align, reloff, nreloc, flags;
    uint32_t reserved1, reserved2, reserved3;
};
#define S_REGULAR                0x0
#define S_ATTR_PURE_INSTRUCTIONS 0x80000000
#define S_ATTR_SOME_INSTRUCTIONS 0x00000400

struct dylib {
    union lc_str name;
    uint32_t     timestamp, current_version, compatibility_version;
};
struct dylib_command { uint32_t cmd, cmdsize; struct dylib dylib; };

struct symtab_command { uint32_t cmd, cmdsize, symoff, nsyms, stroff, strsize; };

struct dysymtab_command {
    uint32_t cmd, cmdsize;
    uint32_t ilocalsym, nlocalsym, iextdefsym, nextdefsym, iundefsym, nundefsym;
    uint32_t tocoff, ntoc, modtaboff, nmodtab, extrefsymoff, nextrefsyms;
    uint32_t indirectsymoff, nindirectsyms, extreloff, nextrel, locreloff, nlocrel;
};

struct uuid_command { uint32_t cmd, cmdsize; uint8_t uuid[16]; };

struct build_version_command { uint32_t cmd, cmdsize, platform, minos, sdk, ntools; };
#define PLATFORM_MACOS        1
#define PLATFORM_IOS          2
#define PLATFORM_IOSSIMULATOR 7
#define PLATFORM_VISIONOS     11

struct encryption_info_command_64 { uint32_t cmd, cmdsize, cryptoff, cryptsize, cryptid, pad; };

#endif
