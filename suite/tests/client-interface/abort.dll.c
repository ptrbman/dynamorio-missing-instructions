/* **********************************************************
 * Copyright (c) 2013 Google, Inc.  All rights reserved.
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
#include <limits.h>

static ptr_uint_t global_var;
static ptr_int_t var0, var1, var2;

static void
my_abort(
#ifdef X64
         int ignore0, int ignore1, int ignore2, int ignore3,
# ifdef UNIX
         int ignore4, int ignore5,
# endif
#endif
         /* the rest of these are passed on the stack */
         ptr_uint_t arg0, ptr_int_t arg1, ptr_int_t arg2)
{
    if (arg0 != global_var || arg1 != -1 || arg2 != 1)
        dr_fprintf(STDERR, "Error on push_imm\n");
    if (var0 != arg0 || var1 != arg1 || var2 != arg2)
        dr_fprintf(STDERR, "Error on mov_imm\n");
    dr_fprintf(STDERR, "aborting now\n");
    dr_abort();
}

#define MINSERT instrlist_meta_preinsert
#ifdef UNIX
# define IF_UNIX_ELSE(x,y) x
#else
# define IF_UNIX_ELSE(x,y) y
#endif

static dr_emit_flags_t
bb_event(void* drcontext, void *tag, instrlist_t* bb, bool for_trace, bool translating)
{
    instr_t* instr = instrlist_first(bb);
    instr_t *ins1, *ins2;

    global_var = (ptr_uint_t)INT_MAX + 1;

    dr_prepare_for_call(drcontext, bb, instr);

    /* test push_imm */
    instrlist_insert_push_immed_ptrsz(drcontext, (ptr_int_t)1,
                                      bb, instr, &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
    if (ins2 != NULL) /* ins2 should be NULL */
        dr_fprintf(STDERR, "Error on push 1\n");
    instrlist_insert_push_immed_ptrsz(drcontext, (ptr_int_t)-1,
                                      bb, instr, &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
    if (ins2 != NULL) /* ins2 should be NULL */
        dr_fprintf(STDERR, "Error on push -1\n");
    instrlist_insert_push_immed_ptrsz(drcontext, global_var,
                                      bb, instr, &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
#ifdef X64
    if (ins2 == NULL) /* ins2 should not be NULL */
        dr_fprintf(STDERR, "Error on push tag\n");
    else
        instr_set_ok_to_mangle(ins2, false);
#endif

    /* test mov_imm */
    instrlist_insert_mov_immed_ptrsz(drcontext, global_var,
                                     OPND_CREATE_ABSMEM(&var0, OPSZ_PTR),
                                     bb, instr,
                                     &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
#ifdef X64
    if (ins2 == NULL) /* ins2 should not be NULL */
        dr_fprintf(STDERR, "Error on mov %p\n", global_var);
    else
        instr_set_ok_to_mangle(ins2, false);
#endif
    instrlist_insert_mov_immed_ptrsz(drcontext, (ptr_int_t)-1,
                                     OPND_CREATE_ABSMEM(&var1, OPSZ_PTR),
                                     bb, instr, &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
    if (ins2 != NULL) /* ins2 should be NULL */
        dr_fprintf(STDERR, "Error on mov -1\n");
    instrlist_insert_mov_immed_ptrsz(drcontext, (ptr_int_t)1,
                                     OPND_CREATE_ABSMEM(&var2, OPSZ_PTR),
                                     bb, instr, &ins1, &ins2);
    instr_set_ok_to_mangle(ins1, false);
    if (ins2 != NULL) /* ins2 should be NULL */
        dr_fprintf(STDERR, "Error on mov 1\n");

#if defined(WINDOWS) && defined(X64)
    /* calling convention: 4 stack slots */
    MINSERT(bb, instr, INSTR_CREATE_lea
            (drcontext,
             opnd_create_reg(DR_REG_RSP),
             opnd_create_base_disp(DR_REG_RSP, DR_REG_NULL, 0, -32, OPSZ_lea)));
#endif
    /* call */
    MINSERT(bb, instr, INSTR_CREATE_call
            (drcontext, opnd_create_pc((void*)my_abort)));
        
    dr_cleanup_after_call(drcontext, bb, instr, 0);

    return DR_EMIT_DEFAULT;
}

DR_EXPORT
void
dr_init(client_id_t id)
{
    dr_register_bb_event(bb_event);
}

