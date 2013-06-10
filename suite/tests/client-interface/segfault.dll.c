/* **********************************************************
 * Copyright (c) 2011-2013 Google, Inc.  All rights reserved.
 * Copyright (c) 2007-2010 VMware, Inc.  All rights reserved.
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

#include "dr_api.h"

#ifdef UNIX
# include <signal.h>
#endif

#ifdef UNIX
static dr_signal_action_t
signal_event(void *dcontext, dr_siginfo_t *info)
{
    static int count;
    /* Test i#1045: cross-page access address */
    if (info->sig == SIGSEGV) {
        if (count++ == 0 && info->access_address == NULL)
            dr_fprintf(STDERR, "First fault is not accessing NULL!\n");
    }
    return DR_SIGNAL_DELIVER;
}
#else
static bool
exception_event(void *dcontext, dr_exception_t *excpt)
{
    if (excpt->record->ExceptionCode != STATUS_ACCESS_VIOLATION)
        dr_fprintf(STDERR, "Unexpected fault type\n");
    return true;
}
#endif

static void
exit_event(void)
{
    dr_fprintf(STDERR, "Aborting in client exit event\n");
    /* we want to also test end-to-end w/ core dump being generated but 
     * that's hard to do in a test suite so we abort here: but that can
     * mask errors.
     */
    dr_abort();
}

DR_EXPORT void
dr_init(client_id_t id)
{
    dr_register_exit_event(exit_event);
#ifdef WINDOWS
    dr_register_exception_event(exception_event);
#else
    dr_register_signal_event(signal_event);
#endif
}

