/* *******************************************************************************
 * Copyright (c) 2014 Google, Inc.  All rights reserved.
 * *******************************************************************************/

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
 * * Neither the name of Google, Inc. nor the names of its contributors may be
 *   used to endorse or promote products derived from this software without
 *   specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL GOOGLE, INC. OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */

/*
 * tls_linux_arm.c - TLS support on ARM
 */

#include <stddef.h> /* offsetof */
#include "../globals.h"
#include "tls.h"
#include "include/syscall.h"

#ifndef LINUX
# error Linux-only
#endif

#ifndef ARM
# error ARM-only
#endif

#ifndef CLIENT_INTERFACE
# error CLIENT_INTERFACE build only for TLS mangling on ARM
#endif

byte **
get_dr_tls_base_addr(void)
{
    byte *lib_tls_base = (byte *)read_thread_register(TLS_REG_LIB);
    if (lib_tls_base == NULL)
        return NULL;
    return (byte **)(lib_tls_base + DR_TLS_BASE_OFFSET);
}

void
tls_thread_init(os_local_state_t *os_tls, byte *segment)
{
    ASSERT((byte *)(os_tls->self) == segment);
    LOG(GLOBAL, LOG_THREADS, 2,
        "tls_thread_init: cur priv lib tls base is"PFX"\n",
        os_tls->os_seg_info.priv_lib_tls_base);
     dynamorio_syscall(SYS_set_tls, 1, os_tls->os_seg_info.priv_lib_tls_base);
     ASSERT(get_segment_base(TLS_REG_LIB) == os_tls->os_seg_info.priv_lib_tls_base);
     ASSERT(*get_dr_tls_base_addr() == NULL);
     *get_dr_tls_base_addr() = segment;
    os_tls->tls_type = TLS_TYPE_SLOT;
}

void
tls_thread_free(tls_type_t tls_type, int index)
{
    byte **dr_tls_base_addr;
    os_local_state_t *os_tls;

    ASSERT(tls_type == TLS_TYPE_SLOT);
    dr_tls_base_addr = get_dr_tls_base_addr();
    ASSERT(dr_tls_base_addr != NULL);
    os_tls = (os_local_state_t *)*dr_tls_base_addr;
    ASSERT(os_tls->self == os_tls);
    /* FIXME i#1578: support detach on ARM.  We need some way to
     * determine whether a thread has exited (for deadlock_avoidance_unlock,
     * e.g.) after dcontext and os_tls are freed.  For now we store -1 in this
     * slot and assume the app will never use that value (we check in
     * os_enter_dynamorio()).
     */
    *dr_tls_base_addr = TLS_SLOT_VAL_EXITED;
    return;
}
