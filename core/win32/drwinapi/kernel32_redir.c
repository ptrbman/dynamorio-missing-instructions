/* **********************************************************
 * Copyright (c) 2011-2013 Google, Inc.   All rights reserved.
 * Copyright (c) 2009-2010 Derek Bruening   All rights reserved.
 * **********************************************************/

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

/* kernel32 and kernelbase redirection routines */

#include "../../globals.h"
#include "drwinapi.h"
#include "drwinapi_private.h"
#include "kernel32_redir.h"

#ifndef WINDOWS
# error Windows-only
#endif

static const redirect_import_t redirect_kernel32[] = {
    /* To avoid the FlsCallback being interpreted */
    {"FlsAlloc",                       (app_pc)redirect_FlsAlloc},
    /* As an initial interception of loader queries, but simpler than
     * intercepting Ldr*: plus, needed to intercept FlsAlloc called by msvcrt
     * init routine.
     * XXX i#235: redirect GetModuleHandle{ExA,ExW} as well
     */
    {"GetModuleHandleA",               (app_pc)redirect_GetModuleHandleA},
    {"GetModuleHandleW",               (app_pc)redirect_GetModuleHandleW},
    {"GetProcAddress",                 (app_pc)redirect_GetProcAddress},
    {"LoadLibraryA",                   (app_pc)redirect_LoadLibraryA},
    {"LoadLibraryW",                   (app_pc)redirect_LoadLibraryW},
    {"GetModuleFileNameA",             (app_pc)redirect_GetModuleFileNameA},
    {"GetModuleFileNameW",             (app_pc)redirect_GetModuleFileNameW},
};
#define REDIRECT_KERNEL32_NUM (sizeof(redirect_kernel32)/sizeof(redirect_kernel32[0]))

void
kernel32_redir_init(void)
{
    kernel32_redir_init_proc();
}

void
kernel32_redir_exit(void)
{
    kernel32_redir_exit_proc();
}

void
kernel32_redir_onload(privmod_t *mod)
{
    if (!dynamo_initialized)
        SELF_UNPROTECT_DATASEC(DATASEC_RARELY_PROT);

    /* Rather than statically linking to real kernel32 we want to invoke
     * routines in the private kernel32 so we look them up here.
     */

    /* XP's kernel32!SetLastError is forwarded on xp64, and our
     * get_proc_address_ex can't handle forwarded exports, so we directly
     * invoke the Rtl version that it forwards to.  On win7 it's not
     * forwarded but just calls the Rtl directly.  On 2K or earlier though
     * there is no Rtl version (so we can't statically link).
     */
    priv_SetLastError = (void (WINAPI *)(DWORD))
        get_proc_address_ex(get_ntdll_base(), "RtlSetLastWin32Error", NULL);
    if (priv_SetLastError == NULL) {
        priv_SetLastError = (void (WINAPI *)(DWORD))
            get_proc_address_ex(mod->base, "SetLastError", NULL);
        ASSERT(priv_SetLastError != NULL);
    }

    kernel32_redir_onload_proc(mod);
    kernel32_redir_onload_lib(mod);

    if (!dynamo_initialized)
        SELF_PROTECT_DATASEC(DATASEC_RARELY_PROT);
}

/* We assume the caller has already ruled out kernel32 calling into kernelbase,
 * which we do not want to redirect.
 */
app_pc
kernel32_redir_lookup(const char *name)
{
    uint i;
    for (i = 0; i < REDIRECT_KERNEL32_NUM; i++) {
        if (strcasecmp(name, redirect_kernel32[i].name) == 0) {
            return redirect_kernel32[i].func;
        }
    }
    return NULL;
}

