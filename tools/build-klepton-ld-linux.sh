#!/usr/bin/env bash
# Build vendor/klepton's translator (klepton-ld) on a Linux host.
#
# Upstream builds it on Apple silicon only. Two things stand in the way here,
# and neither touches what the translator computes:
#   * Mach-O headers: tools/linux-compat/include supplies the published layouts.
#   * kl_x18.c reads TPIDRRO_EL0 in kl_x18_init(), a runtime-only path (claiming
#     the guest's TSD slot in a live process). On a non-arm64 host that read is
#     replaced in a build-dir copy; the submodule is never modified.
#
# usage: tools/build-klepton-ld-linux.sh [out-dir]    (default: build/)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
K="$ROOT/vendor/klepton"
OUT=${1:-"$ROOT/build"}
GEN="$OUT/klepton-ld-src"
mkdir -p "$OUT" "$GEN"

x18="$K/runtime/kl_x18.c"
if [ "$(uname -m)" != "aarch64" ]; then
    # Only the one asm statement; fail loudly if upstream changes it.
    grep -q '__asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));' "$x18" ||
        { echo "kl_x18.c changed upstream: re-check the TPIDRRO_EL0 substitution" >&2; exit 1; }
    sed 's|__asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));|(void)tp; return -1; /* linux host: no guest TSD to claim */|' \
        "$x18" > "$GEN/kl_x18.c"
    x18="$GEN/kl_x18.c"
fi

${CC:-gcc} -O2 -D_GNU_SOURCE -Wno-format-truncation \
    -I "$ROOT/tools/linux-compat/include" -I "$K/runtime" -pthread \
    -o "$OUT/klepton-ld" \
    "$K/tools/klepton_ld.c" "$x18" "$K/runtime/kl_env.c" "$K/runtime/guest/kl_guestpatch.c"
echo "$OUT/klepton-ld"
