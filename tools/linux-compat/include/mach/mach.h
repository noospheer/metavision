/* Linux stand-ins for the three Mach VM calls kl_x18.c makes. klepton-ld only
 * links them; the veneer allocator they serve runs inside the Darwin runtime. */
#ifndef MV_COMPAT_MACH_H
#define MV_COMPAT_MACH_H
#include <stdint.h>
#include <sys/mman.h>
#include <mach-o/loader.h>
typedef int       kern_return_t;
typedef uintptr_t vm_address_t;
typedef uintptr_t vm_size_t;
typedef unsigned  mach_port_t;
#define KERN_SUCCESS   0
#define KERN_NO_SPACE  3
#define VM_FLAGS_FIXED 0x0
static inline mach_port_t mach_task_self(void) { return 0; }
static inline kern_return_t vm_allocate(mach_port_t t, vm_address_t *a, vm_size_t n, int f) {
    (void)t; (void)f;
    void *p = mmap((void *)*a, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (p == MAP_FAILED) return KERN_NO_SPACE;
    *a = (vm_address_t)p; return KERN_SUCCESS;
}
static inline kern_return_t vm_deallocate(mach_port_t t, vm_address_t a, vm_size_t n) {
    (void)t; return munmap((void *)a, n) ? KERN_NO_SPACE : KERN_SUCCESS;
}
#endif
