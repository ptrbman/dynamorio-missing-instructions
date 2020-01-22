/* **********************************************************
 * Copyright (c) 2016-2020 Google, Inc.  All rights reserved.
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
 * * Neither the name of Google, Inc. nor the names of its contributors may be
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

/* trace_invariants: a memory trace invariants checker.
 */

#ifndef _TRACE_INVARIANTS_H_
#define _TRACE_INVARIANTS_H_ 1

#include "../analysis_tool.h"
#include "../common/memref.h"
#include "raw2trace.h"
#include "raw2trace_directory.h"
#include <unordered_map>
#include <unordered_map>

class trace_invariants_t : public analysis_tool_t {
public:
    trace_invariants_t(const std::string &module_file_path, bool offline = true,
                       unsigned int verbose = 0);
    virtual ~trace_invariants_t();
    std::string
    initialize() override;
    bool
    process_memref(const memref_t &memref) override;
    bool
    print_results() override;

protected:
    std::string
    get_opcode(addr_t pc, int *opcode OUT);

    void *dcontext = nullptr;
    std::string module_file;
    std::unique_ptr<module_mapper_t> module_mapper;
    std::unordered_map<app_pc, int> opcode_cache;
    app_pc last_trace_module_start = nullptr;
    size_t last_trace_module_size = 0;
    app_pc last_mapped_module_start = nullptr;
    raw2trace_directory_t directory;
    bool knob_offline = false;
    unsigned int knob_verbose = 0;
    memref_t prev_instr = {};
    memref_t prev_xfer_marker = {};
    memref_t prev_entry = {};
    memref_t prev_prev_entry = {};
    memref_t pre_signal_instr = {};
    int instrs_until_interrupt = -1;
    int memrefs_until_interrupt = -1;
    addr_t app_handler_pc = 0;
    std::unordered_map<memref_tid_t, bool> thread_exited;
};

#endif /* _TRACE_INVARIANTS_H_ */
