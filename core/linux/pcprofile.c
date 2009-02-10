/* **********************************************************
 * Copyright (c) 2001-2009 VMware, Inc.  All rights reserved.
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

/* Copyright (c) 2003-2007 Determina Corp. */
/* Copyright (c) 2001-2003 Massachusetts Institute of Technology */
/* Copyright (c) 2001 Hewlett-Packard Company */

/*
 * pcprofile.c - pc sampling profiler for dynamo
 */

#include "globals.h"
#include "utils.h"
#include "fragment.h"
#include "fcache.h"
#include <string.h> /* for memset */

/* Don't use symtab, it doesn't give us anything that addr2line or
 * other post-execution tools can't (it doesn't see into shared libraries),
 * plus will want a script to process the raw data we output anyway!
 * If you put symtab back in, add dynamo option "-profexecname"
 */
#define USE_SYMTAB 0
#if USE_SYMTAB
#include "symtab.h"
static bool valid_symtab;
#endif

/* Profiling via pc sampling
 * We store the pc for dynamo and app pc's, for fragments we store the
 * tag and offset
 * In order to handle tags that aren't original program pc's we can't
 * use tag+offset as the hashtable key -- so we use fcache pc as the
 * key.  To handle deleted fragments and later fragments re-using the same
 * fcache pcs, we have a "retired" flag that we set when a fragment is
 * deleted.  Thus we can end up printing out a separate count for
 * the same pc.
 */
typedef struct _pc_profile_entry_t {
    void *                  pc;      /* the pc */
    where_am_i_t          whereami;      /* location of pc */
#ifdef DEBUG
    int                     id;      /* if in fragment, id */
#endif
    app_pc                 tag;      /* if in fragment, tag */
    uint                offset;      /* if in fragment, offset from start pc */
    bool                 trace;      /* if in fragment, is it a trace? */
    int                counter;      /* execution counter */
    bool               retired;      /* owning fragment was deleted */
    struct _pc_profile_entry_t *next;  /* for chaining entries */
} pc_profile_entry_t;

#define HASH_BITS 14

/* The timer and all data are per-thread */
typedef struct _thread_pc_info_t {
    pc_profile_entry_t **htable; /* HASH_BITS-bit addressed hash table, key is pc */
    void *special_heap;
    file_t file;
    int where[WHERE_LAST];
} thread_pc_info_t;

/* forward declarations for static functions */
static pc_profile_entry_t *pcprofile_add_entry(thread_pc_info_t *info, void *pc, int whereami);
static pc_profile_entry_t *pcprofile_lookup(thread_pc_info_t *info, void *pc);
static void pcprofile_reset(thread_pc_info_t *info);
static void pcprofile_results(thread_pc_info_t *info);

/* initialization */
void
pcprofile_thread_init(dcontext_t *dcontext)
{
    int i;
    int size = HASHTABLE_SIZE(HASH_BITS) * sizeof(pc_profile_entry_t*);

    thread_pc_info_t *info = heap_alloc(dcontext, sizeof(thread_pc_info_t)
                                    HEAPACCT(ACCT_OTHER));
    dcontext->pcprofile_field = (void *) info;
    memset(info, 0, sizeof(thread_pc_info_t));

    info->htable = (pc_profile_entry_t**) heap_alloc(dcontext, size
                                                 HEAPACCT(ACCT_OTHER));
    memset(info->htable, 0, size);
#if USE_SYMTAB
    valid_symtab = symtab_init();
#endif
    for (i = 0; i < WHERE_LAST; i++)
        info->where[i] = 0;
    info->file = open_log_file("pcsamples", NULL, 0);
    info->special_heap = special_heap_init(sizeof(pc_profile_entry_t), false /* no locks */,
                                           false /* -x */, true /* persistent */);

    start_itimer(dcontext);
}

/* cleanup */
void
pcprofile_thread_exit(dcontext_t *dcontext)
{
    int size;
    thread_pc_info_t *info = (thread_pc_info_t *) dcontext->pcprofile_field;

    /* don't want any alarms while holding lock for printing results
     * (see notes under pcprofile_cache_flush below)
     */
    stop_itimer();

    pcprofile_results(info);
    size = HASHTABLE_SIZE(HASH_BITS) * sizeof(pc_profile_entry_t*);
    pcprofile_reset(info); /* special heap so no fast path */
#ifdef DEBUG
    /* for non-debug we do fast exit path and don't free local heap */
    heap_free(dcontext, info->htable, size HEAPACCT(ACCT_OTHER));
#endif
#if USE_SYMTAB
    if (valid_symtab)
        symtab_exit();
#endif
    os_close(info->file);
    special_heap_exit(info->special_heap);
#ifdef DEBUG
    /* for non-debug we do fast exit path and don't free local heap */
    heap_free(dcontext, info, sizeof(thread_pc_info_t) HEAPACCT(ACCT_OTHER));
#endif
}

void
pcprofile_fork_init(dcontext_t *dcontext)
{
    /* FIXME: hmmm...I guess a forked child will just start from scratch?
     */
    thread_pc_info_t *info = (thread_pc_info_t *) dcontext->pcprofile_field;
    pcprofile_reset(info);
    info->file = open_log_file("pcsamples", NULL, 0);
}

#if 0
static void
pcprof_dump_callstack(dcontext_t *dcontext, app_pc cur_pc, app_pc ebp, file_t outfile)
{
    uint *pc = (uint *) ebp;
    int num = 0;
    if (cur_pc != NULL) {
        print_file(outfile, "\tcurrent pc = "PFX"\n", cur_pc);
    }
    /* only DR routines 
     * cannot call is_readable b/c that asks for memory -> livelock
     */
    while (pc != NULL && (pc >= dcontext->dstack - DYNAMORIO_STACK_SIZE) &&
           pc < dcontext->dstack) {
        print_file(outfile, 
            "\tframe ptr "PFX" => parent "PFX", ret = "PFX"\n", pc, *pc, *(pc+1));
        num++;
        /* yes I've seen weird recursive cases before */
        if (pc == (uint *) *pc || num > 100)
            break;
        pc = (uint *) *pc;
    }
}
#endif

/* Handle a pc sample
 *
 * WARNING: this function could interrupt any part of dynamo!
 * Make sure nothing is done that could cause deadlock or
 * data structure mishaps.
 * Right now interrupting heap_alloc or interrupting pcprofile_results are
 * the only bad things that could happen, both are dealt with.
 */
void
pcprofile_alarm(dcontext_t *dcontext, void *pc, app_pc ebp)
{               
    thread_pc_info_t *info = (thread_pc_info_t *) dcontext->pcprofile_field;
    pc_profile_entry_t *entry;
    fragment_t *fragment;
    fragment_t wrapper;

    entry = pcprofile_lookup(info, pc);

#if 0
    print_file(info->file, "\nalarm "PFX"\n", pc);
    pcprof_dump_callstack(dcontext, pc, ebp, info->file);
#endif

    if (entry != NULL) {
        entry->counter++;
    } else {
        /* the process is suspended, so we don't care about data races, but
         * we can't have anyone else holding locks we need.
         * special_heap routines do not use any locks.
         */
        entry = pcprofile_add_entry(info, pc, dcontext->whereami);
        /* if in a fragment, get fragment tag & offset now */
        if (entry->whereami == WHERE_FCACHE) {
            fragment = fragment_pclookup(dcontext, pc, &wrapper);
            if (fragment == NULL) {
                /* FIXME: should check fcache_unit_areas.lock before
                 * calling (case 1317) and at least assert on it, if counting
                 * on whereami to ensure no DR locks are held
                 */
                if (in_fcache(pc)) {
                    entry->whereami = WHERE_UNKNOWN;
                } else {
                    /* identify parts of our assembly code now.
                     * it's all generated and post-process can't identify.
                     * assume code order is as follows:
                     */
                    if (in_context_switch_code(dcontext, (cache_pc)pc)) {
                        entry->whereami = WHERE_CONTEXT_SWITCH;
                    } else if (in_indirect_branch_lookup_code(dcontext,
                                                              (cache_pc)pc)) {
                        entry->whereami = WHERE_IBL;
                    } else {
                        entry->whereami = WHERE_UNKNOWN;
                    }
                }
            } else {
#ifdef DEBUG
                entry->id = fragment->id;
#endif
                entry->tag = fragment->tag;
                ASSERT(CHECK_TRUNCATE_TYPE_int((byte *)pc - fragment->start_pc));
                entry->offset = (int) ((byte *)pc - fragment->start_pc);
                entry->trace = (fragment->flags & FRAG_IS_TRACE) != 0;
            }
        }
    }

    /* update whereami counters */
    info->where[entry->whereami]++;
}

/* create a new, initialized profile pc entry */
static pc_profile_entry_t *
pcprofile_add_entry(thread_pc_info_t *info, void *pc, int whereami)
{
    uint hindex;
    pc_profile_entry_t *e;

    /* special_heap is hardcoded for sizeof(pc_profile_entry_t) */
    e = (pc_profile_entry_t*) special_heap_alloc(info->special_heap);
    e->pc = pc;
    e->counter = 1;
    e->whereami = whereami;
    e->next = NULL;
#if DEBUG
    e->id = 0;
#endif
    e->tag = 0;
    e->offset = 0;
    e->trace = false;
    e->retired = false;

    /* add e to the htable */
    hindex = HASH_FUNC_BITS((ptr_uint_t)pc, HASH_BITS);
    e->next = info->htable[hindex];
    info->htable[hindex] = e;

    return e;
}

/* Lookup an entry by pc and return a pointer to the corresponding entry 
 * Returns NULL if no such entry exists */
static pc_profile_entry_t *
pcprofile_lookup(thread_pc_info_t *info, void *pc)
{
    uint hindex;
    pc_profile_entry_t *e;
    /* find the entry corresponding to tag */
    hindex = HASH_FUNC_BITS((ptr_uint_t)pc, HASH_BITS);
    for (e = info->htable[hindex]; e; e = e->next) {
        if (e->pc == pc && !e->retired)
            return e;
    }
    return NULL;
}

/* When a fragment is deleted we "retire" all its entries
 * Thus we end up with multiple entires with the same pc
 */
void
pcprofile_fragment_deleted(dcontext_t *dcontext, fragment_t *f)
{
    thread_pc_info_t *info;
    int i;
    pc_profile_entry_t *e;
    if (dcontext == GLOBAL_DCONTEXT) {
        dcontext = get_thread_private_dcontext();
    }
    if (dcontext == NULL) {
        ASSERT(dynamo_exited);
        return;
    }
    info = (thread_pc_info_t *) dcontext->pcprofile_field;
    for (i = 0; i < HASHTABLE_SIZE(HASH_BITS); i++) {
        for (e = info->htable[i]; e; e = e->next) {
            if (e->tag == f->tag) {
                e->retired = true;
            }
        }
    }
}

#if 0 /* not used */
/* delete the trace head entry corresponding to tag if it exists */
static void
pcprofile_destroy_entry(thread_pc_info_t *info, void *pc)
{
    uint hindex;
    pc_profile_entry_t *e, *prev_e = NULL;

    /* find the trace head entry corresponding to tag and delete it */
    hindex = HASH_FUNC_BITS((ptr_uint_t)pc, HASH_BITS);
    for (e = info->htable[hindex]; e; prev_e = e, e = e->next) {
        if (e->pc == pc) {
            if (prev_e)
                prev_e->next = e->next;
            else
                info->htable[hindex] = e->next;
            break;
        }
    }
    if (e)
        special_heap_free(info->special_heap, e);
}
#endif

/* reset profile structures */
static void
pcprofile_reset(thread_pc_info_t *info)
{
    int i;
    for (i = 0; i < HASHTABLE_SIZE(HASH_BITS); i++) {
        pc_profile_entry_t *e = info->htable[i];
        while (e) {
            pc_profile_entry_t *nexte = e->next;
            special_heap_free(info->special_heap, e);
            e = nexte;
        }
        info->htable[i] = NULL;
    }
    for (i = 0; i < WHERE_LAST; i++)
        info->where[i] = 0;
}

/* Print the profile results 
 * FIXME: It would be nice to print counts integrated with fragment listings
 * That would require re-ordering *_exit() sequence (fragments are deleted first)
 * Instead of doing that, can use a script to combine these tag+offsets with
 * previously printed fragments
 * FIXME: this routine uses floating point ops, if ever called not at thread exit
 * must preserve fp state around the whole routine!
 */
static void
pcprofile_results(thread_pc_info_t *info)
{
    int i, total = 0;
    pc_profile_entry_t *e;

    for (i = 0; i < WHERE_LAST; i++) 
        total += info->where[i];
    
    print_file(info->file, "DynamoRIO library base: "PFX"\n",
               get_dynamorio_dll_start());
    print_file(info->file, "ITIMER distribution (%d):\n", total);
    if (info->where[WHERE_APP] > 0) {
        print_file(info->file, "  %5.1f%% of time in APPLICATION (%d)\n",
                   (float)info->where[WHERE_APP]/(float)total * 100.0,
                   info->where[WHERE_APP]);
    }
    if (info->where[WHERE_INTERP] > 0) {
        print_file(info->file, "  %5.1f%% of time in INTERPRETER (%d)\n",
                   (float)info->where[WHERE_INTERP]/(float)total * 100.0,
                   info->where[WHERE_INTERP]);
    }
    if (info->where[WHERE_DISPATCH] > 0) {
        print_file(info->file, "  %5.1f%% of time in DISPATCH (%d)\n",
                   (float)info->where[WHERE_DISPATCH]/(float)total * 100.0,
                   info->where[WHERE_DISPATCH]);
    }
    if (info->where[WHERE_MONITOR] > 0) {
        print_file(info->file, "  %5.1f%% of time in MONITOR (%d)\n",
                   (float)info->where[WHERE_MONITOR]/(float)total * 100.0,
                   info->where[WHERE_MONITOR]);
    }
    if (info->where[WHERE_SYSCALL_HANDLER] > 0) {
        print_file(info->file, "  %5.1f%% of time in SYSCALL HANDLER (%d)\n",
                   (float)info->where[WHERE_SYSCALL_HANDLER]/(float)total * 100.0,
                   info->where[WHERE_SYSCALL_HANDLER]);
    }
    if (info->where[WHERE_SIGNAL_HANDLER] > 0) {
        print_file(info->file, "  %5.1f%% of time in SIGNAL HANDLER (%d)\n",
                   (float)info->where[WHERE_SIGNAL_HANDLER]/(float)total * 100.0,
                   info->where[WHERE_SIGNAL_HANDLER]);
    }
    if (info->where[WHERE_TRAMPOLINE] > 0) {
        print_file(info->file, "  %5.1f%% of time in TRAMPOLINES (%d)\n",
                   (float)info->where[WHERE_TRAMPOLINE]/(float)total * 100.0,
                   info->where[WHERE_TRAMPOLINE]);
    }
    if (info->where[WHERE_CONTEXT_SWITCH] > 0) {
        print_file(info->file, "  %5.1f%% of time in CONTEXT SWITCH (%d)\n",
                   (float)info->where[WHERE_CONTEXT_SWITCH]/(float)total * 100.0,
                   info->where[WHERE_CONTEXT_SWITCH]);
    }
    if (info->where[WHERE_IBL] > 0) {
        print_file(info->file, "  %5.1f%% of time in INDIRECT BRANCH LOOKUP (%d)\n",
                   (float)info->where[WHERE_IBL]/(float)total * 100.0,
                   info->where[WHERE_IBL]);
    }
    if (info->where[WHERE_FCACHE] > 0) {
        print_file(info->file, "  %5.1f%% of time in FRAGMENT CACHE (%d)\n",
                   (float)info->where[WHERE_FCACHE]/(float)total * 100.0,
                   info->where[WHERE_FCACHE]);
    }
    if (info->where[WHERE_UNKNOWN] > 0) {
        print_file(info->file, "  %5.1f%% of time in UNKNOWN (%d)\n",
                   (float)info->where[WHERE_UNKNOWN]/(float)total * 100.0,
                   info->where[WHERE_UNKNOWN]);
    }

    print_file(info->file, "\nPC PROFILING RESULTS\n");

    for (i = 0; i < HASHTABLE_SIZE(HASH_BITS); i++) {
        e = info->htable[i];
        while (e) {
            if (e->whereami == WHERE_FCACHE) {
                const char *type;
                if (e->trace)
                    type = "trace";
                else
                    type = "fragment";
                print_file(info->file,
#ifdef DEBUG
                        "pc="PFX"\t#=%d\tin %s #%6d @"PFX" w/ offs "PFX"\n",
                        e->pc, e->counter, type, e->id, e->tag, e->offset);
#else
                        "pc="PFX"\t#=%d\tin %s @"PFX" w/ offs "PFX"\n",
                        e->pc, e->counter, type, e->tag, e->offset);
#endif
#if USE_SYMTAB
                /* FIXME: this only works for fragments whose tags are app pc's! */
                if (valid_symtab) {
                    print_file(info->file,
                            "\tin app = %s\n",
                            symtab_lookup_pc((void *)(e->tag+e->offset)));
                }
#endif
            } else if (e->whereami == WHERE_APP) {
#if USE_SYMTAB
                if (valid_symtab) {
                    print_file(info->file, "pc="PFX"\t#=%d\tin the app = %s\n",
                               e->pc, e->counter, symtab_lookup_pc(e->pc));
                } else {
#else
                    print_file(info->file, "pc="PFX"\t#=%d\tin the app\n",
                               e->pc, e->counter);
#endif
#if USE_SYMTAB
                }
#endif
            } else if (e->whereami == WHERE_UNKNOWN) {
                if (is_dynamo_address(e->pc)) {
                    print_file(info->file, "pc="PFX"\t#=%d\tin DynamoRIO <SOMEWHERE>\n",
                               e->pc, e->counter);
                } else {
                    char *comment = NULL;
                    DODEBUG({ comment = get_address_comment(e->pc); });
                    print_file(info->file, "pc="PFX"\t#=%d\tin uncategorized: %s\n",
                               e->pc, e->counter,
                               (comment==NULL)?"<UNKNOWN>":comment);
                }
            } else {
#if USE_SYMTAB
                if (valid_symtab) {
                    print_file(info->file,
                               "pc="PFX"\t#=%d\tin DynamoRIO = %s\n",
                               e->pc, e->counter, symtab_lookup_pc(e->pc));
                } else {
#else
                    print_file(info->file, "pc="PFX"\t#=%d\tin DynamoRIO",
                               e->pc, e->counter);
                    if (e->whereami == WHERE_INTERP) {
                        print_file(info->file, " interpreter\n");
                    } else if (e->whereami == WHERE_DISPATCH) {
                        print_file(info->file, " dispatch\n");
                    } else if (e->whereami == WHERE_MONITOR) {
                        print_file(info->file, " monitor\n");
                    } else if (e->whereami == WHERE_SIGNAL_HANDLER) {
                        print_file(info->file, " signal handler\n");
                    } else if (e->whereami == WHERE_SYSCALL_HANDLER) {
                        print_file(info->file, " syscall handler\n");
                    } else if (e->whereami == WHERE_CONTEXT_SWITCH) {
                        print_file(info->file, " context switch\n");
                    } else if (e->whereami == WHERE_IBL) {
                        print_file(info->file, " indirect_branch_lookup\n");
                    } else {
                        print_file(STDERR, "ERROR: unknown whereAmI %d\n",
                                e->whereami);
                        ASSERT_NOT_REACHED();
                    }
#endif
#if USE_SYMTAB
                }
#endif
            }
            e = e->next;
        }
    }    
}
