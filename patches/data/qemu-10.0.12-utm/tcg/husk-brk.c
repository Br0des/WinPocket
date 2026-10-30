/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * WinPocket -- the BreakpointJIT trap sequences, implemented in C.
 *
 * This is a C translation of Husk's husk-brk.S
 * (https://github.com/Leviidev/Husk, GPL-2.0-or-later). The original was
 * hand-written assembly because the C versions their first attempt relied on
 * __attribute__((naked, optnone)) could be reordered or elided by the
 * compiler. Here the same guarantee comes from binding the argument passing
 * registers explicitly with register variables: the values live in real
 * registers that the asm block reads and writes, so no naked attribute is
 * needed, and meson needs no assembler rules -- every toolchain that builds
 * this QEMU tree already compiles C.
 *
 * These three routines are the entire request channel to StikDebug. They are
 * reproduced from the documented wire protocol (brk immediate + x16 command
 * number) rather than linked from Stossy11's BreakpointJIT.framework, for
 * three reasons (as in Husk):
 *
 *   1. That framework ships as a bare binary with no stated license. This
 *      tree is GPL-2.0-or-later and cannot take on an unlicensed dynamic
 *      dependency.
 *   2. Embedding ANY framework that carries entitlements into a sideloaded
 *      app trips AMFI at launch ("has entitlements but is not a main
 *      binary"), which is why consumers of it must dlopen() lazily instead
 *      of linking. With the sequences compiled directly in, that whole class
 *      of problem disappears.
 *   3. Writing them explicitly guarantees the exact encoding.
 *
 * Verified by Husk against BreakpointJIT.framework
 * (com.stossy11.BreakpointJIT 1.0) via `otool -tV`, which disassembles in
 * full to:
 *
 *   _BreakGetJITMapping:  mov x16, #0x1 ; brk #0xf00d ; ret
 *   _BreakJITDetach:      mov x16, #0x0 ; brk #0xf00d ; ret
 *   _BreakMarkJITMapping: brk #0x69     ; ret
 *
 * Protocol (see StikDebug/Scripts/universal.js):
 *   brk #0xf00d dispatches on x16 -- 0 = detach, 1 = prepare region.
 *   Arguments arrive in x0/x1 and the result is written back into x0 before
 *   the debugger resumes us, so the asm block's output returns it.
 *   brk #0x69 is serviced by writing the constant 0xE0000069 into x0, which
 *   makes it a cheap "is StikDebug actually attached?" probe.
 *
 * If StikDebug is NOT attached, these brk instructions raise a real SIGTRAP.
 * husk_ios_jit_install_trap_handler() must be installed first so that
 * becomes a NULL return rather than process death. tcg/region.c installs it
 * itself before the first allocation, so a library-only user is covered.
 */

#include "husk-ios-jit.h"

#if defined(__arm64__) || defined(__aarch64__)

/*
 * void *husk_brk_get_jit_mapping(void *addr, size_t len);
 * x0 = addr (pass NULL to request a fresh region), x1 = len.
 * Returns the executable region address in x0, or 0 on failure.
 */
HUSK_EXPORT void *husk_brk_get_jit_mapping(void *addr, size_t len)
{
    register void *arg0 __asm__("x0") = addr;
    register size_t arg1 __asm__("x1") = len;
    __asm__ volatile (
        "mov x16, #1\n\t"        /* CMD_PREPARE_REGION */
        "brk #0xf00d\n\t"
        : "+r" (arg0)
        : "r" (arg1)
        : "x16", "memory"
    );
    return arg0;
}

/* void husk_brk_jit_detach(void); */
HUSK_EXPORT void husk_brk_jit_detach(void)
{
    __asm__ volatile (
        "mov x16, #0\n\t"        /* CMD_DETACH */
        "brk #0xf00d"
    );
}

/* uint64_t husk_brk_probe(void);
 * Returns 0xE0000069 (or a byte-reversed variant) when StikDebug is attached
 * and servicing traps; our SIGTRAP handler turns an unanswered brk into 0. */
HUSK_EXPORT uint64_t husk_brk_probe(void)
{
    register uint64_t arg0 __asm__("x0") = 0;
    __asm__ volatile (
        "brk #0x69"
        : "+r" (arg0)
        :
        : "x16", "memory"
    );
    return arg0;
}

#else /* !aarch64 -- non-iOS host builds and tests still link */

HUSK_EXPORT void *husk_brk_get_jit_mapping(void *addr, size_t len)
{
    (void)addr; (void)len;
    return NULL;
}

HUSK_EXPORT void husk_brk_jit_detach(void) {}

HUSK_EXPORT uint64_t husk_brk_probe(void) { return 0; }

#endif /* aarch64 */
