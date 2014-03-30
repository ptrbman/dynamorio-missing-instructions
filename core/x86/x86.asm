/* **********************************************************
 * Copyright (c) 2011-2014 Google, Inc.  All rights reserved.
 * Copyright (c) 2001-2010 VMware, Inc.  All rights reserved.
 * ********************************************************** */

/*
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * * Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 *
 * * Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 *
 * * Neither the name of VMware, Inc. nor the names of its contributors may be
 *   used to endorse or promote products derived from this software without
 *   specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL VMWARE, INC. OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */

/* Copyright (c) 2003-2007 Determina Corp. */
/* Copyright (c) 2001-2003 Massachusetts Institute of Technology */
/* Copyright (c) 2001 Hewlett-Packard Company */

/*
 * x86.asm - x86 specific assembly and trampoline code
 *
 * This file is used for both linux and windows.
 * We used to use the gnu assembler on both platforms, but
 * gas does not support 64-bit windows.
 * Thus we now use masm on windows and gas with the new intel-syntax-specifying
 * options so that our code here only needs a minimum of macros to
 * work on both.
 *
 * Note that for gas on cygwin we used to need to prepend _ to global
 * symbols: we don't need that for linux gas or masm so we don't do it anymore.
 */

/* We handle different registers and calling conventions with a CPP pass.
 * It can be difficult to choose registers that work across all ABI's we're
 * trying to support: we need to move each ARG into a register in case
 * it is passed in memory, but we have to pick registers that don't already
 * hold other arguments.  Typically, use this order:
 *   REG_XAX, REG_XBX, REG_XDI, REG_XSI, REG_XDX, REG_XCX
 * Note that REG_XBX is by convention used on linux for PIC base: if we want
 * to try and avoid relocations (case 7852) we should avoid using it
 * to avoid confusion (though we can always pick a different register,
 * even varying by function).
 * FIXME: should we use virtual registers instead?
 * FIXME: should we have ARG1_IN_REG macro that is either nop or load from stack?
 * For now not bothering, but if we add more routines we'll want more support.
 * Naturally the ARG* macros are only valid at function entry.
 */

#include "asm_defines.asm"
START_FILE

#ifdef UNIX
# ifdef LINUX
#  include "include/syscall.h"
# else
#  include <sys/syscall.h>
# endif
#endif

#define RESTORE_FROM_DCONTEXT_VIA_REG(reg,offs,dest) mov dest, PTRSZ [offs + reg]
#define SAVE_TO_DCONTEXT_VIA_REG(reg,offs,src) mov PTRSZ [offs + reg], src

/* For the few remaining dcontext_t offsets we need here: */
#if defined(WINDOWS) && !defined(X64)
# define UPCXT_BEFORE_INLINE_SLOTS 4  /* at_syscall + padding */
#else
# define UPCXT_BEFORE_INLINE_SLOTS 8  /* IF_UNIX(errno +) at_syscall + padding */
#endif

/* Count the slots for client clean call inlining. */
#ifdef CLIENT_INTERFACE
/* Add CLEANCALL_NUM_INLINE_SLOTS(5) * ARG_SZ for these slots.  No padding. */
# define UPCXT_EXTRA (UPCXT_BEFORE_INLINE_SLOTS + 5 * ARG_SZ)
#else
# define UPCXT_EXTRA UPCXT_BEFORE_INLINE_SLOTS
#endif

/* We should give asm_defines.asm all unique names and then include globals.h
 * and avoid all this duplication!
 */
#ifdef X64
# ifdef WINDOWS
#  define NUM_XMM_SLOTS 6 /* xmm0-5 */
# else
#  define NUM_XMM_SLOTS 16 /* xmm0-15 */
# endif
# define PRE_XMM_PADDING 16
#else
# define NUM_XMM_SLOTS 8 /* xmm0-7 */
# define PRE_XMM_PADDING 24
#endif
#define XMM_SAVED_REG_SIZE 32 /* for ymm */
/* xmm0-5/7/15 for PR 264138/i#139/PR 302107 */
#define XMM_SAVED_SIZE ((NUM_XMM_SLOTS)*(XMM_SAVED_REG_SIZE))

/* Should we generate all of our asm code instead of having it static?
 * As it is we're duplicating insert_push_all_registers(), dr_insert_call(), etc.,
 * but it's not that much code here in these macros, and this is simpler
 * than emit_utils.c-style code.
 */
#ifdef X64
/* push GPR registers in priv_mcontext_t order.  does NOT make xsp have a
 * pre-push value as no callers need that (they all use PUSH_PRIV_MCXT).
 * Leaves space for, but does NOT fill in, the xmm0-5 slots (PR 264138),
 * since it's hard to dynamically figure out during bootstrapping whether
 * movdqu or movups are legal instructions.  The caller is expected
 * to fill in the xmm values prior to any calls that may clobber them.
 */
# define PUSHGPR \
        push     r15 @N@\
        push     r14 @N@\
        push     r13 @N@\
        push     r12 @N@\
        push     r11 @N@\
        push     r10 @N@\
        push     r9  @N@\
        push     r8  @N@\
        push     rax @N@\
        push     rcx @N@\
        push     rdx @N@\
        push     rbx @N@\
        /* not the pusha pre-push rsp value but see above */ @N@\
        push     rsp @N@\
        push     rbp @N@\
        push     rsi @N@\
        push     rdi
# define POPGPR        \
        pop      rdi @N@\
        pop      rsi @N@\
        pop      rbp @N@\
        pop      rbx /* rsp into dead rbx */ @N@\
        pop      rbx @N@\
        pop      rdx @N@\
        pop      rcx @N@\
        pop      rax @N@\
        pop      r8  @N@\
        pop      r9  @N@\
        pop      r10 @N@\
        pop      r11 @N@\
        pop      r12 @N@\
        pop      r13 @N@\
        pop      r14 @N@\
        pop      r15 @N@
# define PRIV_MCXT_SIZE (18*ARG_SZ + PRE_XMM_PADDING + XMM_SAVED_SIZE)
# define dstack_OFFSET     (PRIV_MCXT_SIZE+UPCXT_EXTRA+3*ARG_SZ)
# define MCONTEXT_PC_OFFS  (17*ARG_SZ)
#else
# define PUSHGPR \
        pusha
# define POPGPR  \
        popa
# define PRIV_MCXT_SIZE (10*ARG_SZ + PRE_XMM_PADDING + XMM_SAVED_SIZE)
# define dstack_OFFSET     (PRIV_MCXT_SIZE+UPCXT_EXTRA+3*ARG_SZ)
# define MCONTEXT_PC_OFFS  (9*ARG_SZ)
#endif
/* offsetof(dcontext_t, is_exiting) */
#define is_exiting_OFFSET (dstack_OFFSET+1*ARG_SZ)
#define PUSHGPR_XSP_OFFS  (3*ARG_SZ)
#define MCONTEXT_XSP_OFFS (PUSHGPR_XSP_OFFS)
#define PUSH_PRIV_MCXT_PRE_PC_SHIFT (- XMM_SAVED_SIZE - PRE_XMM_PADDING)

/* Pushes a priv_mcontext_t on the stack, with an xsp value equal to the
 * xsp before the pushing.  Clobbers xax!
 * Does fill in xmm0-5, if necessary, for PR 264138.
 * Assumes that DR has been initialized (get_xmm_vals() checks proc feature bits).
 * Caller should ensure 16-byte stack alignment prior to the push (PR 306421).
 */
#define PUSH_PRIV_MCXT(pc)                              \
        lea      REG_XSP, [REG_XSP + PUSH_PRIV_MCXT_PRE_PC_SHIFT]  @N@\
        push     pc                                    @N@\
        PUSHF                                          @N@\
        PUSHGPR                                        @N@\
        lea      REG_XAX, [REG_XSP]                    @N@\
        CALLC1(GLOBAL_REF(get_xmm_vals), REG_XAX)      @N@\
        lea      REG_XAX, [PRIV_MCXT_SIZE + REG_XSP]   @N@\
        mov      [PUSHGPR_XSP_OFFS + REG_XSP], REG_XAX

/* Pops the GPRs and flags from a priv_mcontext off the stack.  Does not
 * restore xmm/ymm regs.
 */
#define POP_PRIV_MCXT_GPRS() \
        POPGPR                                          @N@\
        POPF                                            @N@\
        lea      REG_XSP, [REG_XSP - PUSH_PRIV_MCXT_PRE_PC_SHIFT + ARG_SZ/*pc*/]

/* This is really the alignment needed by x64 code.  For now, when we bother to
 * align the stack pointer, we just go for 16 byte alignment.  We do *not*
 * assume 16-byte alignment across the code base.
 * i#847: Investigate using aligned SSE ops (see get_xmm_caller_saved).
 */
#define FRAME_ALIGNMENT 16

/****************************************************************************/
/****************************************************************************/
#ifndef NOT_DYNAMORIO_CORE_PROPER

DECL_EXTERN(get_own_context_integer_control)
DECL_EXTERN(get_xmm_vals)
DECL_EXTERN(auto_setup)
DECL_EXTERN(return_from_native)
DECL_EXTERN(native_module_callout)
DECL_EXTERN(dispatch)
#ifdef DR_APP_EXPORTS
DECL_EXTERN(dr_app_start_helper)
#endif
DECL_EXTERN(dynamo_process_exit)
DECL_EXTERN(dynamo_thread_exit)
DECL_EXTERN(dynamo_thread_stack_free_and_exit)
DECL_EXTERN(dynamorio_app_take_over_helper)
DECL_EXTERN(found_modified_code)
DECL_EXTERN(get_cleanup_and_terminate_global_do_syscall_entry)
#ifdef INTERNAL
DECL_EXTERN(internal_error)
#endif
DECL_EXTERN(internal_exception_info)
DECL_EXTERN(is_currently_on_dstack)
DECL_EXTERN(nt_continue_setup)
#if defined(UNIX)
DECL_EXTERN(master_signal_handler_C)
#endif
#ifdef MACOS
DECL_EXTERN(new_bsdthread_setup)
#endif
DECL_EXTERN(hashlookup_null_target)
#if defined(UNIX) && !defined(HAVE_SIGALTSTACK)
DECL_EXTERN(sig_should_swap_stack)
DECL_EXTERN(fixup_rtframe_pointers)
# define CLONE_AND_SWAP_STRUCT_SIZE 2*ARG_SZ
#endif
#ifdef UNIX
DECL_EXTERN(dr_setjmp_sigmask)
DECL_EXTERN(privload_early_inject)
DECL_EXTERN(dynamorio_dl_fixup)
#endif
#ifdef WINDOWS
DECL_EXTERN(dynamorio_earliest_init_takeover_C)
DECL_EXTERN(os_terminate_wow64_stack)
#endif

/* non-functions: these make us non-PIC! (PR 212290) */
DECL_EXTERN(exiting_thread_count)
DECL_EXTERN(initstack)
DECL_EXTERN(initstack_mutex)
DECL_EXTERN(int_syscall_address)
DECL_EXTERN(syscalls)
DECL_EXTERN(sysenter_ret_address)
DECL_EXTERN(sysenter_tls_offset)
#ifdef WINDOWS
DECL_EXTERN(wow64_index)
# ifdef X64
DECL_EXTERN(syscall_argsz)
# endif
#endif


#ifdef WINDOWS
/* dynamo_auto_start: used for non-early follow children.
 * Assumptions: The saved priv_mcontext_t for the start of the app is on
 * the stack, followed by a pointer to a region of memory to free
 * (which can be NULL) and its size.  This routine is reached by a jmp
 * so be aware of that for address calculation. This routine does
 * not return.
 *
 * On win32, note that in order to export this from the dynamo dll, which is
 * required for non early follow children, we have to explicitly tell the
 * linker to do so.  This is done in the Makefile.
 * Note that if it weren't for wanting local go-native code we would have
 * auto_setup in x86_code.c be dynamo_auto_start.
 */
        DECLARE_FUNC(dynamo_auto_start)
GLOBAL_LABEL(dynamo_auto_start:)
        /* we pass a pointer to TOS as a parameter.
         * a param in xsp won't work w/ win64 padding so put in xax */
        mov      REG_XAX, REG_XSP
        CALLC1(GLOBAL_REF(auto_setup), REG_XAX)
        /* if auto_setup returns, we need to go native */
        jmp      load_dynamo_failure
        END_FUNC(dynamo_auto_start)
#endif

#ifdef UNIX
/* We avoid performance problems with messing up the RSB by using
 * a separate routine.  The caller needs to use a plain call
 * with _GLOBAL_OFFSET_TABLE_ on the exact return address instruction.
 */
        DECLARE_FUNC(get_pic_xax)
GLOBAL_LABEL(get_pic_xax:)
        mov      REG_XAX, PTRSZ [REG_XSP]
        ret
        END_FUNC(get_pic_xax)

        DECLARE_FUNC(get_pic_xdi)
GLOBAL_LABEL(get_pic_xdi:)
        mov      REG_XDI, PTRSZ [REG_XSP]
        ret
        END_FUNC(get_pic_xdi)
#endif

/*
 * Calls the specified function 'func' after switching to the stack 'stack'.  If we're
 * currently on the initstack 'free_initstack' should be set so we release the
 * initstack lock.  The supplied 'dcontext' will be passed as an argument to 'func'.
 * If 'func' returns then 'return_on_return' is checked. If set we swap back stacks and
 * return to the caller.  If not set then it's assumed that func wasn't supposed to
 * return and we go to an error routine unexpected_return() below.
 *
 * void call_switch_stack(dcontext_t *dcontext,       // 1*ARG_SZ+XAX
 *                        byte *stack,                // 2*ARG_SZ+XAX
 *                        void (*func)(dcontext_t *), // 3*ARG_SZ+XAX
 *                        bool free_initstack,        // 4*ARG_SZ+XAX
 *                        bool return_on_return)      // 5*ARG_SZ+XAX
 */
        DECLARE_FUNC(call_switch_stack)
GLOBAL_LABEL(call_switch_stack:)
        /* get all args with same offset(xax) regardless of plaform */
#ifdef X64
# ifdef WINDOWS
        mov      REG_XAX, REG_XSP
        /* stack alignment doesn't really matter (b/c we're swapping) but in case
         * we add a call we keep this here
         */
        lea      REG_XSP, [-ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
# else
        /* no padding so we make our own space. odd #slots keeps align-16 w/ retaddr */
        lea      REG_XSP, [-5*ARG_SZ + REG_XSP]
        /* xax points one beyond TOS to get same offset as having retaddr there */
        lea      REG_XAX, [-ARG_SZ + REG_XSP]
        mov      [5*ARG_SZ + REG_XAX], ARG5
# endif
        mov      [1*ARG_SZ + REG_XAX], ARG1
        mov      [2*ARG_SZ + REG_XAX], ARG2
        mov      [3*ARG_SZ + REG_XAX], ARG3
        mov      [4*ARG_SZ + REG_XAX], ARG4
#else
        /* stack alignment doesn't matter */
        mov      REG_XAX, REG_XSP
#endif
        /* we need a callee-saved reg across our call so save it onto stack */
        push     REG_XBX
        push     REG_XDI /* alignment doesn't matter: swapping stacks */
        mov      REG_XBX, REG_XAX
        mov      REG_XDI, REG_XSP
        /* set up for call */
        mov      REG_XDX, [3*ARG_SZ + REG_XAX] /* func */
        mov      REG_XCX, [1*ARG_SZ + REG_XAX] /* dcontext */
        mov      REG_XSP, [2*ARG_SZ + REG_XAX] /* stack */
        cmp      BYTE [4*ARG_SZ + REG_XAX], 0 /* free_initstack */
        je       call_dispatch_alt_stack_no_free
#if !defined(X64) && defined(LINUX)
        /* PR 212290: avoid text relocations: get PIC base into xax
         * Can't use CALLC0 since it inserts a nop: we need the exact retaddr.
         */
        call     get_pic_xax
        lea      REG_XAX, [_GLOBAL_OFFSET_TABLE_ + REG_XAX]
        lea      REG_XAX, VAR_VIA_GOT(REG_XAX, GLOBAL_REF(initstack_mutex))
        mov      DWORD [REG_XAX], 0
#else
        mov      DWORD SYMREF(initstack_mutex), 0 /* rip-relative on x64 */
#endif
call_dispatch_alt_stack_no_free:
        CALLC1(REG_XDX, REG_XCX)
        mov      REG_XSP, REG_XDI
        mov      REG_XAX, REG_XBX
        cmp      BYTE [5*ARG_SZ + REG_XAX], 0 /* return_on_return */
        je       GLOBAL_REF(unexpected_return)
        pop      REG_XDI
        pop      REG_XBX
#ifdef X64
# ifdef WINDOWS
        mov      REG_XSP, REG_XAX
# else
        lea      REG_XSP, [5*ARG_SZ + REG_XSP]
# endif
#else
        mov      REG_XSP, REG_XAX
#endif
        ret
        END_FUNC(call_switch_stack)

/*
 * Copies from the current xsp to tos onto the base of stack and then
 * swaps to the cloned top of stack.
 *
 * void clone_and_swap_stack(byte *stack, byte *tos)
 */
        DECLARE_FUNC(clone_and_swap_stack)
GLOBAL_LABEL(clone_and_swap_stack:)
        mov      REG_XAX, ARG1
        mov      REG_XCX, ARG2
        mov      REG_XDX, REG_XSP
        /* save not-always-caller-saved regs */
        push     REG_XSI
        push     REG_XDI
        /* memcpy(stack - sz, cur_esp, sz) */
        sub      REG_XCX, REG_XDX /* sz = tos - cur_esp */
        mov      REG_XSI, REG_XDX /* source = tos */
        mov      REG_XDI, REG_XAX /* dest = stack - sz */
        sub      REG_XDI, REG_XCX
        sub      REG_XAX, REG_XCX /* before lose sz, calculate tos on stack */
        /* cld from signal handler for app signal should be ok */
        cld
        rep movsb
        /* restore and swap to cloned stack */
        pop      REG_XDI
        pop      REG_XSI
        mov      REG_XSP, REG_XAX
        ret
        END_FUNC(clone_and_swap_stack)

/*
 * dr_app_start - Causes application to run under Dynamo control
 */
#ifdef DR_APP_EXPORTS
        DECLARE_EXPORTED_FUNC(dr_app_start)
GLOBAL_LABEL(dr_app_start:)
        sub     REG_XSP, FRAME_ALIGNMENT - ARG_SZ  /* Maintain alignment. */

        /* grab exec state and pass as param in a priv_mcontext_t struct */
        PUSH_PRIV_MCXT(PTRSZ [FRAME_ALIGNMENT - ARG_SZ + REG_XSP -
                        PUSH_PRIV_MCXT_PRE_PC_SHIFT]) /* return address as pc */

        /* do the rest in C */
        lea     REG_XAX, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */
        CALLC1(GLOBAL_REF(dr_app_start_helper), REG_XAX)

        /* if we come back, then DR is not taking control so
         * clean up stack and return */
        add      REG_XSP, PRIV_MCXT_SIZE + FRAME_ALIGNMENT - ARG_SZ
        ret
        END_FUNC(dr_app_start)

/*
 * dr_app_take_over - For the client interface, we'll export 'dr_app_take_over'
 * for consistency with the dr_ naming convention of all exported functions.
 * We'll keep 'dynamorio_app_take_over' for compatibility with the preinjector.
 */
        DECLARE_EXPORTED_FUNC(dr_app_take_over)
GLOBAL_LABEL(dr_app_take_over:  )
        jmp      GLOBAL_REF(dynamorio_app_take_over)
        END_FUNC(dr_app_take_over)

/* dr_app_running_under_dynamorio - Indicates whether the current thread
 * is running within the DynamoRIO code cache.
 * Returns false (not under dynamorio) by default.
 * The function is mangled by dynamorio to return true instead when
 * it is brought into the code cache.
 */
        DECLARE_EXPORTED_FUNC(dr_app_running_under_dynamorio)
GLOBAL_LABEL(dr_app_running_under_dynamorio: )
        mov      eax, 0
        ret
        END_FUNC(dr_app_running_under_dynamorio)
#endif

/*
 * dynamorio_app_take_over - Causes application to run under Dynamo
 * control.  Dynamo never releases control.
 */
        DECLARE_EXPORTED_FUNC(dynamorio_app_take_over)
GLOBAL_LABEL(dynamorio_app_take_over:)
        sub     REG_XSP, FRAME_ALIGNMENT - ARG_SZ  /* Maintain alignment. */

        /* grab exec state and pass as param in a priv_mcontext_t struct */
        PUSH_PRIV_MCXT(PTRSZ [FRAME_ALIGNMENT - ARG_SZ + REG_XSP -
                        PUSH_PRIV_MCXT_PRE_PC_SHIFT]) /* return address as pc */

        /* do the rest in C */
        lea      REG_XAX, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */
        CALLC1(GLOBAL_REF(dynamorio_app_take_over_helper), REG_XAX)

        /* if we come back, then DR is not taking control so
         * clean up stack and return */
        add      REG_XSP, PRIV_MCXT_SIZE + FRAME_ALIGNMENT - ARG_SZ
        ret
        END_FUNC(dynamorio_app_take_over)

/*
 * cleanup_and_terminate(dcontext_t *dcontext,     // 1*ARG_SZ+XBP
 *                       int sysnum,               // 2*ARG_SZ+XBP = syscall #
 *                       int sys_arg1/param_base,  // 3*ARG_SZ+XBP = arg1 for syscall
 *                       int sys_arg2,             // 4*ARG_SZ+XBP = arg2 for syscall
 *                       bool exitproc)            // 5*ARG_SZ+XBP
 *
 * Calls dynamo_exit_process if exitproc is true, else calls dynamo_exit_thread.
 * Uses the current dstack, but instructs the cleanup routines not to
 * de-allocate it, does a custom de-allocate after swapping to initstack (don't
 * want to use initstack the whole time, that's too long to hold the mutex).
 * Then calls system call sysnum with parameter base param_base, which is presumed
 * to be either NtTerminateThread or NtTerminateProcess or exit.
 * For x64 Windows, args are in ecx and edx (terminate syscalls have only 2 args).
 * For x64 Linux, 1st 2 args are in rdi and rsi.
 *
 * Note that the caller is responsible for placing the actual syscall arguments
 * at the correct offset from edx (or ebx).  See SYSCALL_PARAM_OFFSET in
 * win32 os.c for more info.
 *
 * Note that this routine does not return and thus clobbers callee-saved regs.
 */
        DECLARE_FUNC(cleanup_and_terminate)
GLOBAL_LABEL(cleanup_and_terminate:)
        /* get all args with same offset(xbp) regardless of plaform, to save
         * across our calls.
         */
#ifdef X64
# ifdef WINDOWS
        mov      REG_XBP, REG_XSP
        lea      REG_XSP, [-ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
# else
        /* no padding so we make our own space. odd #slots keeps align-16 w/ retaddr */
        lea      REG_XSP, [-5*ARG_SZ + REG_XSP]
        /* xbp points one beyond TOS to get same offset as having retaddr there */
        lea      REG_XBP, [-ARG_SZ + REG_XSP]
        mov      [5*ARG_SZ + REG_XBP], ARG5
# endif
        mov      [1*ARG_SZ + REG_XBP], ARG1
        mov      [2*ARG_SZ + REG_XBP], ARG2
        mov      [3*ARG_SZ + REG_XBP], ARG3
        mov      [4*ARG_SZ + REG_XBP], ARG4
#else
        mov      REG_XBP, REG_XSP
# if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [-3*ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
# endif
#endif
        /* increment exiting_thread_count so that we don't get killed after
         * thread_exit removes us from the all_threads list */
#if !defined(X64) && defined(LINUX)
        /* PR 212290: avoid text relocations: get PIC base into callee-saved xdi.
         * Can't use CALLC0 since it inserts a nop: we need the exact retaddr.
         */
        call     get_pic_xdi
        lea      REG_XDI, [_GLOBAL_OFFSET_TABLE_ + REG_XDI]
        lea      REG_XAX, VAR_VIA_GOT(REG_XDI, GLOBAL_REF(exiting_thread_count))
        lock inc DWORD [REG_XAX]
#else
        lock inc DWORD SYMREF(exiting_thread_count) /* rip-rel for x64 */
#endif
        /* save dcontext->dstack for freeing later and set dcontext->is_exiting */
        /* xbx is callee-saved and not an x64 param so we can use it */
        mov      REG_XBX, PTRSZ [1*ARG_SZ + REG_XBP] /* dcontext */
        SAVE_TO_DCONTEXT_VIA_REG(REG_XBX,is_exiting_OFFSET,1)
        CALLC1(GLOBAL_REF(is_currently_on_dstack), REG_XBX) /* xbx is callee-saved */
        cmp      REG_XAX, 0
        jnz      cat_save_dstack
        mov      REG_XBX, 0 /* save 0 for dstack to avoid double-free */
        jmp      cat_done_saving_dstack
cat_save_dstack:
        RESTORE_FROM_DCONTEXT_VIA_REG(REG_XBX,dstack_OFFSET,REG_XBX)
cat_done_saving_dstack:
        /* PR 306421: xbx is callee-saved for all platforms, so don't push yet,
         * to maintain 16-byte stack alignment
         */
        /* avoid sygate sysenter version as our stack may be static const at
         * that point, caller will take care of sygate hack */
        CALLC0(GLOBAL_REF(get_cleanup_and_terminate_global_do_syscall_entry))
#if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [-2*ARG_SZ + REG_XSP] /* maintain align-16 w/ 2 pushes below */
#endif
        push     REG_XBX /* 16-byte aligned again */
        push     REG_XAX
        /* upper bytes are 0xab so only look at lower bytes */
        movzx    esi, BYTE [5*ARG_SZ + REG_XBP] /* exitproc */
        cmp      esi, 0
        jz       cat_thread_only
        CALLC0(GLOBAL_REF(dynamo_process_exit))
        jmp      cat_no_thread
cat_thread_only:
        CALLC0(GLOBAL_REF(dynamo_thread_exit))
cat_no_thread:
        /* now switch to initstack for cleanup of dstack
         * could use initstack for whole thing but that's too long
         * of a time to hold global initstack_mutex */
        mov      ecx, 1
#if !defined(X64) && defined(LINUX)
        /* PIC base is still in xdi */
        lea      REG_XAX, VAR_VIA_GOT(REG_XDI, GLOBAL_REF(initstack_mutex))
#endif
cat_spin:
#if !defined(X64) && defined(LINUX)
        xchg     DWORD [REG_XAX], ecx
#else
        xchg     DWORD SYMREF(initstack_mutex), ecx /* rip-relative on x64 */
#endif
        jecxz    cat_have_lock
        /* try again -- too few free regs to call sleep() */
        pause    /* good thing gas now knows about pause */
        jmp      cat_spin
cat_have_lock:
        /* need to grab everything off dstack first */
#ifdef WINDOWS
        /* PR 601533: the wow64 syscall writes to the stack b/c it
         * makes a call, so we have a race that can lead to a hang or
         * worse.  we do not expect the syscall to return, so we can
         * use a global single-entry stack (the wow64 layer swaps to a
         * different stack: presumably for alignment and other reasons).
         */
        CALLC1(GLOBAL_REF(os_terminate_wow64_stack), -1/*INVALID_HANDLE_VALUE*/)
        mov      REG_XDI, REG_XAX    /* esp to use */
#endif
        mov      REG_XSI, [2*ARG_SZ + REG_XBP]  /* sysnum */
        pop      REG_XAX             /* syscall */
        pop      REG_XCX             /* dstack */
#if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [2*ARG_SZ + REG_XSP] /* undo align-16 lea from above */
#endif
        mov      REG_XBX, [3*ARG_SZ + REG_XBP] /* sys_arg1 */
        mov      REG_XDX, [4*ARG_SZ + REG_XBP] /* sys_arg2 */
        /* swap stacks */
#if !defined(X64) && defined(LINUX)
        /* PIC base is still in xdi */
        lea      REG_XBP, VAR_VIA_GOT(REG_XDI, GLOBAL_REF(initstack))
        mov      REG_XSP, PTRSZ [REG_XBP]
#else
        mov      REG_XSP, PTRSZ SYMREF(initstack) /* rip-relative on x64 */
#endif
        /* now save registers */
#if defined(MACOS) && !defined(X64)
        /* ensure aligned after 1st 2 arg pushes below, which are the syscall args */
        lea      REG_XSP, [-2*ARG_SZ + REG_XSP]
#endif
#ifdef WINDOWS
        push     REG_XDI   /* esp to use */
#endif
        push     REG_XDX   /* sys_arg2 */
        push     REG_XBX   /* sys_arg1 */
        push     REG_XAX   /* syscall */
        push     REG_XSI   /* sysnum => xsp 16-byte aligned for x64 and x86 */
#if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [-2*ARG_SZ + REG_XSP] /* align to 16 for this call */
#endif
        /* free dstack and call the EXIT_DR_HOOK */
        CALLC1(GLOBAL_REF(dynamo_thread_stack_free_and_exit), REG_XCX) /* pass dstack */
#if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [2*ARG_SZ + REG_XSP] /* undo align to 16 */
#endif
        /* finally, execute the termination syscall */
        pop      REG_XAX   /* sysnum */
#ifdef X64
        /* We assume we're doing "syscall" on Windows & Linux, where r10 is dead */
        pop      r10       /* syscall, in reg dead at syscall */
# ifdef UNIX
        pop      REG_XDI   /* sys_arg1 */
        pop      REG_XSI   /* sys_arg2 */
# else
        pop      REG_XCX   /* sys_arg1 */
        pop      REG_XDX   /* sys_arg2 */
# endif
#else
        pop      REG_XSI   /* syscall */
# ifdef MACOS
        /* Leave the args on the stack for 32-bit Mac.  We actually need another
         * slot before the 1st arg (usually the retaddr for app syscall).
         * This ends up with stack alignment of 0xc, which is what we want.
         */
        push     0
# elif defined(LINUX)
        pop      REG_XBX   /* sys_arg1 */
        pop      REG_XCX   /* sys_arg2 */
# else
        pop      REG_XDX   /* sys_arg1 == param_base */
        pop      REG_XCX   /* sys_arg2 (unused) */
# endif
#endif
#ifdef WINDOWS
        pop      REG_XSP    /* get the stack pointer we pushed earlier */
#endif
        /* give up initstack mutex -- potential problem here with a thread getting
         *   an asynch event that then uses initstack, but syscall should only care
         *   about ebx and edx */
#if !defined(X64) && defined(LINUX)
        /* PIC base is still in xdi */
        lea      REG_XBP, VAR_VIA_GOT(REG_XDI, initstack_mutex)
        mov      DWORD [REG_XBP], 0
#else
        mov      DWORD SYMREF(initstack_mutex), 0 /* rip-relative on x64 */
#endif
        /* we are finished with all shared resources, decrement the
         * exiting_thread_count (allows another thread to kill us) */
#if !defined(X64) && defined(LINUX)
        /* PIC base is still in xdi */
        lea      REG_XBP, VAR_VIA_GOT(REG_XDI, GLOBAL_REF(exiting_thread_count))
        lock dec DWORD [REG_XBP]
#else
        lock dec DWORD SYMREF(exiting_thread_count) /* rip-rel on x64 */
#endif
#ifdef X64
        jmp      r10      /* go do the syscall! */
#else
        jmp      REG_XSI  /* go do the syscall! */
#endif
        END_FUNC(cleanup_and_terminate)

/* global_do_syscall_int
 * Caller is responsible for all set up.  For windows this means putting the
 * syscall num in eax and putting the args at edx.  For linux this means putting
 * the syscall num in eax, and the args in ebx, ecx, edx, esi, edi and ebp (in
 * that order, as needed).  global_do_syscall is only used with system calls
 * that we don't expect to return, so for debug builds we go into an infinite
 * loop if syscall returns.
 */
        DECLARE_FUNC(global_do_syscall_int)
GLOBAL_LABEL(global_do_syscall_int:)
#ifdef WINDOWS
        int      HEX(2e)
#else
        /* XXX: if we need to make any Mach syscalls for MacOS here, we'll
         * need a sysenter version, as the kernel throws SIGSYS when using int.
         */
        int      HEX(80)
#endif
#ifdef DEBUG
        jmp      GLOBAL_REF(debug_infinite_loop)
#endif
#ifdef UNIX
        /* we do come here for SYS_kill which can fail: try again via exit_group */
        jmp      GLOBAL_REF(dynamorio_sys_exit_group)
#endif
        END_FUNC(global_do_syscall_int)

/* For sygate hack need to indirect the system call through ntdll. */
#ifdef WINDOWS
        DECLARE_FUNC(global_do_syscall_sygate_int)
GLOBAL_LABEL(global_do_syscall_sygate_int:)
        /* would be nicer to call so we could return to debug_infinite_loop on
         * failure, but on some paths (cleanup_and_terminate) we can no longer
         * safetly use the stack */
        jmp      PTRSZ SYMREF(int_syscall_address)
        END_FUNC(global_do_syscall_sygate_int)
#endif

/* global_do_syscall_sysenter
 * Caller is responsible for all set up, this means putting the syscall num
 * in eax and putting the args at edx+8 (windows specific, we don't yet support
 * linux sysenter).  global_do_syscall is only used with system calls that we
 * don't expect to return.  As edx becomes esp, if the syscall does return it
 * will go to the address in [edx] (again windows specific) (if any debugging
 * code is desired should be pointed to there, do note that edx will become esp
 * so be aware of stack limitations/protections).
 */
        DECLARE_FUNC(global_do_syscall_sysenter)
GLOBAL_LABEL(global_do_syscall_sysenter:)
#if defined(X64) && defined(WINDOWS)
        syscall  /* FIXME ml64 won't take "sysenter" so half-fixing now */
#else
        sysenter
#endif
#ifdef DEBUG
        /* We'll never ever reach here, sysenter won't/can't return to this
         * address since it doesn't know it, but we'll put in a jmp to
         * debug_infinite_loop just in case */
        jmp      GLOBAL_REF(debug_infinite_loop)
#endif
        END_FUNC(global_do_syscall_sysenter)

/* Sygate case 5441 hack - the return address (edx) needs to point to
 * ntdll to pass their verification.  Global_do_syscall is really only
 * used with system calls that aren't expected to return so we don't
 * have to be too careful.  Just shuffle the stack using the sysret addr.
 * If there is already a return address we'll keep that (just move down
 * a slot).
 */
#ifdef WINDOWS
        DECLARE_FUNC(global_do_syscall_sygate_sysenter)
GLOBAL_LABEL(global_do_syscall_sygate_sysenter:)
        mov      REG_XSP, REG_XDX
        /* move existing ret down a slot (note target address is
         * computed with already inc'ed esp [see intel docs]) */
        pop      PTRSZ [REG_XSP]
        push     PTRSZ SYMREF(sysenter_ret_address)
#if defined(X64) && defined(WINDOWS)
        syscall  /* FIXME ml64 won't take "sysenter" so half-fixing now */
#else
        sysenter
#endif
#ifdef DEBUG
        /* We'll never ever reach here, sysenter won't/can't return to this
         * address since it doesn't know it, but we'll put in a jmp to
         * debug_infinite_loop just in case */
        jmp      GLOBAL_REF(debug_infinite_loop)
#endif
        END_FUNC(global_do_syscall_sygate_sysenter)
#endif

/* Both Windows and Linux put rcx into r10 since rcx is used as the return addr */
#ifdef X64
/* global_do_syscall_syscall
 * Caller is responsible for all set up: putting the syscall num in eax
 * and the args in registers/memory.  Only used with system calls
 * that we don't expect to return, so for debug builds we go into an infinite
 * loop if syscall returns.
  */
       DECLARE_FUNC(global_do_syscall_syscall)
GLOBAL_LABEL(global_do_syscall_syscall:)
        mov      r10, REG_XCX
        syscall
#   ifdef DEBUG
        jmp      GLOBAL_REF(debug_infinite_loop)
#   endif
#   ifdef UNIX
        /* we do come here for SYS_kill which can fail: try again via exit_group */
        jmp      GLOBAL_REF(dynamorio_sys_exit_group)
#   endif
        END_FUNC(global_do_syscall_syscall)
#endif

#ifdef WINDOWS

/* global_do_syscall_wow64
 * Xref case 3922
 * Caller is responsible for all set up: putting the syscall num in eax,
 * the wow64 index into ecx, and the args in edx.  Only used with system calls
 * that we don't expect to return, so for debug builds we go into an infinite
 * loop if syscall returns.
  */
       DECLARE_FUNC(global_do_syscall_wow64)
GLOBAL_LABEL(global_do_syscall_wow64:)
        call     PTRSZ SEGMEM(fs,HEX(0c0))
#ifdef DEBUG
        jmp      GLOBAL_REF(debug_infinite_loop)
#endif
        END_FUNC(global_do_syscall_wow64)

/* global_do_syscall_wow64_index0
 * Sames as global_do_syscall_wow64, except zeros out ecx.
 */
        DECLARE_FUNC(global_do_syscall_wow64_index0)
GLOBAL_LABEL(global_do_syscall_wow64_index0:)
        xor      ecx, ecx
        call     PTRSZ SEGMEM(fs,HEX(0c0))
#ifdef DEBUG
        jmp      GLOBAL_REF(debug_infinite_loop)
#endif
        END_FUNC(global_do_syscall_wow64_index0)

#endif /* WINDOWS */

#ifdef DEBUG
/* Just an infinite CPU eating loop used to mark certain failures.
 */
        DECLARE_FUNC(debug_infinite_loop)
GLOBAL_LABEL(debug_infinite_loop:)
        jmp      GLOBAL_REF(debug_infinite_loop)
        END_FUNC(debug_infinite_loop)
#endif

#ifdef WINDOWS
/* We use our own syscall wrapper for key win32 system calls.
 *
 * We would use a dynamically generated routine created by decoding
 * a real ntdll wrapper and tweaking it, but we need to use
 * this for our own syscalls and have a bootstrapping problem -- so
 * rather than hacking to get the power to decode w/o a heap, we hardcode
 * the types we support here.
 *
 * We assume that all syscall wrappers are identical, and they have
 * specific instruction sequences -- thus this routine needs to be updated
 * with any syscall sequence change in a future version of ntdll.dll!
 *
 * We construct our own minimalist versions that use C calling convention
 * and take as a first argument the system call number:
 *
 * ref case 5217, for Sygate compatibility the int needs to come from
 * ntdll.dll, we use a call to NtYieldExecution+9 (int 2e; ret;)
 *
 * 1)   mov immed, eax        mov 4(esp), eax
 *      lea 4(esp), edx  ==>  lea 8(esp), edx
 *      int 2e                  int 2e
 *      ret 4*numargs          ret
 *
 * 2)   mov immed, eax               mov 4(esp), eax
 *      mov 0x7ffe0300, edx          mov esp, edx
 *      call {edx,(edx)}             < juggle stack, see below >
 *         NOTE - to support the sygate case 5441 hack the actual instructions
 *              - we use are different, but the end up doing the same thing
 *    callee:                   ==>    sysenter
 *        mov esp, edx             our_ret:
 *        sysenter                     ret
 *        ret
 *      ret 4*numargs
 *
 * => signature: dynamorio_syscall_{int2e,sysenter}(sysnum, arg1, arg2, ...)
 */
        DECLARE_FUNC(dynamorio_syscall_int2e)
GLOBAL_LABEL(dynamorio_syscall_int2e:)
        mov      eax, [4 + esp]
        lea      edx, [8 + esp]
        int      HEX(2e)
        ret
        END_FUNC(dynamorio_syscall_int2e)

        DECLARE_FUNC(dynamorio_syscall_sygate_int2e)
GLOBAL_LABEL(dynamorio_syscall_sygate_int2e:)
        mov      eax, [4 + esp]
        lea      edx, [8 + esp]
        call     PTRSZ SYMREF(int_syscall_address)
        ret
        END_FUNC(dynamorio_syscall_sygate_int2e)

        DECLARE_FUNC(dynamorio_syscall_sysenter)
GLOBAL_LABEL(dynamorio_syscall_sysenter:)
        /* esp + 0    return address
         *       4    syscall num
         *       8+   syscall args
         * Ref case 5461 edx serves as both the argument pointer (edx+8) and the
         * top of stack for the kernel sysexit. */
        mov      eax, [4 + esp]
        mov      REG_XDX, REG_XSP
#if defined(X64) && defined(WINDOWS)
        syscall  /* FIXME ml64 won't take "sysenter" so half-fixing now */
#else
        sysenter
#endif
        /* Kernel sends control to hardcoded location, which does ret,
         * which will return directly back to the caller.  Thus the following
         * ret will never execute. */
        ret
        END_FUNC(dynamorio_syscall_sysenter)

        DECLARE_GLOBAL(dynamorio_sysenter_fixup)
        DECLARE_FUNC(dynamorio_syscall_sygate_sysenter)
GLOBAL_LABEL(dynamorio_syscall_sygate_sysenter:)
        /* stack looks like:
         * esp + 0    return address
         *       4    syscall num
         *       8+   syscall args
         * Ref case 5461 edx serves as both the argument pointer (edx+8) and the
         * top  of stack for the kernel sysexit. While we could do nothing and
         * just have the sysenter return straight back to the caller, we use
         * sysenter_ret_address indirection to support the Sygate compatibility
         * fix for case 5441 where steal a ret from ntdll.dll so need to mangle
         * our stack to look like
         * esp + 0    sysenter_ret_address
         *       4    dynamorio_sysenter_fixup
         *       8+   syscall args
         * sysenter_tls_slot    return address
         * before we do the edx <- esp
         *
         * NOTE - we can NOT just have
         * esp + 0    sysenter_ret_address
         *       4    return address
         *       8    args
         * as even though this will go the right place, the stack will be one
         * off on the return (debug builds with frame ptr are ok, but not
         * release).  We could roll our own custom calling convention for this
         * but would be a pain given how this function is called.  So we use a
         * tls slot to store the return address around the system call since
         * there isn't room on the stack, thus is not re-entrant, but neither is
         * dr and we don't make alertable system calls.  An alternate scheme
         * kept the return address off the top of the stack which works fine
         * (nothing alertable), but just seemed too risky.
         * FIXME - any perf impact from breaking hardware return predictor */
        pop      REG_XDX
        mov      eax, DWORD SYMREF(sysenter_tls_offset)
        mov      SEGMEM(fs,eax), edx
        pop      REG_XAX
#ifdef X64
        /* Can't push a 64-bit immed */
        mov      REG_XCX, dynamorio_sysenter_fixup
        push     REG_XCX
#else
        push     dynamorio_sysenter_fixup
#endif
        push     PTRSZ SYMREF(sysenter_ret_address)
        mov      REG_XDX, REG_XSP
#if defined(X64) && defined(WINDOWS)
        syscall  /* FIXME ml64 won't take "sysenter" so half-fixing now */
#else
        sysenter
#endif
ADDRTAKEN_LABEL(dynamorio_sysenter_fixup:)
        /* push whatever (was the slot for the eax arg) */
        push     REG_XAX
        /* ecx/edx should be dead here, just borrow one */
        mov      edx, DWORD SYMREF(sysenter_tls_offset)
        push     PTRSZ SEGMEM(fs,edx)
        ret
        END_FUNC(dynamorio_syscall_sygate_sysenter)

# ifdef X64
/* With the 1st 4 args in registers, we don't want the sysnum to shift them
 * all as it's not easy to un-shift.  So, we put the 1st arg last, and
 * the SYS enum value first.  We use the syscall_argsz array to restore
 * the 1st arg.  Since the return value is never larger than 64 bits, we
 * never have to worry about a hidden 1st arg that shifts the rest.
 */
        DECLARE_FUNC(dynamorio_syscall_syscall)
GLOBAL_LABEL(dynamorio_syscall_syscall:)
        mov      rax, QWORD SYMREF(syscalls)
        /* the upper 32 bits are automatically zeroed */
        mov      eax, DWORD [rax + ARG1*4] /* sysnum in rax */
        mov      r10, syscall_argsz
        /* the upper 32 bits are automatically zeroed */
        mov      r10d, DWORD [r10 + ARG1*4] /* # args in r10 */
        cmp      r10, 0
        je       dynamorio_syscall_syscall_ready
        cmp      r10, 1
        je       dynamorio_syscall_syscall_1arg
        cmp      r10, 2
        je       dynamorio_syscall_syscall_2arg
        cmp      r10, 3
        je       dynamorio_syscall_syscall_3arg
        /* else, >= 4 args, so pull from arg slot of (#args + 1) */
        mov      ARG1, QWORD [rsp + r10*8 + 8]
        jmp      dynamorio_syscall_syscall_ready
dynamorio_syscall_syscall_1arg:
        mov      ARG1, ARG2
        jmp      dynamorio_syscall_syscall_ready
dynamorio_syscall_syscall_2arg:
        mov      ARG1, ARG3
        jmp      dynamorio_syscall_syscall_ready
dynamorio_syscall_syscall_3arg:
        mov      ARG1, ARG4
        /* fall-through */
dynamorio_syscall_syscall_ready:
        mov      r10, rcx /* put rcx in r10 just like Nt wrappers (syscall writes rcx) */
        syscall
        ret
        END_FUNC(dynamorio_syscall_syscall)
# endif

/* For WOW64 (case 3922) the syscall wrappers call *teb->WOW32Reserved (==
 * wow64cpu!X86SwitchTo64BitMode), which is a far jmp that switches to the
 * 64-bit cs segment (0x33 selector).  They pass in ecx an index into
 * a function table of argument conversion routines.
 *
 * 3)   mov sysnum, eax
 *      mov tableidx, ecx
 *      call *fs:0xc0
 *    callee:
 *        jmp  0x33:wow64cpu!CpupReturnFromSimulatedCode
 *      ret 4*numargs
 *
 * rather than taking in sysnum and tableidx, we take in sys_enum and
 * look up the sysnum and tableidx to keep the same args as the other
 * dynamorio_syscall_* routines
 * => signature: dynamorio_syscall_wow64(sys_enum, arg1, arg2, ...)
 */
        DECLARE_FUNC(dynamorio_syscall_wow64)
GLOBAL_LABEL(dynamorio_syscall_wow64:)
        mov      eax, [4 + esp]
        mov      edx, DWORD SYMREF(wow64_index)
        mov      ecx, [edx + eax*4]
        mov      edx, DWORD SYMREF(syscalls)
        mov      eax, [edx + eax*4]
        lea      edx, [8 + esp]
        call     PTRSZ SEGMEM(fs,HEX(0c0))
        ret
        END_FUNC(dynamorio_syscall_wow64)

/* Win8 has no index and furthermore requires the stack to be set
 * up (i.e., we can't just point edx where we want it).
 * Thus, we must shift the retaddr one slot down on top of sys_enum.
 * => signature: dynamorio_syscall_wow64_noedx(sys_enum, arg1, arg2, ...)
 */
        DECLARE_FUNC(dynamorio_syscall_wow64_noedx)
GLOBAL_LABEL(dynamorio_syscall_wow64_noedx:)
        mov      eax, [4 + esp]
        mov      ecx, DWORD SYMREF(syscalls)
        mov      eax, [ecx + eax*4]
        mov      ecx, [esp]
        mov      [esp + 4], ecx
        lea      esp, [esp + 4]
        call     PTRSZ SEGMEM(fs,HEX(0c0))
        /* we have to restore the stack shift of course (i#1036) */
        mov      ecx, [esp]
        mov      [esp - 4], ecx
        lea      esp, [esp - 4]
        ret
        END_FUNC(dynamorio_syscall_wow64_noedx)

#endif /* WINDOWS */

#endif /* !NOT_DYNAMORIO_CORE_PROPER */

/*
 * For debugging: report an error if the function called by call_switch_stack()
 * unexpectedly returns.  Also used elsewhere.
 */
        DECLARE_FUNC(unexpected_return)
GLOBAL_LABEL(unexpected_return:)
#if defined(INTERNAL) && !defined(NOT_DYNAMORIO_CORE_PROPER)
        CALLC3(GLOBAL_REF(internal_error), 0, -99 /* line # */, 0)
        /* internal_error never returns */
#endif
        /* infinite loop is intentional: FIXME: do better in release build!
         * FIXME - why not an int3? */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(unexpected_return)

/* we share dynamorio_syscall w/ preload */
#ifdef UNIX
/* to avoid libc wrappers we roll our own syscall here
 * hardcoded to use int 0x80 for 32-bit -- FIXME: use something like do_syscall
 * and syscall for 64-bit.
 * signature: dynamorio_syscall(sysnum, num_args, arg1, arg2, ...)
 * For Linux, the argument max is 6.
 * For MacOS, the argument max is 6 for x64 and 7 for x86.
 */
        DECLARE_FUNC(dynamorio_syscall)
GLOBAL_LABEL(dynamorio_syscall:)
        /* x64 kernel doesn't clobber all the callee-saved registers */
        push     REG_XBX /* stack now aligned for x64 */
# ifdef X64
        /* reverse order so we don't clobber earlier args */
        mov      REG_XBX, ARG2 /* put num_args where we can reference it longer */
        mov      rax, ARG1 /* sysnum: only need eax, but need rax to use ARG1 (or movzx) */
#  ifdef MACOS
        /* for now we assume a BSD syscall */
        or       rax, 0x2000000
#  endif
        cmp      REG_XBX, 0
        je       syscall_ready
        mov      ARG1, ARG3
        cmp      REG_XBX, 1
        je       syscall_ready
        mov      ARG2, ARG4
        cmp      REG_XBX, 2
        je       syscall_ready
        mov      ARG3, ARG5
        cmp      REG_XBX, 3
        je       syscall_ready
        mov      ARG4, ARG6
        cmp      REG_XBX, 4
        je       syscall_ready
        mov      ARG5, [2*ARG_SZ + REG_XSP] /* arg7: above xbx and retaddr */
        cmp      REG_XBX, 5
        je       syscall_ready
        mov      ARG6, [3*ARG_SZ + REG_XSP] /* arg8: above arg7, xbx, retaddr */
syscall_ready:
        mov      r10, rcx
        syscall
# else
        push     REG_XBP
        push     REG_XSI
        push     REG_XDI
        /* add 16 to skip the 4 pushes
         * XXX: rather than this dispatch, could have separate routines
         * for each #args, or could just blindly read upward on the stack.
         * for dispatch, if assume size of mov instr can do single ind jmp */
        mov      ecx, [16+ 8 + esp] /* num_args */
        cmp      ecx, 0
        je       syscall_0args
        cmp      ecx, 1
        je       syscall_1args
        cmp      ecx, 2
        je       syscall_2args
        cmp      ecx, 3
        je       syscall_3args
        cmp      ecx, 4
        je       syscall_4args
        cmp      ecx, 5
        je       syscall_5args
#  ifdef MACOS
        cmp      ecx, 6
        je       syscall_6args
#   ifdef INTERNAL
        cmp      ecx, 7
        jg       GLOBAL_REF(unexpected_return)
#   endif
        mov      eax, [16+36 + esp] /* arg7 */
syscall_6args:
#  elif defined(INTERNAL)
        cmp      ecx, 6
        jg       GLOBAL_REF(unexpected_return)
#  endif
        mov      ebp, [16+32 + esp] /* arg6 */
syscall_5args:
        mov      edi, [16+28 + esp] /* arg5 */
syscall_4args:
        mov      esi, [16+24 + esp] /* arg4 */
syscall_3args:
        mov      edx, [16+20 + esp] /* arg3 */
syscall_2args:
        mov      ecx, [16+16 + esp] /* arg2 */
syscall_1args:
        mov      ebx, [16+12 + esp] /* arg1 */
syscall_0args:
#  ifdef MACOS
        push     eax /* 7th arg, if any */
        /* Arg size is encoded in upper bits.
         * XXX: or is that only for sysenter gateway?
         * We assume this is size, not count, and so for our "7 arg"
         * call that's really 6 with one 64-bit we leave it.
         */
        mov      eax, [20+ 8 + esp] /* num_args */
        shl      eax, 18 /* <<16 but also *4 for size */
        or       eax, [20+ 4 + esp] /* sysnum */
        /* args are on stack, w/ an extra slot (retaddr of syscall wrapper) */
        push     ebp
        push     edi
        push     esi
        push     edx
        push     ecx
        push     ebx /* aligned to 16 after this push */
        push     0 /* extra slot (app retaddr) */
        /* It simplifies our syscall calling to have a single dynamorio_syscall()
         * signature that returns int64 -- but most syscalls just return a 32-bit
         * value and the kernel does not clear edx.  Thus we need to do so, which
         * should be safe since edx is caller-saved.  (Note that we do not risk
         * doing this for app syscalls: only those called by DR.)
         */
        mov      edx, 0
#  else
        mov      eax, [16+ 4 + esp] /* sysnum */
#  endif
        /* PR 254280: we assume int$80 is ok even for LOL64, maybe slow is all.
         * For Mac, it's possible to do sysenter here as we can store the retaddr
         * in edx ourselves (in fact see r2514 dynamorio_syscall_sysenter for an
         * implementation, now removed), but we still need int for certain syscalls
         * (returning 64-bit values, e.g.) so we go w/ int always and assume our
         * syscall perf doesn't matter much (should be rare).
         */
        int      HEX(80)
#  ifdef MACOS
        lea      esp, [8*ARG_SZ + esp] /* must not change flags */
#  endif
        pop      REG_XDI
        pop      REG_XSI
        pop      REG_XBP
# endif /* X64 */
        pop      REG_XBX
        /* return val is in eax for us */
        /* for MacOS, it can also include edx, so be sure not to clobber that! */
# ifdef MACOS
        /* convert to -errno */
        jae      syscall_success
        neg      eax
syscall_success:
# endif
        ret
        END_FUNC(dynamorio_syscall)

# ifdef MACOS
/* Mach dep syscall invocation.
 * Signature: dynamorio_mach_dep_syscall(sysnum, num_args, arg1, arg2, ...)
 * Only supports up to 4 args.
 */
        DECLARE_FUNC(dynamorio_mach_dep_syscall)
GLOBAL_LABEL(dynamorio_mach_dep_syscall:)
        /* x64 kernel doesn't clobber all the callee-saved registers */
        push     REG_XBX
#  ifdef X64
        /* reverse order so we don't clobber earlier args */
        mov      REG_XBX, ARG2 /* put num_args where we can reference it longer */
        mov      rax, ARG1 /* sysnum: only need eax, but need rax to use ARG1 (or movzx) */
        cmp      REG_XBX, 0
        je       mach_dep_syscall_ready
        mov      ARG1, ARG3
        cmp      REG_XBX, 1
        je       mach_dep_syscall_ready
        mov      ARG2, ARG4
        cmp      REG_XBX, 2
        je       mach_dep_syscall_ready
        mov      ARG3, ARG5
        cmp      REG_XBX, 3
        je       mach_dep_syscall_ready
        mov      ARG4, ARG6
#  else
        push     REG_XBP
        push     REG_XSI
        push     REG_XDI
        /* add 16 to skip the 4 pushes */
        mov      ecx, [16+ 8 + esp] /* num_args */
        cmp      ecx, 0
        je       mach_dep_syscall_0args
        cmp      ecx, 1
        je       mach_dep_syscall_1args
        cmp      ecx, 2
        je       mach_dep_syscall_2args
        cmp      ecx, 3
        je       mach_dep_syscall_3args
        mov      esi, [16+24 + esp] /* arg4 */
mach_dep_syscall_3args:
        mov      edx, [16+20 + esp] /* arg3 */
mach_dep_syscall_2args:
        mov      ecx, [16+16 + esp] /* arg2 */
mach_dep_syscall_1args:
        mov      ebx, [16+12 + esp] /* arg1 */
mach_dep_syscall_0args:
        mov      eax, [16+ 4 + esp] /* sysnum */
        lea      REG_XSP, [-2*ARG_SZ + REG_XSP] /* maintain align-16: retaddr-5th below */
        /* args are on stack, w/ an extra slot (retaddr of syscall wrapper) */
        push     esi
        push     edx
        push     ecx
        push     ebx
        push     0 /* extra slot */
        /* clear the top half so we can always consider the result 64-bit */
        mov      edx, 0
#  endif
        /* mach dep syscalls use interrupt 0x82 */
        int      HEX(82)
#  ifndef X64
        lea      esp, [7*ARG_SZ + esp] /* must not change flags */
        pop      REG_XDI
        pop      REG_XSI
        pop      REG_XBP
#  endif
        pop      REG_XBX
        /* return val is in eax for us */
        /* for MacOS, it can also include edx, so be sure not to clobber that! */
        /* convert to -errno */
        jae      mach_dep_syscall_success
        neg      eax
mach_dep_syscall_success:
        ret
        END_FUNC(dynamorio_mach_dep_syscall)
# endif /* MACOS */

/* FIXME: this function should be in #ifdef CLIENT_INTERFACE
 * However, the compiler complains about it in
 * vps-debug-internal-32 build, so we remove the ifdef now.
 */
/* i#555: to avoid client use app's vsyscall, we enforce all clients
 * use int 0x80 for system call.
 */
        DECLARE_FUNC(client_int_syscall)
GLOBAL_LABEL(client_int_syscall:)
        int      HEX(80)
        ret
        END_FUNC(client_int_syscall)
#endif /* UNIX */
#ifndef NOT_DYNAMORIO_CORE_PROPER
#ifdef UNIX

#ifdef LINUX /* XXX i#1285: implement MacOS private loader + injector */
#if !defined(STANDALONE_UNIT_TEST) && !defined(STATIC_LIBRARY)
/* i#47: Early injection _start routine.  The kernel sets all registers to zero
 * except the SP and PC.  The stack has argc, argv[], envp[], and the auxiliary
 * vector laid out on it.
 */
        DECLARE_FUNC(_start)
GLOBAL_LABEL(_start:)
        xor     REG_XBP, REG_XBP  /* Terminate stack traces at NULL. */
# ifdef X64
        mov     ARG1, REG_XSP
# else
        mov     REG_XAX, REG_XSP
#  ifdef MACOS
        lea      REG_XSP, [-3*ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
#  endif
        push    REG_XAX
# endif
        CALLC0(GLOBAL_REF(privload_early_inject))
        jmp     GLOBAL_REF(unexpected_return)
        END_FUNC(_start)
#endif /* !STANDALONE_UNIT_TEST && !STATIC_LIBRARY */
#endif /* LINUX */

/* while with pre-2.6.9 kernels we were able to rely on the kernel's
 * default sigreturn code sequence and be more platform independent,
 * case 6700 necessitates having our own code, which for now, like
 * dynamorio_syscall, hardcodes int 0x80
 */
        DECLARE_FUNC(dynamorio_sigreturn)
GLOBAL_LABEL(dynamorio_sigreturn:)
#ifdef X64
        mov      eax, HEX(f)
        mov      r10, rcx
        syscall
#else
# ifdef MACOS
        /* we assume we don't need to align the stack (tricky to do so) */
        /* XXX: should we target _sigtramp instead?  Some callers aren't
         * on a signal frame though.
         */
        mov      eax, HEX(b8)
# else
        mov      eax, HEX(ad)
# endif
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
#endif
        /* should not return.  if we somehow do,infinite loop is intentional.
         * FIXME: do better in release build! FIXME - why not an int3? */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(dynamorio_sigreturn)

/* we need to exit without using any stack, to support
 * THREAD_SYNCH_TERMINATED_AND_CLEANED.
 */
        DECLARE_FUNC(dynamorio_sys_exit)
GLOBAL_LABEL(dynamorio_sys_exit:)
#ifdef X64
        mov      edi, 0 /* exit code: hardcoded */
        mov      eax, HEX(3c) /* SYS_exit */
        mov      r10, rcx
        syscall
#else
#  ifdef MACOS
        /* XXX: won't this kill the whole process?  dynamorio_sys_exit_group
         * should do this, and here we should invoke something else
         */
        lea      REG_XSP, [-3*ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
#  endif
        mov      ebx, 0 /* exit code: hardcoded */
        mov      eax, HEX(1) /* SYS_exit */
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
#endif
        /* should not return.  if we somehow do, infinite loop is intentional.
         * FIXME: do better in release build! FIXME - why not an int3? */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(dynamorio_sys_exit)

#ifdef LINUX
/* we need to call futex_wakeall without using any stack, to support
 * THREAD_SYNCH_TERMINATED_AND_CLEANED.
 * takes int* futex in xax.
 */
        DECLARE_FUNC(dynamorio_futex_wake_and_exit)
GLOBAL_LABEL(dynamorio_futex_wake_and_exit:)
#ifdef X64
        mov      ARG6, 0
        mov      ARG5, 0
        mov      ARG4, 0
        mov      ARG3, 0x7fffffff /* arg3 = INT_MAX */
        mov      ARG2, 1 /* arg2 = FUTEX_WAKE */
        mov      ARG1, rax /* &futex, passed in rax */
        mov      rax, 202 /* SYS_futex */
        mov      r10, rcx
        syscall
#else
        mov      ebp, 0 /* arg6 */
        mov      edi, 0 /* arg5 */
        mov      esi, 0 /* arg4 */
        mov      edx, 0x7fffffff /* arg3 = INT_MAX */
        mov      ecx, 1 /* arg2 = FUTEX_WAKE */
        mov      ebx, eax /* arg1 = &futex, passed in eax */
        mov      eax, 240 /* SYS_futex */
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
#endif
        jmp GLOBAL_REF(dynamorio_sys_exit)
        END_FUNC(dynamorio_futex_wake_and_exit)
#endif /* LINUX */

/* exit entire group without using any stack, in case something like
 * SYS_kill via cleanup_and_terminate fails
 */
        DECLARE_FUNC(dynamorio_sys_exit_group)
GLOBAL_LABEL(dynamorio_sys_exit_group:)
#ifdef X64
        mov      edi, 0 /* exit code: hardcoded */
        mov      eax, HEX(e7) /* SYS_exit_group */
        mov      r10, rcx
        syscall
#else
#  ifdef MACOS
        /* XXX: invoke SYS_exit here and something else in dynamorio_sys_exit */
        lea      REG_XSP, [-3*ARG_SZ + REG_XSP] /* maintain align-16: offset retaddr */
#  endif
        mov      ebx, 0 /* exit code: hardcoded */
        mov      eax, HEX(fc) /* SYS_exit_group */
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
#endif
        /* should not return.  if we somehow do, infinite loop is intentional.
         * FIXME: do better in release build! FIXME - why not an int3? */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(dynamorio_sys_exit_group)

#if defined(LINUX) && !defined(X64)
/* since our handler is rt, we have no source for the kernel's/libc's
 * default non-rt sigreturn, so we set up our own.
 */
        DECLARE_FUNC(dynamorio_nonrt_sigreturn)
GLOBAL_LABEL(dynamorio_nonrt_sigreturn:)
        pop      eax /* I don't understand why */
        mov      eax, HEX(77)
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
        /* should not return.  if we somehow do,infinite loop is intentional.
         * FIXME: do better in release build! FIXME - why not an int3? */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(dynamorio_sigreturn)
#endif

#ifdef HAVE_SIGALTSTACK
/* We used to get the SP by taking the address of our args, but that doesn't
 * work on x64 nor with other compilers.  Today we use asm to pass in the
 * initial SP.  For x64, we add a 4th register param and tail call to
 * master_signal_handler_C.  Adding a param and doing a tail call on ia32 is
 * hard, so we make a real call and pass only xsp.  The C routine uses it to
 * read the original params.
 * See also PR 305020.
 */
        DECLARE_FUNC(master_signal_handler)
GLOBAL_LABEL(master_signal_handler:)
#ifdef X64
# ifdef LINUX
        mov      ARG4, REG_XSP /* pass as extra arg */
# else
        mov      ARG6, REG_XSP /* pass as extra arg */
# endif
        jmp      GLOBAL_REF(master_signal_handler_C)
        /* master_signal_handler_C will do the ret */
#else
        /* We need to pass in xsp.  The easiest way is to create an
         * intermediate frame.
         */
        mov      REG_XAX, REG_XSP
        CALLC1_FRESH(GLOBAL_REF(master_signal_handler_C), REG_XAX)
# ifdef MACOS
        mov      eax, ARG5 /* ucxt */
        /* Set up args to SYS_sigreturn, skipping the retaddr slot */
        mov      edx, ARG2 /* style */
        CALLC2_FRESH(GLOBAL_REF(dynamorio_sigreturn), eax, edx)
        jmp      GLOBAL_REF(unexpected_return)
# else
        ret
# endif
#endif
        END_FUNC(master_signal_handler)

#else /* !HAVE_SIGALTSTACK */

/* PR 283149: if we're on the app stack now and we need to deliver
 * immediately, we can't copy over our own sig frame w/ the app's, and we
 * can't push the app's below ours and have continuation work.  One choice
 * is to copy the frame to pending and assume we'll deliver right away.
 * Instead we always swap to dstack, which also makes us a little more
 * transparent wrt running out of app stack or triggering app stack guard
 * pages.  We do it in asm since it's ugly to swap stacks in the middle
 * of a C routine: have to fix up locals + frame ptr, or jmp to start of
 * func and clobber callee-saved regs (which messes up vmkernel sigreturn).
 */
        DECLARE_FUNC(master_signal_handler)
GLOBAL_LABEL(master_signal_handler:)
        mov      REG_XAX, ARG1
        mov      REG_XCX, ARG2
        mov      REG_XDX, ARG3
        /* save args */
        push     REG_XAX
        push     REG_XCX
        push     REG_XDX
        /* make space for answers: struct clone_and_swap_args */
        sub      REG_XSP, CLONE_AND_SWAP_STRUCT_SIZE
        mov      REG_XAX, REG_XSP
        /* call a C routine rather than writing everything in asm */
        CALLC2(GLOBAL_REF(sig_should_swap_stack), REG_XAX, REG_XDX)
        cmp      REG_XAX, 0
        pop      REG_XAX /* clone_and_swap_args.stack */
        pop      REG_XCX /* clone_and_swap_args.tos */
        je       no_swap
        /* calculate the offset between stacks */
        mov      REG_XDX, REG_XAX
        sub      REG_XDX, REG_XCX /* shift = stack - tos */
# ifdef VMX86_SERVER
        /* update the two parameters to sigreturn for new stack
         * we can eliminate this once we have PR 405694
         */
#  ifdef X64
        add      r12, REG_XDX     /* r12 += shift */
#  else
        add      REG_XSI, REG_XDX /* xsi += shift */
#  endif
        add      REG_XBP, REG_XDX /* xbp += shift */
# endif
        push     REG_XDX
        CALLC2(GLOBAL_REF(clone_and_swap_stack), REG_XAX, REG_XCX)
        /* get shift back and update arg2 and arg3 */
        pop      REG_XDX
        pop      REG_XCX /* arg3 */
        pop      REG_XAX /* arg2 */
        add      REG_XAX, REG_XDX /* arg2 += shift */
        add      REG_XCX, REG_XDX /* arg3 += shift */
# ifndef X64
        /* update the official arg2 and arg3 on the stack */
        mov     [3*ARG_SZ + REG_XSP], REG_XAX  /* skip arg1+retaddr+arg1 */
        mov     [4*ARG_SZ + REG_XSP], REG_XCX
# endif
        push     REG_XAX
        push     REG_XCX
        /* need to get arg1, old frame, new frame */
        mov      REG_XAX, [4*ARG_SZ + REG_XSP] /* skip 3 args + retaddr */
        neg      REG_XDX
        add      REG_XDX, REG_XSP /* xsp-shift = old frame */
        add      REG_XDX, 3*ARG_SZ /* old frame */
        mov      REG_XCX, REG_XSP
        add      REG_XCX, 3*ARG_SZ /* new frame */
        /* have to be careful about order of reg params */
        CALLC5(GLOBAL_REF(fixup_rtframe_pointers), 0, REG_XAX, REG_XDX, REG_XCX, 0)
no_swap:
# ifdef X64
        pop      ARG3
        pop      ARG2
        pop      ARG1
        mov      rcx, rsp /* pass as 4th arg */
        jmp      GLOBAL_REF(master_signal_handler_C)
        /* can't return, no retaddr */
# else
        add      REG_XSP, 3*ARG_SZ
        /* We need to pass in xsp.  The easiest way is to create an
         * intermediate frame.
         */
        mov      REG_XAX, REG_XSP
        CALLC1(GLOBAL_REF(master_signal_handler_C), REG_XAX)
        ret
# endif
        END_FUNC(master_signal_handler)
#endif /* !HAVE_SIGALTSTACK */

#ifdef LINUX
/* SYS_clone swaps the stack so we need asm support to call it.
 * signature:
 *   thread_id_t dynamorio_clone(uint flags, byte *newsp, void *ptid, void *tls,
 *                               void *ctid, void (*func)(void))
 */
        DECLARE_FUNC(dynamorio_clone)
GLOBAL_LABEL(dynamorio_clone:)
        /* save func for use post-syscall on the newsp.
         * when using clone_record_t we have 4 slots we can clobber.
         */
# ifdef X64
        sub      ARG2, ARG_SZ
        mov      [ARG2], ARG6 /* func is now on TOS of newsp */
        /* all args are already in syscall registers */
        mov      r10, rcx
        mov      REG_XAX, SYS_clone
        syscall
# else
        mov      REG_XAX, ARG6
        mov      REG_XCX, ARG2
        sub      REG_XCX, ARG_SZ
        mov      [REG_XCX], REG_XAX /* func is now on TOS of newsp */
        mov      REG_XDX, ARG3
        /* preserve callee-saved regs */
        push     REG_XBX
        push     REG_XSI
        push     REG_XDI
        /* now can't use ARG* since xsp modified by pushes */
        mov      REG_XBX, DWORD [4*ARG_SZ + REG_XSP] /* ARG1 + 3 pushes */
        mov      REG_XSI, DWORD [7*ARG_SZ + REG_XSP] /* ARG4 + 3 pushes */
        mov      REG_XDI, DWORD [8*ARG_SZ + REG_XSP] /* ARG5 + 3 pushes */
        mov      REG_XAX, SYS_clone
        /* PR 254280: we assume int$80 is ok even for LOL64 */
        int      HEX(80)
# endif
        cmp      REG_XAX, 0
        jne      dynamorio_clone_parent
        /* avoid conflicts w/ parent's TLS by clearing our reg now */
        mov      SEG_TLS, ax
        pop      REG_XCX
        call     REG_XCX
        /* shouldn't return */
        jmp      GLOBAL_REF(unexpected_return)
dynamorio_clone_parent:
# ifndef X64
        /* restore callee-saved regs */
        pop      REG_XDI
        pop      REG_XSI
        pop      REG_XBX
# endif
        /* return val is in eax still */
        ret
        END_FUNC(dynamorio_clone)
#endif /* LINUX */

#endif /* UNIX */


#ifdef MACOS
/* Thread interception at the user function.  We need to get the
 * stack pointer and to preserve callee-saved registers, as we will return
 * back past the user function to the pthread layer (i#1403 covers
 * intercepting earlier).  We also clear fs, as the kernel seems to set it to
 * point at a flat whole-address-space value, messing up our checks for
 * it being initialized.
 */
        DECLARE_FUNC(new_bsdthread_intercept)
GLOBAL_LABEL(new_bsdthread_intercept:)
        /* We assume we can go ahead and clobber caller-saved regs. */
        mov      eax, 0
        mov      fs, eax
        mov      REG_XAX, ARG1
        PUSH_PRIV_MCXT(0 /* for priv_mcontext_t.pc */)
        lea      REG_XAX, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */
        CALLC1_FRESH(GLOBAL_REF(new_bsdthread_setup), REG_XAX)
        /* should not return */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(new_bsdthread_intercept)
#endif


#ifdef WINDOWS
/*
 * nt_continue_dynamo_start -- invoked to give dynamo control over
 * exception handler continuation (after a call to NtContinue).
 * identical to internal_dynamo_start except it calls nt_continue_start_setup
 * to get the real next pc, and has an esp adjustment at the start.
 */
        DECLARE_FUNC(nt_continue_dynamo_start)
GLOBAL_LABEL(nt_continue_dynamo_start:)
        /* assume valid esp
         * FIXME: this routine should really not assume esp */

        /* grab exec state and pass as param in a priv_mcontext_t struct */
        PUSH_PRIV_MCXT(0 /* for priv_mcontext_t.pc */)
        lea      REG_XAX, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */

        /* Call nt_continue_setup passing the priv_mcontext_t.  It will
         * obtain and initialize this thread's dcontext pointer and
         * begin execution with the passed-in state.
         */
        CALLC1(GLOBAL_REF(nt_continue_setup), REG_XAX)
        /* should not return */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(nt_continue_dynamo_start)
#endif /* WINDOWS */

/* back_from_native_retstubs -- We use a different version of back_from_native for
 * each nested module transition.  This has to have MAX_NATIVE_RETSTACK
 * elements, which we check in native_exec_init().  The size of each entry has
 * to match BACK_FROM_NATIVE_RETSTUB_SIZE in arch_exports.h.  Currently we
 * assume that the assembler uses push imm8 and jmp rel8.  As in
 * back_from_native, this code is executed natively by the app, so we assume the
 * app stack is valid and can be clobbered.
 */
        DECLARE_FUNC(back_from_native_retstubs)
GLOBAL_LABEL(back_from_native_retstubs:)
#ifndef ASSEMBLE_WITH_GAS
/* MASM does short jumps for public symbols. */
# define Lback_from_native GLOBAL_REF(back_from_native)
#endif
        push     0
        jmp      Lback_from_native
        push     1
        jmp      Lback_from_native
        push     2
        jmp      Lback_from_native
        push     3
        jmp      Lback_from_native
        push     4
        jmp      Lback_from_native
        push     5
        jmp      Lback_from_native
        push     6
        jmp      Lback_from_native
        push     7
        jmp      Lback_from_native
        push     8
        jmp      Lback_from_native
        push     9
        jmp      Lback_from_native
DECLARE_GLOBAL(back_from_native_retstubs_end)
#ifndef ASSEMBLE_WITH_GAS
# undef Lback_from_native
#endif
ADDRTAKEN_LABEL(back_from_native_retstubs_end:)
        END_FUNC(back_from_native_retstubs)

/*
 * back_from_native -- for taking control back after letting a module
 * execute natively
 * assumptions: app stack is valid
 */
        DECLARE_FUNC(back_from_native)
GLOBAL_LABEL(back_from_native:)
#ifdef ASSEMBLE_WITH_GAS
        /* We use Lback_from_native to force short jumps with gas.  */
Lback_from_native:
#endif
        /* assume valid esp
         * FIXME: more robust if don't use app's esp -- should use initstack
         */
        /* grab exec state and pass as param in a priv_mcontext_t struct */
        PUSH_PRIV_MCXT(0 /* for priv_mcontext_t.pc */)
        lea      REG_XAX, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */

        /* Call return_from_native passing the priv_mcontext_t.  It will obtain
         * this thread's dcontext pointer and begin execution with the passed-in
         * state.
         */
#if defined(X64) || defined(MACOS)
        and      REG_XSP, -FRAME_ALIGNMENT  /* x64 or Mac alignment */
#endif
        CALLC1(GLOBAL_REF(return_from_native), REG_XAX)
        /* should not return */
        jmp      GLOBAL_REF(unexpected_return)
        END_FUNC(back_from_native)

#ifdef UNIX
/* Like back_from_native, except we're calling from a native module into a
 * module that should execute from the code cache.  We transfer here from PLT
 * stubs generated by create_plt_stub() in core/unix/native_elf.c.  See also
 * initialize_plt_stub_template().  On entry, next_pc is on the stack for ia32
 * and in %r11 for x64.  We use %r11 because it is scratch in the sysv amd64
 * calling convention.
 */
        DECLARE_FUNC(native_plt_call)
GLOBAL_LABEL(native_plt_call:)
        PUSH_PRIV_MCXT(0 /* pc */)
        lea      REG_XAX, [REG_XSP]  /* lea priv_mcontext_t */
# ifdef X64
        mov      REG_XCX, r11  /* next_pc in r11 */
# else
        mov      REG_XCX, [REG_XSP + PRIV_MCXT_SIZE]     /* next_pc on stack */
        add      DWORD [REG_XAX + MCONTEXT_XSP_OFFS], ARG_SZ   /* adjust app xsp for arg */
# endif
        CALLC2_FRESH(GLOBAL_REF(native_module_callout), REG_XAX, REG_XCX)

        /* If we returned, continue to execute natively on the app stack. */
        POP_PRIV_MCXT_GPRS()
# ifdef X64
        jmp      r11    /* next_pc still in r11 */
# else
        ret             /* next_pc was on stack */
# endif
        END_FUNC(native_plt_call)
#endif /* UNIX */


/* Our version of setjmp & long jmp.  We don't want to modify app state like
 * SEH or do unwinding which is done by standard versions.
 */

#ifdef CLIENT_INTERFACE
/* Front-end for client use where we don't want to expose our struct layouts,
 * yet we must call dr_setjmp directly w/o a call frame in between for
 * a proper restore point.
 *
 * int dr_try_start(try_except_context_t *cxt) ;
 */
# define TRY_CXT_SETJMP_OFFS 0 /* offsetof(try_except_context_t, context) */
        DECLARE_EXPORTED_FUNC(dr_try_start)
GLOBAL_LABEL(dr_try_start:)
        add      ARG1, TRY_CXT_SETJMP_OFFS
        jmp      GLOBAL_REF(dr_setjmp)
        END_FUNC(dr_try_start)
#endif /* CLIENT_INTERFACE */

/* int cdecl dr_setjmp(dr_jmp_buf *buf);
 */
        DECLARE_FUNC(dr_setjmp)
GLOBAL_LABEL(dr_setjmp:)
#ifdef UNIX
        /* PR 206278: for try/except we need to save the signal mask */
        mov      REG_XDX, ARG1
        push     REG_XDX /* preserve */
# if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [-2*ARG_SZ + REG_XSP] /* maintain align-16: ra + push */
# endif
        CALLC1(GLOBAL_REF(dr_setjmp_sigmask), REG_XDX)
# if defined(MACOS) && !defined(X64)
        lea      REG_XSP, [2*ARG_SZ + REG_XSP] /* maintain align-16: ra + push */
# endif
        pop      REG_XDX /* preserve */
#else
        mov      REG_XDX, ARG1
#endif
        mov      [       0 + REG_XDX], REG_XBX
        mov      [  ARG_SZ + REG_XDX], REG_XCX
        mov      [2*ARG_SZ + REG_XDX], REG_XDI
        mov      [3*ARG_SZ + REG_XDX], REG_XSI
        mov      [4*ARG_SZ + REG_XDX], REG_XBP
        mov      [5*ARG_SZ + REG_XDX], REG_XSP
        mov      REG_XAX, [REG_XSP]
        mov      [6*ARG_SZ + REG_XDX], REG_XAX
#ifdef X64
        mov      [ 7*ARG_SZ + REG_XDX], r8
        mov      [ 8*ARG_SZ + REG_XDX], r9
        mov      [ 9*ARG_SZ + REG_XDX], r10
        mov      [10*ARG_SZ + REG_XDX], r11
        mov      [11*ARG_SZ + REG_XDX], r12
        mov      [12*ARG_SZ + REG_XDX], r13
        mov      [13*ARG_SZ + REG_XDX], r14
        mov      [14*ARG_SZ + REG_XDX], r15
#endif
        xor      eax, eax
        ret
        END_FUNC(dr_setjmp)

/* int cdecl dr_longjmp(dr_jmp_buf *buf, int retval);
 */
        DECLARE_FUNC(dr_longjmp)
GLOBAL_LABEL(dr_longjmp:)
        mov      REG_XDX, ARG1
        mov      REG_XAX, ARG2

        mov      REG_XBX, [       0 + REG_XDX]
        mov      REG_XDI, [2*ARG_SZ + REG_XDX]
        mov      REG_XSI, [3*ARG_SZ + REG_XDX]
        mov      REG_XBP, [4*ARG_SZ + REG_XDX]
        mov      REG_XSP, [5*ARG_SZ + REG_XDX] /* now we've switched to the old stack */
        mov      REG_XCX, [6*ARG_SZ + REG_XDX]
        mov      [REG_XSP], REG_XCX    /* restore the return address on to the stack */
        mov      REG_XCX, [  ARG_SZ + REG_XDX]
#ifdef X64
        mov      r8,  [ 7*ARG_SZ + REG_XDX]
        mov      r9,  [ 8*ARG_SZ + REG_XDX]
        mov      r10, [ 9*ARG_SZ + REG_XDX]
        mov      r11, [10*ARG_SZ + REG_XDX]
        mov      r12, [11*ARG_SZ + REG_XDX]
        mov      r13, [12*ARG_SZ + REG_XDX]
        mov      r14, [13*ARG_SZ + REG_XDX]
        mov      r15, [14*ARG_SZ + REG_XDX]
#endif
        ret
        END_FUNC(dr_longjmp)


/*#############################################################################
 *#############################################################################
 * Utility routines moved here due to the lack of inline asm support
 * in VC8.
 */

/* uint atomic_swap(uint *addr, uint value)
 * return current contents of addr and replace contents with value.
 * on win32 could use InterlockedExchange intrinsic instead.
 */
        DECLARE_FUNC(atomic_swap)
GLOBAL_LABEL(atomic_swap:)
        mov      REG_XAX, ARG2
        mov      REG_XCX, ARG1 /* nop on win64 (ditto for linux64 if used rdi) */
        xchg     [REG_XCX], eax
        ret
        END_FUNC(atomic_swap)

/* bool cpuid_supported(void)
 * Checks for existence of the cpuid instr by attempting to modify bit 21 of eflags
 */
        DECLARE_FUNC(cpuid_supported)
GLOBAL_LABEL(cpuid_supported:)
        PUSHF
        pop      REG_XAX
        mov      ecx, eax      /* original eflags in ecx */
        xor      eax, HEX(200000) /* try to modify bit 21 of eflags */
        push     REG_XAX
        POPF
        PUSHF
        pop      REG_XAX
        cmp      ecx, eax
        mov      eax, 0        /* zero out top bytes */
        setne    al
        push     REG_XCX         /* now restore original eflags */
        POPF
        ret
        END_FUNC(cpuid_supported)

/* void our_cpuid(int res[4], int eax)
 * Executes cpuid instr, which is hard for x64 inline asm b/c clobbers rbx and can't
 * push in middle of func.
 */
        DECLARE_FUNC(our_cpuid)
GLOBAL_LABEL(our_cpuid:)
        mov      REG_XDX, ARG1
        mov      REG_XAX, ARG2
        push     REG_XBX /* callee-saved */
        push     REG_XDI /* callee-saved */
        /* not making a call so don't bother w/ 16-byte stack alignment */
        mov      REG_XDI, REG_XDX
        cpuid
        mov      [ 0 + REG_XDI], eax
        mov      [ 4 + REG_XDI], ebx
        mov      [ 8 + REG_XDI], ecx
        mov      [12 + REG_XDI], edx
        pop      REG_XDI /* callee-saved */
        pop      REG_XBX /* callee-saved */
        ret
        END_FUNC(our_cpuid)

/* We could use inline asm on Linux but it's cleaner to share the same code: */
/* void dr_stmxcsr(uint *val) */
#define FUNCNAME dr_stmxcsr
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        stmxcsr  [REG_XAX]
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_xgetbv(uint *high, uint *low) */
#define FUNCNAME dr_xgetbv
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        mov      REG_XDX, ARG2
        push     REG_XAX               /* high */
        push     REG_XDX               /* low */
        mov      ecx, 0
        /* VS2005 assembler doesn't know xgetbv */
        RAW(0f) RAW(01) RAW(d0)    /* xgetbv */
        pop      REG_XCX
        mov      DWORD [REG_XCX], eax  /* low */
        pop      REG_XCX
        mov      DWORD [REG_XCX], edx  /* high */
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_fxsave(byte *buf_aligned) */
#define FUNCNAME dr_fxsave
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
#ifdef X64
        /* VS2005 doesn't know "fxsave64" (and it's "fxsaveq" for gcc 4.4) */
        RAW(48) RAW(0f) RAW(ae) RAW(00) /* fxsave64 [REG_XAX] */
#else
        fxsave   [REG_XAX]
#endif
        fnclex
        finit
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_fnsave(byte *buf_aligned) */
#define FUNCNAME dr_fnsave
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        /* FIXME: do we need an fwait prior to the fnsave? */
        fnsave   [REG_XAX]
        fwait
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_fxrstor(byte *buf_aligned) */
#define FUNCNAME dr_fxrstor
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
#ifdef X64
        /* VS2005 doesn't know "fxrstor64" */
        RAW(48) RAW(0f) RAW(ae) RAW(08) /* fxrstor64 [REG_XAX] */
#else
        fxrstor  [REG_XAX]
#endif
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_frstor(byte *buf_aligned) */
#define FUNCNAME dr_frstor
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        frstor   [REG_XAX]
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

#ifdef X64
/* void dr_fxsave32(byte *buf_aligned) */
#define FUNCNAME dr_fxsave32
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        fxsave   [REG_XAX]
        fnclex
        finit
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

/* void dr_fxrstor32(byte *buf_aligned) */
#define FUNCNAME dr_fxrstor32
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      REG_XAX, ARG1
        fxrstor  [REG_XAX]
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME
#endif

#ifdef WINDOWS /* on linux we use inline asm versions */

/* byte *get_frame_ptr(void)
 * returns the value of ebp
 */
        DECLARE_FUNC(get_frame_ptr)
GLOBAL_LABEL(get_frame_ptr:)
        mov      REG_XAX, REG_XBP
        ret
        END_FUNC(get_frame_ptr)

/*
 * void call_modcode_alt_stack(dcontext_t *dcontext,
 *                             EXCEPTION_RECORD *pExcptRec,
 *                             CONTEXT *cxt, app_pc target, uint flags,
 *                             bool using_initstack, fragment_t *f)
 * custom routine used to transfer control from check_for_modified_code()
 * to found_modified_code() win32/callback.c.
 */
#define dcontext        ARG1
#define pExcptRec       ARG2
#define cxt             ARG3
#define target          ARG4
#define flags           ARG5
#define using_initstack ARG6
#define fragment        ARG7
        DECLARE_FUNC(call_modcode_alt_stack)
GLOBAL_LABEL(call_modcode_alt_stack:)
        mov      REG_XAX, dcontext /* be careful not to clobber other in-reg params */
        mov      REG_XBX, pExcptRec
        mov      REG_XDI, cxt
        mov      REG_XSI, target
        mov      REG_XDX, flags
        mov      REG_XCX, fragment
        /* bool is byte-sized but rest should be zeroed as separate param */
        cmp      using_initstack, 0
        je       call_modcode_alt_stack_no_free
        mov      DWORD SYMREF(initstack_mutex), 0 /* rip-relative on x64 */
call_modcode_alt_stack_no_free:
        RESTORE_FROM_DCONTEXT_VIA_REG(REG_XAX,dstack_OFFSET,REG_XSP)
        CALLC6(GLOBAL_REF(found_modified_code), REG_XAX, REG_XBX, REG_XDI, REG_XSI, REG_XDX, REG_XCX)
        /* should never return */
        jmp      GLOBAL_REF(unexpected_return)
        ret
        END_FUNC(call_modcode_alt_stack)
#undef dcontext
#undef pExcptRec
#undef cxt
#undef target
#undef flags
#undef using_initstack

#ifdef STACK_GUARD_PAGE
/*
 * void call_intr_excpt_alt_stack(dcontext_t *dcontext, EXCEPTION_RECORD *pExcptRec,
 *                                CONTEXT *cxt, byte *stack)
 *
 * Routine to switch to a separate exception stack before calling
 * internal_exception_info().  This switch is useful if the dstack
 * is exhausted and we want to ensure we have enough space for
 * error reporting.
 */
#define dcontext        ARG1
#define pExcptRec       ARG2
#define cxt             ARG3
#define stack           ARG4
        DECLARE_FUNC(call_intr_excpt_alt_stack)
GLOBAL_LABEL(call_intr_excpt_alt_stack:)
        mov      REG_XAX, dcontext
        mov      REG_XBX, pExcptRec
        mov      REG_XDI, cxt
        mov      REG_XSI, REG_XSP
        mov      REG_XSP, stack
# ifdef X64
        /* retaddr + this push => 16-byte alignment prior to call */
# endif
        push     REG_XSI       /* save xsp */
        CALLC4(GLOBAL_REF(internal_exception_info), \
               REG_XAX /* dcontext */,  \
               REG_XBX /* pExcptRec */, \
               REG_XDI /* cxt */,       \
               1       /* dstack overflow == true */)
        pop      REG_XSP
        ret
        END_FUNC(call_intr_excpt_alt_stack)
#undef dcontext
#undef pExcptRec
#undef cxt
#undef stack
#endif /* STACK_GUARD_PAGE */

/* CONTEXT.Seg* is WORD for x64 but DWORD for x86 */
#ifdef X64
# define REG_XAX_SEGWIDTH ax
#else
# define REG_XAX_SEGWIDTH eax
#endif
/* Need a second volatile register for any calling convention.  In all
 * conventions, XCX is volatile, but it's ARG4 on Lin64 and ARG1 on Win64.
 * Using XCX on Win64 is fine, but on Lin64 it clobbers ARG4 so we use XDI as
 * the free reg instead.
 */
#if defined(UNIX) && defined(X64)
# define FREE_REG rdi
#else
# define FREE_REG REG_XCX
#endif
/* void get_segments_defg(cxt_seg_t *ds, cxt_seg_t *es, cxt_seg_t *fs, cxt_seg_t *gs) */
        DECLARE_FUNC(get_segments_defg)
GLOBAL_LABEL(get_segments_defg:)
        xor      eax, eax           /* Zero XAX, use it for reading segments. */
        mov      FREE_REG, ARG1
        mov      ax, ds
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        mov      FREE_REG, ARG2
        mov      ax, es
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        mov      FREE_REG, ARG3
        mov      ax, fs
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        mov      FREE_REG, ARG4
        mov      ax, gs
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        ret
        END_FUNC(get_segments_defg)

/* void get_segments_cs_ss(cxt_seg_t *cs, cxt_seg_t *ss) */
        DECLARE_FUNC(get_segments_cs_ss)
GLOBAL_LABEL(get_segments_cs_ss:)
        xor      eax, eax           /* Zero XAX, use it for reading segments. */
        mov      FREE_REG, ARG1
        mov      ax, cs
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        mov      FREE_REG, ARG2
        mov      ax, ss
        mov      [FREE_REG], REG_XAX_SEGWIDTH
        ret
        END_FUNC(get_segments_cs_ss)
#undef FREE_REG
#undef REG_XAX_SEGWIDTH

/* void get_own_context_helper(CONTEXT *cxt)
 * does not fix up xsp to match the call site
 * does not preserve callee-saved registers
 */
        DECLARE_FUNC(get_own_context_helper)
GLOBAL_LABEL(get_own_context_helper:)
        /* push callee-saved registers that we use */
        push     REG_XBX
        push     REG_XSI
        push     REG_XDI
#ifdef  X64
        /* w/ retaddr, we're now at 16-byte alignment */
        /* save argument register (PUSH_PRIV_MCXT calls out to c code) */
        mov REG_XDI, ARG1
#endif

        /* grab exec state and pass as param in a priv_mcontext_t struct */
        /* use retaddr for pc */
        PUSH_PRIV_MCXT([(3 * ARG_SZ) + REG_XSP - PUSH_PRIV_MCXT_PRE_PC_SHIFT])
        /* we don't have enough registers to avoid parameter regs so we carefully
         * use the suggested register order
         */
        lea      REG_XSI, [REG_XSP] /* stack grew down, so priv_mcontext_t at tos */
#ifdef X64
        mov      REG_XAX, REG_XDI
#else
        /* 4 * arg_sz = 3 callee saved registers pushed to stack plus return addr */
        mov      REG_XAX, [PRIV_MCXT_SIZE + (4 * ARG_SZ) + REG_XSP]
#endif
        xor      edi, edi
        mov      di, ss
        xor      ebx, ebx
        mov      bx, cs
        CALLC4(GLOBAL_REF(get_own_context_integer_control), REG_XAX, REG_XBX, REG_XDI, REG_XSI)
        add      REG_XSP, PRIV_MCXT_SIZE
        pop      REG_XDI
        pop      REG_XSI
        pop      REG_XBX
        ret
        END_FUNC(get_own_context_helper)

#endif /* WINDOWS */

/* void get_xmm_caller_saved(byte *xmm_caller_saved_buf)
 *   stores the values of xmm0 through xmm5 consecutively into xmm_caller_saved_buf.
 *   xmm_caller_saved_buf need not be 16-byte aligned.
 *   for linux, also saves xmm6-15 (PR 302107).
 *   caller must ensure that the underlying processor supports SSE!
 * FIXME PR 266305: AMD optimization guide says to use movlps+movhps for unaligned
 * stores, instead of movups (movups is best for loads): but for
 * simplicity I'm sticking with movups (assumed not perf-critical here).
 */
        DECLARE_FUNC(get_xmm_caller_saved)
GLOBAL_LABEL(get_xmm_caller_saved:)
        mov      REG_XAX, ARG1
        movups   [REG_XAX + 0*XMM_SAVED_REG_SIZE], xmm0
        movups   [REG_XAX + 1*XMM_SAVED_REG_SIZE], xmm1
        movups   [REG_XAX + 2*XMM_SAVED_REG_SIZE], xmm2
        movups   [REG_XAX + 3*XMM_SAVED_REG_SIZE], xmm3
        movups   [REG_XAX + 4*XMM_SAVED_REG_SIZE], xmm4
        movups   [REG_XAX + 5*XMM_SAVED_REG_SIZE], xmm5
#ifdef UNIX
        movups   [REG_XAX + 6*XMM_SAVED_REG_SIZE], xmm6
        movups   [REG_XAX + 7*XMM_SAVED_REG_SIZE], xmm7
#endif
#if defined(UNIX) && defined(X64)
        movups   [REG_XAX + 8*XMM_SAVED_REG_SIZE], xmm8
        movups   [REG_XAX + 9*XMM_SAVED_REG_SIZE], xmm9
        movups   [REG_XAX + 10*XMM_SAVED_REG_SIZE], xmm10
        movups   [REG_XAX + 11*XMM_SAVED_REG_SIZE], xmm11
        movups   [REG_XAX + 12*XMM_SAVED_REG_SIZE], xmm12
        movups   [REG_XAX + 13*XMM_SAVED_REG_SIZE], xmm13
        movups   [REG_XAX + 14*XMM_SAVED_REG_SIZE], xmm14
        movups   [REG_XAX + 15*XMM_SAVED_REG_SIZE], xmm15
#endif
        ret
        END_FUNC(get_xmm_caller_saved)

/* void get_ymm_caller_saved(byte *ymm_caller_saved_buf)
 *   stores the values of ymm0 through ymm5 consecutively into ymm_caller_saved_buf.
 *   ymm_caller_saved_buf need not be 32-byte aligned.
 *   for linux, also saves ymm6-15 (PR 302107).
 *   caller must ensure that the underlying processor supports SSE!
 */
        DECLARE_FUNC(get_ymm_caller_saved)
GLOBAL_LABEL(get_ymm_caller_saved:)
        mov      REG_XAX, ARG1
       /* i#441: some compilers like gcc 4.3 and VS2005 do not know "vmovdqu".
        * We just put in the raw bytes for these instrs:
        * Note the 64/32 bit have the same encoding for either rax or eax.
        * c5 fe 7f 00               vmovdqu %ymm0,0x00(%xax)
        * c5 fe 7f 48 20            vmovdqu %ymm1,0x20(%xax)
        * c5 fe 7f 50 40            vmovdqu %ymm2,0x40(%xax)
        * c5 fe 7f 58 60            vmovdqu %ymm3,0x60(%xax)
        * c5 fe 7f a0 80 00 00 00   vmovdqu %ymm4,0x80(%xax)
        * c5 fe 7f a8 a0 00 00 00   vmovdqu %ymm5,0xa0(%xax)
        */
        RAW(c5) RAW(fe) RAW(7f) RAW(00)
        RAW(c5) RAW(fe) RAW(7f) RAW(48) RAW(20)
        RAW(c5) RAW(fe) RAW(7f) RAW(50) RAW(40)
        RAW(c5) RAW(fe) RAW(7f) RAW(58) RAW(60)
        RAW(c5) RAW(fe) RAW(7f) RAW(a0) RAW(80) RAW(00) RAW(00) RAW(00)
        RAW(c5) RAW(fe) RAW(7f) RAW(a8) RAW(a0) RAW(00) RAW(00) RAW(00)
#ifdef UNIX
       /*
        * c5 fe 7f b0 c0 00 00 00   vmovdqu %ymm6,0xc0(%xax)
        * c5 fe 7f b8 e0 00 00 00   vmovdqu %ymm7,0xe0(%xax)
        */
        RAW(c5) RAW(fe) RAW(7f) RAW(b0) RAW(c0) RAW(00) RAW(00) RAW(00)
        RAW(c5) RAW(fe) RAW(7f) RAW(b8) RAW(e0) RAW(00) RAW(00) RAW(00)
# ifdef X64
       /*
        * c5 7e 7f 80 00 01 00 00   vmovdqu %ymm8, 0x100(%xax)
        * c5 7e 7f 88 20 01 00 00   vmovdqu %ymm9, 0x120(%xax)
        * c5 7e 7f 90 40 01 00 00   vmovdqu %ymm10,0x140(%xax)
        * c5 7e 7f 98 60 01 00 00   vmovdqu %ymm11,0x160(%xax)
        * c5 7e 7f a0 80 01 00 00   vmovdqu %ymm12,0x180(%xax)
        * c5 7e 7f a8 a0 01 00 00   vmovdqu %ymm13,0x1a0(%xax)
        * c5 7e 7f b0 c0 01 00 00   vmovdqu %ymm14,0x1c0(%xax)
        * c5 7e 7f b8 e0 01 00 00   vmovdqu %ymm15,0x1e0(%xax)
        */
        RAW(c5) RAW(7e) RAW(7f) RAW(80) RAW(00) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(88) RAW(20) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(90) RAW(40) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(98) RAW(60) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(a0) RAW(80) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(a8) RAW(a0) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(b0) RAW(c0) RAW(01) RAW(00) RAW(00)
        RAW(c5) RAW(7e) RAW(7f) RAW(b8) RAW(e0) RAW(01) RAW(00) RAW(00)
# endif
#endif
        ret
        END_FUNC(get_ymm_caller_saved)

/* void hashlookup_null_handler(void)
 * PR 305731: if the app targets NULL, it ends up here, which indirects
 * through hashlookup_null_target to end up in an ibl miss routine.
 */
        DECLARE_FUNC(hashlookup_null_handler)
GLOBAL_LABEL(hashlookup_null_handler:)
#if !defined(X64) && defined(LINUX)
        /* We don't have any free registers to make this PIC so we patch
         * this up.  It would be better to generate than patch .text,
         * but we need a static address to reference in null_fragment
         * (though if we used shared ibl target_delete we could
         * set our final address prior to using null_fragment anywhere).
         */
        jmp      hashlookup_null_handler
#else
        jmp      PTRSZ SYMREF(hashlookup_null_target) /* rip-relative on x64 */
#endif
        END_FUNC(hashlookup_null_handler)

#ifdef X64
# define PTRSZ_SHIFT_BITS 3
# define PTRSZ_SUFFIXED(string_op) string_op##q
# ifdef UNIX
#  define ARGS_TO_XDI_XSI_XDX()         /* ABI handles this. */
#  define RESTORE_XDI_XSI()             /* Not needed. */
# else /* WINDOWS */
/* Get args 1, 2, 3 into rdi, rsi, and rdx. */
#  define ARGS_TO_XDI_XSI_XDX() \
        push     rdi                            @N@\
        push     rsi                            @N@\
        mov      rdi, ARG1                      @N@\
        mov      rsi, ARG2                      @N@\
        mov      rdx, ARG3
#  define RESTORE_XDI_XSI() \
        pop      rsi                            @N@\
        pop      rdi
# endif /* WINDOWS */
#else
# define PTRSZ_SHIFT_BITS 2
# define PTRSZ_SUFFIXED(string_op) string_op##d

/* Get args 1, 2, 3 into edi, esi, and edx to match Linux x64 ABI.  Need to save
 * edi and esi since they are callee-saved.  The ARGN macros can't handle
 * stack adjustments, so use the scratch regs eax and ecx to hold the args
 * before the pushes.
 */
# define ARGS_TO_XDI_XSI_XDX() \
        mov     eax, ARG1                       @N@\
        mov     ecx, ARG2                       @N@\
        mov     edx, ARG3                       @N@\
        push    edi                             @N@\
        push    esi                             @N@\
        mov     edi, eax                        @N@\
        mov     esi, ecx
# define RESTORE_XDI_XSI() \
        pop esi                                 @N@\
        pop edi
#endif

/* Repeats string_op for XDX bytes using aligned pointer-sized operations when
 * possible.  Assumes that string_op works by counting down until XCX reaches
 * zero.  The pointer-sized string ops are aligned based on ptr_to_align.
 * For string ops that have both a src and dst, aligning based on src is
 * preferred, subject to micro-architectural differences.
 *
 * XXX: glibc memcpy uses SSE instructions to copy, which is 10% faster on x64
 * and ~2x faster for 20kb copies on plain x86.  Using SSE is quite complicated,
 * because it means doing cpuid checks and loop unrolling.  Many of our string
 * operations are short anyway.  For safe_read, it also increases the number of
 * potentially faulting PCs.
 */
#define REP_STRING_OP(funcname, ptr_to_align, string_op) \
        mov     REG_XCX, ptr_to_align                           @N@\
        and     REG_XCX, (ARG_SZ - 1)                           @N@\
        jz      funcname##_aligned                              @N@\
        neg     REG_XCX                                         @N@\
        add     REG_XCX, ARG_SZ                                 @N@\
        cmp     REG_XDX, REG_XCX  /* if (n < xcx) */            @N@\
        cmovb   REG_XCX, REG_XDX  /*     xcx = n; */            @N@\
        sub     REG_XDX, REG_XCX                                @N@\
ADDRTAKEN_LABEL(funcname##_pre:)                                @N@\
        rep string_op##b                                        @N@\
funcname##_aligned:                                             @N@\
        /* Aligned word-size ops. */                            @N@\
        mov     REG_XCX, REG_XDX                                @N@\
        shr     REG_XCX, PTRSZ_SHIFT_BITS                       @N@\
ADDRTAKEN_LABEL(funcname##_mid:)                                @N@\
        rep PTRSZ_SUFFIXED(string_op)                           @N@\
        /* Handle trailing bytes. */                            @N@\
        mov     REG_XCX, REG_XDX                                @N@\
        and     REG_XCX, (ARG_SZ - 1)                           @N@\
ADDRTAKEN_LABEL(funcname##_post:)                               @N@\
        rep string_op##b

/* Declare these labels global so we can take their addresses in C.  pre, mid,
 * and post are defined by REP_STRING_OP().
 */
DECLARE_GLOBAL(safe_read_asm_pre)
DECLARE_GLOBAL(safe_read_asm_mid)
DECLARE_GLOBAL(safe_read_asm_post)
DECLARE_GLOBAL(safe_read_asm_recover)

/* i#350: We implement safe_read in assembly and save the PCs that can fault.
 * If these PCs fault, we return from the signal handler to the epilog, which
 * can recover.  We return the source pointer from XSI, and the caller uses this
 * to determine how many bytes were copied and whether it matches size.
 *
 * XXX: Do we care about differentiating whether the read or write faulted?
 * Currently this is just "safe_memcpy", and we recover regardless of whether
 * the read or write faulted.
 *
 * void *
 * safe_read_asm(void *dst, const void *src, size_t n);
 */
        DECLARE_FUNC(safe_read_asm)
GLOBAL_LABEL(safe_read_asm:)
        ARGS_TO_XDI_XSI_XDX()           /* dst=xdi, src=xsi, n=xdx */
        /* Copy xdx bytes, align on src. */
        REP_STRING_OP(safe_read_asm, REG_XSI, movs)
ADDRTAKEN_LABEL(safe_read_asm_recover:)
        mov     REG_XAX, REG_XSI        /* Return cur_src */
        RESTORE_XDI_XSI()
        ret
        END_FUNC(safe_read_asm)

#ifdef UNIX
/* i#46: Implement private memcpy and memset for libc isolation.  If we import
 * memcpy and memset from libc in the normal way, the application can override
 * those definitions and intercept them.  In particular, this occurs when
 * running an app that links in the Address Sanitizer runtime.  Since we already
 * need a reasonably efficient assembly memcpy implementation for safe_read, we
 * go ahead and reuse the code for private memcpy and memset.
 *
 * XXX: See comment on REP_STRING_OP about maybe using SSE instrs.  It's more
 * viable for memcpy and memset than for safe_read_asm.
 */

/* Private memcpy.
 */
        DECLARE_FUNC(memcpy)
GLOBAL_LABEL(memcpy:)
        ARGS_TO_XDI_XSI_XDX()           /* dst=xdi, src=xsi, n=xdx */
        mov    REG_XAX, REG_XDI         /* Save dst for return. */
        /* Copy xdx bytes, align on src. */
        REP_STRING_OP(memcpy, REG_XSI, movs)
        RESTORE_XDI_XSI()
        ret                             /* Return original dst. */
        END_FUNC(memcpy)

/* Private memset.
 */
        DECLARE_FUNC(memset)
GLOBAL_LABEL(memset:)
        ARGS_TO_XDI_XSI_XDX()           /* dst=xdi, val=xsi, n=xdx */
        push    REG_XDI                 /* Save dst for return. */
        test    esi, esi                /* Usually val is zero. */
        jnz     make_val_word_size
        xor     eax, eax
do_memset:
        /* Set xdx bytes, align on dst. */
        REP_STRING_OP(memset, REG_XDI, stos)
        pop     REG_XAX                 /* Return original dst. */
        RESTORE_XDI_XSI()
        ret

        /* Create pointer-sized value in XAX using multiply. */
make_val_word_size:
        and     esi, HEX(ff)
# ifdef X64
        mov     rax, HEX(0101010101010101)
# else
        mov     eax, HEX(01010101)
# endif
        /* Use two-operand imul to avoid clobbering XDX. */
        imul    REG_XAX, REG_XSI
        jmp     do_memset
        END_FUNC(memset)


# ifndef MACOS /* XXX: attribute alias issue, plus using nasm */
/* gcc emits calls to these *_chk variants in release builds when the size of
 * dst is known at compile time.  In C, the caller is responsible for cleaning
 * up arguments on the stack, so we alias these *_chk routines to the non-chk
 * routines and rely on the caller to clean up the extra dst_len arg.
 */
.global __memcpy_chk
.hidden __memcpy_chk
.set __memcpy_chk,memcpy

.global __memset_chk
.hidden __memset_chk
.set __memset_chk,memset
# endif


/* Replacement for _dl_runtime_resolve() used for catching module transitions
 * out of native modules.
 */
        DECLARE_FUNC(_dynamorio_runtime_resolve)
GLOBAL_LABEL(_dynamorio_runtime_resolve:)
# ifdef X64
        /* Preserve all 6 argument registers and rax (num fp reg args). */
        push     rax
        push     rdi
        push     rsi
        push     rdx
        push     rcx
        push     r8
        push     r9

        /* Should be 16-byte aligned now: retaddr, 2 args, 7 regs. */
        mov      rdi, [rsp + 7 * ARG_SZ]        /* link map */
        mov      rsi, [rsp + 8 * ARG_SZ]        /* .dynamic index */
        CALLC0(GLOBAL_REF(dynamorio_dl_fixup))
        mov      r11, rax                       /* preserve */

        pop      r9
        pop      r8
        pop      rcx
        pop      rdx
        pop      rsi
        pop      rdi
        pop      rax

        add      rsp, 16        /* clear args */
        jmp      r11            /* Jump to resolved PC, or into DR. */
# else /* !X64 */
        push     REG_XAX
        push     REG_XCX
        mov      REG_XAX, [REG_XSP + 2 * ARG_SZ]  /* link map */
        mov      REG_XCX, [REG_XSP + 3 * ARG_SZ]  /* .dynamic index */
#  ifdef MACOS
        lea      REG_XSP, [-1*ARG_SZ + REG_XSP] /* maintain align-16: ra + push x2 */
#  endif
        CALLC2(GLOBAL_REF(dynamorio_dl_fixup), REG_XAX, REG_XCX)
#  ifdef MACOS
        lea      REG_XSP, [1*ARG_SZ + REG_XSP] /* maintain align-16: ra + push x2 */
#  endif
        mov      [REG_XSP + 2 * ARG_SZ], REG_XAX /* overwrite arg1 */
        pop      REG_XCX
        pop      REG_XAX
        ret      4 /* ret to target, pop arg2 */
# endif /* !X64 */
        END_FUNC(_dynamorio_runtime_resolve)

#endif /* UNIX */

/*#############################################################################
 *#############################################################################
 */

/****************************************************************************/
/****************************************************************************/
#endif /* !NOT_DYNAMORIO_CORE_PROPER */

/****************************************************************************
 * routines shared with NOT_DYNAMORIO_CORE_PROPER
 */

/* void dr_fpu_exception_init(void)
 * sets the exception mask flags for both regular float and xmm packed float
 */
#define FUNCNAME dr_fpu_exception_init
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        fninit
        push     HEX(1f80)
        ldmxcsr  DWORD [REG_XSP]
        pop      REG_XAX
        ret
        END_FUNC(FUNCNAME)
#undef FUNCNAME

#ifdef WINDOWS

/* byte *get_stack_ptr(void)
 * returns the value of xsp before the call
 */
        DECLARE_FUNC(get_stack_ptr)
GLOBAL_LABEL(get_stack_ptr:)
        mov      REG_XAX, REG_XSP
        add      REG_XAX, ARG_SZ /* remove return address space */
        ret
        END_FUNC(get_stack_ptr)

/* void load_dynamo(void)
 *
 * used for injection into a child process
 * N.B.:  if the code here grows, SIZE_OF_LOAD_DYNAMO in win32/inject.c
 * must be updated.
 */
        DECLARE_FUNC(load_dynamo)
GLOBAL_LABEL(load_dynamo:)
    /* the code for this routine is copied into an allocation in the app
       and invoked upon return from the injector. When it is invoked,
       it expects the app's stack to look like this:

                xsp-->| &LoadLibrary  |  for x64 xsp must be 16-aligned
                      | &dynamo_path  |
                      | &GetProcAddr  |
                      | &dynamo_entry |___
                      |               |   |
                      |(saved context)| priv_mcontext_t struct
                      | &code_alloc   |   | pointer to the code allocation
                      | sizeof(code_alloc)| size of the code allocation
                      |_______________|___| (possible padding for x64 xsp alignment)
       &dynamo_path-->|               |   |
                      | (dynamo path) | TEXT(DYNAMORIO_DLL_PATH)
                      |_______________|___|
      &dynamo_entry-->|               |   |
                      | (dynamo entry)| "dynamo_auto_start"
                      |               |___|


        in separate allocation         ___
                      |               |   |
                      |     CODE      |  load_dynamo() code
                      |               |___|

        The load_dynamo routine will load the dynamo DLL into memory, then jump
        to its dynamo_auto_start entry point, passing it the saved app context as
        parameters.
     */
        /* two byte NOP to satisfy third party braindead-ness documented in case 3821 */
        mov      edi, edi
#ifdef LOAD_DYNAMO_DEBUGBREAK
        /* having this code in front may hide the problem addressed with the
         * above padding */
        /* giant loop so can attach debugger, then change ebx to 1
         * to step through rest of code */
        mov      ebx, HEX(7fffffff)
load_dynamo_repeat_outer:
        mov      eax, HEX(7fffffff)
load_dynamo_repeatme:
        dec      eax
        cmp      eax, 0
        jg       load_dynamo_repeatme
        dec      ebx
        cmp      ebx, 0
        jg       load_dynamo_repeat_outer

# ifdef X64
        /* xsp is 8-aligned and our pop makes it 16-aligned */
# endif
        /* TOS has &DebugBreak */
        pop      REG_XBX /* pop   REG_XBX = &DebugBreak */
        CALLWIN0(REG_XBX) /* call DebugBreak  (in kernel32.lib) */
#endif
        /* TOS has &LoadLibraryA */
        pop      REG_XBX /* pop   REG_XBX = &LoadLibraryA */
        /* TOS has &dynamo_path */
        pop      REG_XAX /* for 32-bit we're doing "pop eax, push eax" */
        CALLWIN1(REG_XBX, REG_XAX) /* call LoadLibraryA  (in kernel32.lib) */

        /* check result */
        cmp      REG_XAX, 0
        jne      load_dynamo_success
        pop      REG_XBX /* pop off &GetProcAddress */
        pop      REG_XBX /* pop off &dynamo_entry */
        jmp      load_dynamo_failure
load_dynamo_success:
        /* TOS has &GetProcAddress */
        pop      REG_XBX /* pop   REG_XBX = &GetProcAddress */
        /* dynamo_handle is now in REG_XAX (returned by call LoadLibrary) */
        /* TOS has &dynamo_entry */
        pop      REG_XDI /* for 32-bit we're doing "pop edi, push edi" */
        CALLWIN2(REG_XBX, REG_XAX, REG_XDI) /* call GetProcAddress */
        cmp      REG_XAX, 0
        je       load_dynamo_failure

        /* jump to dynamo_auto_start (returned by GetProcAddress) */
        jmp      REG_XAX
        /* dynamo_auto_start will take over or continue natively at the saved
         * context via load_dynamo_failure.
        */
        END_FUNC(load_dynamo)
/* N.B.: load_dynamo_failure MUST follow load_dynamo, as both are
 * copied in one fell swoop by inject_into_thread()!
 */
/* not really a function but having issues getting both masm and gas to
 * let other asm routines jump here.
 * targeted by load_dynamo and dynamo_auto_start by a jump, not a call,
 * when we should not take over and should go native instead.
 * Xref case 7654: we come here to the child's copy from dynamo_auto_start
 * instead of returning to the parent's copy post-load_dynamo to avoid
 * incompatibilites with stack layout accross dr versions.
 */
        DECLARE_FUNC(load_dynamo_failure)
GLOBAL_LABEL(load_dynamo_failure:)
        /* Would be nice if we could free our allocation here as well, but
         * that's too much of a pain (esp. here).
         * Note TOS has the saved context at this point, xref layout in
         * auto_setup. Note this code is duplicated in dynamo_auto_start. */
        mov      REG_XAX, [MCONTEXT_XSP_OFFS + REG_XSP] /* load app xsp */
        mov      REG_XBX, [MCONTEXT_PC_OFFS + REG_XSP] /* load app start_pc */
        /* write app start_pc off top of app stack */
        mov      [-ARG_SZ + REG_XAX], REG_XBX
        /* it's ok to write past app TOS since we're just overwriting part of
         * the dynamo_entry string which is dead at this point, won't affect
         * the popping of the saved context */
        POPGPR
        POPF
        /* we assume reading beyond TOS is ok here (no signals on windows) */
        /* we assume xmm0-5 do not need to be restored */
        /* restore app xsp (POPGPR doesn't) */
        mov      REG_XSP, [-MCONTEXT_PC_OFFS + MCONTEXT_XSP_OFFS + REG_XSP]
        jmp      PTRSZ [-ARG_SZ + REG_XSP]      /* jmp to app start_pc */

        ret
        END_FUNC(load_dynamo_failure)


/***************************************************************************/
#ifndef X64

/* Routines to switch to 64-bit mode from 32-bit WOW64, make a 64-bit
 * call, and then return to 32-bit mode.
 */

/* FIXME: check these selector values on all platforms: these are for XPSP2.
 * Keep in synch w/ defines in arch.h.
 */
# define CS32_SELECTOR HEX(23)
# define CS64_SELECTOR HEX(33)

/*
 * int switch_modes_and_load(void *ntdll64_LdrLoadDll,
 *                           UNICODE_STRING_64 *lib,
 *                           HANDLE *result)
 */
# define FUNCNAME switch_modes_and_load
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        /* get args before we change esp */
        mov      eax, ARG1
        mov      ecx, ARG2
        mov      edx, ARG3
        /* save callee-saved registers */
        push     ebx
        /* far jmp to next instr w/ 64-bit switch: jmp 0033:<sml_transfer_to_64> */
        RAW(ea)
        DD offset sml_transfer_to_64
        DB CS64_SELECTOR
        RAW(00)
sml_transfer_to_64:
    /* Below here is executed in 64-bit mode, but with guarantees that
     * no address is above 4GB, as this is a WOW64 process.
     */
       /* Call LdrLoadDll to load 64-bit lib:
        *   LdrLoadDll(IN PWSTR DllPath OPTIONAL,
        *              IN PULONG DllCharacteristics OPTIONAL,
        *              IN PUNICODE_STRING DllName,
        *              OUT PVOID *DllHandle));
        */
        RAW(4c) RAW(8b) RAW(ca)  /* mov r9, rdx : 4th arg: result */
        RAW(4c) RAW(8b) RAW(c1)  /* mov r8, rcx : 3rd arg: lib */
        push     0               /* slot for &DllCharacteristics */
        lea      edx, dword ptr [esp] /* 2nd arg: &DllCharacteristics */
        xor      ecx, ecx        /* 1st arg: DllPath = NULL */
        /* save WOW64 state */
        RAW(41) push     esp /* push r12 */
        RAW(41) push     ebp /* push r13 */
        RAW(41) push     esi /* push r14 */
        RAW(41) push     edi /* push r15 */
        /* align the stack pointer */
        mov      ebx, esp        /* save esp in callee-preserved reg */
        sub      esp, 32         /* call conv */
        and      esp, HEX(fffffff0) /* align to 16-byte boundary */
        call     eax
        mov      esp, ebx        /* restore esp */
        /* restore WOW64 state */
        RAW(41) pop      edi /* pop r15 */
        RAW(41) pop      esi /* pop r14 */
        RAW(41) pop      ebp /* pop r13 */
        RAW(41) pop      esp /* pop r12 */
        /* far jmp to next instr w/ 32-bit switch: jmp 0023:<sml_return_to_32> */
        push     offset sml_return_to_32  /* 8-byte push */
        mov      dword ptr [esp + 4], CS32_SELECTOR /* top 4 bytes of prev push */
        jmp      fword ptr [esp]
sml_return_to_32:
        add      esp, 16         /* clean up far jmp target and &DllCharacteristics */
        pop      ebx             /* restore callee-saved reg */
        ret                      /* return value already in eax */
        END_FUNC(FUNCNAME)

/*
 * int switch_modes_and_call(void_func_t func, void *arg1, void *arg2, void *arg3)
 */
# undef FUNCNAME
# define FUNCNAME switch_modes_and_call
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        mov      eax, ARG1
        mov      ecx, ARG2
        mov      edx, ARG3
        /* save callee-saved registers */
        push     ebx
        mov      ebx, ARG4
        /* far jmp to next instr w/ 64-bit switch: jmp 0033:<smc_transfer_to_64> */
        RAW(ea)
        DD offset smc_transfer_to_64
        DB CS64_SELECTOR
        RAW(00)
smc_transfer_to_64:
    /* Below here is executed in 64-bit mode, but with guarantees that
     * no address is above 4GB, as this is a WOW64 process.
     */
        /* save WOW64 state */
        RAW(41) push     esp /* push r12 */
        RAW(41) push     ebp /* push r13 */
        RAW(41) push     esi /* push r14 */
        RAW(41) push     edi /* push r15 */
        RAW(44) mov      eax, ebx /* mov ARG4 in ebx to r8d (3rd arg slot) */
        /* align the stack pointer */
        mov      ebx, esp        /* save esp in callee-preserved reg */
        sub      esp, 32         /* call conv */
        and      esp, HEX(fffffff0) /* align to 16-byte boundary */
        call     eax             /* arg1 is already in rcx and arg2 in rdx */
        mov      esp, ebx        /* restore esp */
        /* restore WOW64 state */
        RAW(41) pop      edi /* pop r15 */
        RAW(41) pop      esi /* pop r14 */
        RAW(41) pop      ebp /* pop r13 */
        RAW(41) pop      esp /* pop r12 */
        /* far jmp to next instr w/ 32-bit switch: jmp 0023:<smc_return_to_32> */
        push     offset smc_return_to_32  /* 8-byte push */
        mov      dword ptr [esp + 4], CS32_SELECTOR /* top 4 bytes of prev push */
        jmp      fword ptr [esp]
smc_return_to_32:
        add      esp, 8          /* clean up far jmp target */
        pop      ebx             /* restore callee-saved reg */
        ret                      /* return value already in eax */
        END_FUNC(FUNCNAME)

/*
 * DR_API ptr_int_t
 * dr_invoke_x64_routine(dr_auxlib64_routine_ptr_t func64, uint num_params, ...)
 */
# undef FUNCNAME
# define FUNCNAME dr_invoke_x64_routine
        DECLARE_EXPORTED_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        /* This is 32-bit so we just need the stack ptr to locate all the args */
        mov      eax, esp
        /* save callee-saved registers */
        push     ebx
        /* far jmp to next instr w/ 64-bit switch: jmp 0033:<inv64_transfer_to_64> */
        RAW(ea)
        DD offset inv64_transfer_to_64
        DB CS64_SELECTOR
        RAW(00)
inv64_transfer_to_64:
    /* Below here is executed in 64-bit mode, but with guarantees that
     * no address is above 4GB, as this is a WOW64 process.
     */
        /* Save WOW64 state.
         * FIXME: if the x64 code makes any callbacks, not only do we need
         * a wrapper to go back to x86 mode but we need to restore these
         * values in case the x86 callback invokes any syscalls!
         * Really messy and fragile.
         */
        RAW(41) push     esp /* push r12 */
        RAW(41) push     ebp /* push r13 */
        RAW(41) push     esi /* push r14 */
        RAW(41) push     edi /* push r15 */
        /* align the stack pointer */
        mov      ebx, esp        /* save esp in callee-preserved reg */
        sub      esp, 32         /* call conv */
        mov      ecx, dword ptr [12 + eax] /* #args (func64 takes two slots) */
        sub      ecx, 4
        jle      inv64_arg_copy_done
        shl      ecx, 3          /* (#args-4)*8 */
        sub      esp, ecx        /* slots for args */
        and      esp, HEX(fffffff0) /* align to 16-byte boundary */
        /* copy the args to their stack slots (simpler to copy the 1st 4 too) */
        mov      ecx, dword ptr [12 + eax] /* #args */
        cmp      ecx, 0
        je       inv64_arg_copy_done
inv64_arg_copy_loop:
        mov      edx, dword ptr [12 + 4*ecx + eax] /* ecx = 1-based arg ordinal */
        /* FIXME: sign-extension is not always what the user wants.
         * But the only general way to solve it would be to take in type codes
         * for each arg!
         */
        RAW(48) RAW(63) RAW(d2)  /* movsxd rdx, edx  (sign-extend) */
        RAW(48)  /* qword ptr */
        mov      dword ptr [-8 + 8*ecx + esp], edx
        sub      ecx, 1 /* we can't use "dec" as it will be encoded wrong! */
        jnz      inv64_arg_copy_loop
inv64_arg_copy_done:
        /* put the 1st 4 args into their reg slots */
        mov      ecx, dword ptr [12 + eax] /* #args */
        cmp      ecx, 4
        jl       inv64_arg_lt4
        mov      edx, dword ptr [12 + 4*4 + eax] /* 1-based arg ordinal */
        RAW(4c) RAW(63) RAW(ca) /* movsxd r9, edx */
inv64_arg_lt4:
        cmp      ecx, 3
        jl       inv64_arg_lt3
        mov      edx, dword ptr [12 + 4*3 + eax] /* 1-based arg ordinal */
        RAW(4c) RAW(63) RAW(c2) /* movsxd r8, edx */
inv64_arg_lt3:
        cmp      ecx, 2
        jl       inv64_arg_lt2
        mov      edx, dword ptr [12 + 4*2 + eax] /* 1-based arg ordinal */
        RAW(48) RAW(63) RAW(d2)  /* movsxd rdx, edx  (sign-extend) */
inv64_arg_lt2:
        cmp      ecx, 1
        jl       inv64_arg_lt1
        mov      ecx, dword ptr [12 + 4*1 + eax] /* 1-based arg ordinal */
        RAW(48) RAW(63) RAW(c9)  /* movsxd rcx, ecx  (sign-extend) */
inv64_arg_lt1:
        /* make the call */
        RAW(48)  /* qword ptr */
        mov      eax, dword ptr [4 + eax] /* func64 */
        RAW(48) call     eax
        /* get top 32 bits of return value into edx for 64-bit x86 return value */
        RAW(48) mov      edx, eax
        RAW(48) shr      edx, 32
        mov      esp, ebx        /* restore esp */
        /* restore WOW64 state */
        RAW(41) pop      edi /* pop r15 */
        RAW(41) pop      esi /* pop r14 */
        RAW(41) pop      ebp /* pop r13 */
        RAW(41) pop      esp /* pop r12 */
        /* far jmp to next instr w/ 32-bit switch: jmp 0023:<inv64_return_to_32> */
        push     offset inv64_return_to_32  /* 8-byte push */
        mov      dword ptr [esp + 4], CS32_SELECTOR /* top 4 bytes of prev push */
        jmp      fword ptr [esp]
inv64_return_to_32:
        add      esp, 8          /* clean up far jmp target */
        pop      ebx             /* restore callee-saved reg */
        ret                      /* return value in edx:eax */
        END_FUNC(FUNCNAME)

#endif /* !X64 */
/***************************************************************************/


# ifndef NOT_DYNAMORIO_CORE_PROPER
/* void dynamorio_earliest_init_takeover(void)
 *
 * Called from hook code for earliest injection.
 * Since we want to resume at the hooked app code as though nothing
 * happened w/o going first to hooking code to restore regs, caller
 * passed us args pointed at by xax.  We then preserve regs and call
 * C code.  C code takes over when it returns to use.  We restore
 * regs and return to app code.
 * Executes on app stack but we assume app stack is fine at this point.
 */
        DECLARE_EXPORTED_FUNC(dynamorio_earliest_init_takeover)
GLOBAL_LABEL(dynamorio_earliest_init_takeover:)
        PUSHGPR
# ifdef EARLIEST_INIT_DEBUGBREAK
        /* giant loop so can attach debugger, then change ebx to 1
         * to step through rest of code */
        mov      ebx, HEX(7fffffff)
dynamorio_earliest_init_repeat_outer:
        mov      esi, HEX(7fffffff)
dynamorio_earliest_init_repeatme:
        dec      esi
        cmp      esi, 0
        jg       dynamorio_earliest_init_repeatme
        dec      ebx
        cmp      ebx, 0
        jg       dynamorio_earliest_init_repeat_outer
# endif
        /* args are pointed at by xax */
        CALLC1(GLOBAL_REF(dynamorio_earliest_init_takeover_C), REG_XAX)
        /* we will either be under DR control or running natively at this point */

        /* restore */
        POPGPR
        ret
        END_FUNC(dynamorio_earliest_init_takeover)
# endif /* NOT_DYNAMORIO_CORE_PROPER */

#endif /* WINDOWS */

END_FILE
