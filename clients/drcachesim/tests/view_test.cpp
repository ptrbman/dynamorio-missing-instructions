/* **********************************************************
 * Copyright (c) 2021-2023 Google, LLC  All rights reserved.
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
 * ARE DISCLAIMED. IN NO EVENT SHALL GOOGLE, LLC OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */

/* Unit tests for the view_t tool. */

#include <algorithm>
#include <iostream>
#include <regex>
#include <string>
#include <vector>

#include "../tools/view.h"
#include "../common/memref.h"
#include "../tracer/raw2trace.h"
#include "../reader/file_reader.h"
#include "memref_gen.h"

#undef ASSERT
#define ASSERT(cond, msg, ...)        \
    do {                              \
        if (!(cond)) {                \
            std::cerr << msg << "\n"; \
            abort();                  \
        }                             \
    } while (0)

#define CHECK(cond, msg, ...)         \
    do {                              \
        if (!(cond)) {                \
            std::cerr << msg << "\n"; \
            return false;             \
        }                             \
    } while (0)

// These are for our mock serial reader and must be in the same namespace
// as file_reader_t's declaration.
template <> file_reader_t<std::vector<trace_entry_t>>::~file_reader_t()
{
}

template <>
bool
file_reader_t<std::vector<trace_entry_t>>::is_complete()
{
    return false;
}

template <>
bool
file_reader_t<std::vector<trace_entry_t>>::open_single_file(const std::string &path)
{
    return true;
}

template <>
bool
file_reader_t<std::vector<trace_entry_t>>::read_next_thread_entry(
    size_t thread_index, OUT trace_entry_t *entry, OUT bool *eof)
{
    return false;
}

namespace {

// Subclasses module_mapper_t and replaces the module loading with a buffer
// of encoded instr_t.
class module_mapper_test_t : public module_mapper_t {
public:
    module_mapper_test_t(void *drcontext, instrlist_t &instrs)
        : module_mapper_t(nullptr)
    {
        byte *pc = instrlist_encode(drcontext, &instrs, decode_buf_, true);
        ASSERT(pc - decode_buf_ < MAX_DECODE_SIZE, "decode buffer overflow");
        // Clear do_module_parsing error; we can't cleanly make virtual b/c it's
        // called from the constructor.
        last_error_ = "";
    }

protected:
    void
    read_and_map_modules(void) override
    {
        modvec_.push_back(module_t("fake_exe", 0, decode_buf_, 0, MAX_DECODE_SIZE,
                                   MAX_DECODE_SIZE, true));
    }

private:
    static const int MAX_DECODE_SIZE = 1024;
    byte decode_buf_[MAX_DECODE_SIZE];
};

class view_test_t : public view_t {
public:
    view_test_t(void *drcontext, instrlist_t &instrs, memref_tid_t thread,
                uint64_t skip_refs, uint64_t sim_refs)
        : view_t("", thread, skip_refs, sim_refs, "", 0)
    {
        module_mapper_ =
            std::unique_ptr<module_mapper_t>(new module_mapper_test_t(drcontext, instrs));
    }

    std::string
    initialize() override
    {
        module_mapper_->get_loaded_modules();
        dr_disasm_flags_t flags =
            IF_X86_ELSE(DR_DISASM_ATT, IF_AARCH64_ELSE(DR_DISASM_DR, DR_DISASM_ARM));
        disassemble_set_syntax(flags);
        return "";
    }
};

class view_nomod_test_t : public view_t {
public:
    view_nomod_test_t(void *drcontext, instrlist_t &instrs, memref_tid_t thread,
                      uint64_t skip_refs, uint64_t sim_refs)
        : view_t("", thread, skip_refs, sim_refs, "", 0)
    {
    }
};

std::string
run_test_helper(view_t &view, const std::vector<memref_t> &memrefs)
{
    class local_stream_t : public default_memtrace_stream_t {
    public:
        local_stream_t(view_t &view, const std::vector<memref_t> &memrefs)
            : view_(view)
            , memrefs_(memrefs)
        {
        }

        std::string
        run()
        {
            view_.initialize_stream(this);
            // Capture cerr.
            std::stringstream capture;
            std::streambuf *prior = std::cerr.rdbuf(capture.rdbuf());
            // Run the tool.
            for (const auto &memref : memrefs_) {
                ++ref_count_;
                if (type_is_instr(memref.instr.type))
                    ++instr_count_;
                if (!view_.process_memref(memref))
                    std::cout << "Hit error: " << view_.get_error_string() << "\n";
            }
            // Return the result.
            std::string res = capture.str();
            std::cerr.rdbuf(prior);
            return res;
        }

        uint64_t
        get_record_ordinal() const override
        {
            return ref_count_;
        }
        uint64_t
        get_instruction_ordinal() const override
        {
            return instr_count_;
        }

    private:
        view_t &view_;
        const std::vector<memref_t> &memrefs_;
        uint64_t ref_count_ = 0;
        uint64_t instr_count_ = 0;
    };

    local_stream_t stream(view, memrefs);
    return stream.run();
}

bool
test_no_limit(void *drcontext, instrlist_t &ilist, const std::vector<memref_t> &memrefs)
{
    view_test_t view(drcontext, ilist, 0, 0, 0);
    std::string res = run_test_helper(view, memrefs);
    if (std::count(res.begin(), res.end(), '\n') != static_cast<int>(memrefs.size())) {
        std::cerr << "Incorrect line count\n";
        return false;
    }
    std::stringstream ss(res);
    int prefix;
    ss >> prefix;
    if (prefix != 1) {
        std::cerr << "Expect 1-based line prefixes\n";
        return false;
    }
    return true;
}

bool
test_num_memrefs(void *drcontext, instrlist_t &ilist,
                 const std::vector<memref_t> &memrefs, int num_memrefs)
{
    ASSERT(static_cast<size_t>(num_memrefs) < memrefs.size(),
           "need more memrefs to limit");
    view_test_t view(drcontext, ilist, 0, 0, num_memrefs);
    std::string res = run_test_helper(view, memrefs);
    if (std::count(res.begin(), res.end(), '\n') != num_memrefs) {
        std::cerr << "Incorrect num_memrefs count: expect " << num_memrefs
                  << " but got \n"
                  << res << "\n";
        return false;
    }
    return true;
}

bool
test_skip_memrefs(void *drcontext, instrlist_t &ilist,
                  const std::vector<memref_t> &memrefs, int skip_memrefs, int num_memrefs)
{
    // We do a simple check on the marker count.
    // XXX: To test precisely skipping the instrs and data we'll need to spend
    // more effort here, but the initial delayed markers are the corner cases.
    int all_count = 0, marker_count = 0;
    for (const auto &memref : memrefs) {
        if (all_count++ < skip_memrefs)
            continue;
        if (all_count - skip_memrefs > num_memrefs)
            break;
        if (memref.marker.type == TRACE_TYPE_MARKER)
            ++marker_count;
    }
    ASSERT(static_cast<size_t>(num_memrefs + skip_memrefs) <= memrefs.size(),
           "need more memrefs to skip");
    view_test_t view(drcontext, ilist, 0, skip_memrefs, num_memrefs);
    std::string res = run_test_helper(view, memrefs);
    if (std::count(res.begin(), res.end(), '\n') != num_memrefs) {
        std::cerr << "Incorrect skipped_memrefs count: expect " << num_memrefs
                  << " but got \n"
                  << res << "\n";
        return false;
    }
    int found_markers = 0;
    size_t pos = 0;
    while (pos != std::string::npos) {
        pos = res.find("marker", pos);
        if (pos != std::string::npos) {
            ++found_markers;
            ++pos;
        }
    }
    if (found_markers != marker_count) {
        std::cerr << "Failed to skip proper number of markers\n";
        return false;
    }
    // Unfortunately this doesn't detect an error in the internal counter.
    // We rely on the marker count check for that.
    std::stringstream ss(res);
    int prefix;
    ss >> prefix;
    if (prefix != 1 + skip_memrefs) {
        std::cerr << "Expect to start after skip count " << skip_memrefs << " but found "
                  << prefix << "\n"
                  << res << "\n";
        return false;
    }
    return true;
}

bool
test_thread_limit(instrlist_t &ilist, const std::vector<memref_t> &memrefs,
                  void *drcontext, int thread2_id)
{
    int thread2_count = 0;
    for (const auto &memref : memrefs) {
        if (memref.data.tid == thread2_id)
            ++thread2_count;
    }
    view_test_t view(drcontext, ilist, thread2_id, 0, 0);
    std::string res = run_test_helper(view, memrefs);
    // Count the Tnnnn prefixes.
    std::stringstream ss;
    ss << "T" << thread2_id;
    std::string prefix = ss.str();
    int found_prefixes = 0;
    size_t pos = 0;
    while (pos != std::string::npos) {
        pos = res.find(prefix, pos);
        if (pos != std::string::npos) {
            ++found_prefixes;
            ++pos;
        }
    }
    if (std::count(res.begin(), res.end(), '\n') != thread2_count ||
        found_prefixes != thread2_count) {
        std::cerr << "Incorrect thread2 count\n";
        return false;
    }
    return true;
}

bool
test_no_modules(void *drcontext, instrlist_t &ilist, const std::vector<memref_t> &memrefs)
{
    view_nomod_test_t view(drcontext, ilist, 0, 0, 0);
    std::string res = run_test_helper(view, memrefs);
    if (std::count(res.begin(), res.end(), '\n') != static_cast<int>(memrefs.size())) {
        std::cerr << "Incorrect line count\n";
        return false;
    }
    std::stringstream ss(res);
    int prefix;
    ss >> prefix;
    if (prefix != 1) {
        std::cerr << "Expect 1-based line prefixes\n";
        return false;
    }
    return true;
}

bool
run_limit_tests(void *drcontext)
{
    bool res = true;

    instrlist_t *ilist = instrlist_create(drcontext);
    // raw2trace doesn't like offsets of 0 so we shift with a nop.
    instr_t *nop1 = XINST_CREATE_nop(drcontext);
    instr_t *nop2 = XINST_CREATE_nop(drcontext);
    instr_t *jcc = XINST_CREATE_jump_cond(drcontext, DR_PRED_EQ, opnd_create_instr(nop2));
    instrlist_append(ilist, nop1);
    instrlist_append(ilist, jcc);
    instrlist_append(ilist, nop2);
    size_t offs_nop1 = 0;
    size_t offs_jz = offs_nop1 + instr_length(drcontext, nop1);
    size_t offs_nop2 = offs_jz + instr_length(drcontext, jcc);

    const memref_tid_t t1 = 3;
    std::vector<memref_t> memrefs = {
        gen_marker(t1, TRACE_MARKER_TYPE_VERSION, 3),
        gen_marker(t1, TRACE_MARKER_TYPE_FILETYPE, 0),
        gen_marker(t1, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, 64),
        gen_marker(t1, TRACE_MARKER_TYPE_TIMESTAMP, 1001),
        gen_marker(t1, TRACE_MARKER_TYPE_CPU_ID, 2),
        gen_instr(t1, offs_nop1),
        gen_data(t1, true, 0x42, 4),
        gen_marker(t1, TRACE_MARKER_TYPE_TIMESTAMP, 1002),
        gen_marker(t1, TRACE_MARKER_TYPE_CPU_ID, 3),
        gen_branch(t1, offs_jz),
        gen_branch(t1, offs_nop2),
        gen_data(t1, true, 0x42, 4),
    };

    res = test_no_limit(drcontext, *ilist, memrefs) && res;
    for (int i = 1; i < static_cast<int>(memrefs.size()); ++i) {
        res = test_num_memrefs(drcontext, *ilist, memrefs, i) && res;
    }
    constexpr int num_refs = 2;
    for (int i = 1; i < static_cast<int>(memrefs.size() - num_refs); ++i) {
        res = test_skip_memrefs(drcontext, *ilist, memrefs, i, num_refs) && res;
    }

    // Ensure missing modules are fine.
    res = test_no_modules(drcontext, *ilist, memrefs) && res;

    const memref_tid_t t2 = 21;
    std::vector<memref_t> thread_memrefs = {
        gen_marker(t1, TRACE_MARKER_TYPE_VERSION, 3),
        gen_marker(t1, TRACE_MARKER_TYPE_FILETYPE, 0),
        gen_marker(t1, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, 64),
        gen_instr(t1, offs_nop1),
        gen_data(t1, true, 0x42, 4),
        gen_branch(t1, offs_jz),
        gen_branch(t1, offs_nop2),
        gen_data(t1, true, 0x42, 4),
        gen_marker(t2, TRACE_MARKER_TYPE_VERSION, 3),
        gen_marker(t2, TRACE_MARKER_TYPE_FILETYPE, 0),
        gen_marker(t2, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, 64),
        gen_marker(t2, TRACE_MARKER_TYPE_TIMESTAMP, 101),
        gen_marker(t2, TRACE_MARKER_TYPE_CPU_ID, 3),
        gen_instr(t2, offs_nop1),
        gen_data(t2, true, 0x42, 4),
        gen_branch(t2, offs_jz),
        gen_branch(t2, offs_nop2),
        gen_data(t2, true, 0x42, 4),
    };
    res = test_thread_limit(*ilist, thread_memrefs, drcontext, t2) && res;

    instrlist_clear_and_destroy(drcontext, ilist);
    return res;
}

/***************************************************************************
 * Serial reader mock.
 */

class mock_file_reader_t : public file_reader_t<std::vector<trace_entry_t>> {
public:
    mock_file_reader_t()
    {
    }
    mock_file_reader_t(const std::vector<std::vector<trace_entry_t>> &entries)
        : file_reader_t(std::vector<std::string>(1, "non-empty"))
    {
        input_files_ = entries;
        pos_.resize(input_files_.size(), 0);
        init();
    }
    bool
    read_next_thread_entry(size_t thread_index, OUT trace_entry_t *entry,
                           OUT bool *eof) override
    {
        if (pos_[thread_index] >= input_files_[thread_index].size()) {
            *eof = true;
            return false;
        }
        *entry = input_files_[thread_index][pos_[thread_index]];
        ++pos_[thread_index];
        return true;
    }

private:
    std::vector<size_t> pos_;
};

std::string
run_serial_test_helper(view_t &view,
                       const std::vector<std::vector<trace_entry_t>> &entries)
{
    class local_stream_t : public default_memtrace_stream_t {
    public:
        local_stream_t(view_t &view,
                       const std::vector<std::vector<trace_entry_t>> &entries)
            : view_(view)
            , entries_(entries)
        {
        }

        std::string
        run()
        {
            view_.initialize_stream(this);
            // Capture cerr.
            std::stringstream capture;
            std::streambuf *prior = std::cerr.rdbuf(capture.rdbuf());
            // Run the tool.
            mock_file_reader_t serial(entries_);
            mock_file_reader_t end;
            for (; serial != end; ++serial) {
                const memref_t memref = *serial;
                ++ref_count_;
                if (type_is_instr(memref.instr.type))
                    ++instr_count_;
                if (!view_.process_memref(memref))
                    std::cout << "Hit error: " << view_.get_error_string() << "\n";
            }
            // Return the result.
            std::string res = capture.str();
            std::cerr.rdbuf(prior);
            return res;
        }

        uint64_t
        get_record_ordinal() const override
        {
            return ref_count_;
        }
        uint64_t
        get_instruction_ordinal() const override
        {
            return instr_count_;
        }

    private:
        view_t &view_;
        const std::vector<std::vector<trace_entry_t>> &entries_;
        uint64_t ref_count_ = 0;
        uint64_t instr_count_ = 0;
    };

    local_stream_t stream(view, entries);
    return stream.run();
}

/***************************************************************************/

bool
run_single_thread_chunk_test(void *drcontext)
{
    const memref_tid_t t1 = 3;
    std::vector<std::vector<trace_entry_t>> entries = { {
        { TRACE_TYPE_HEADER, 0, { 0x1 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_VERSION, { 3 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_FILETYPE, { 0 } },
        { TRACE_TYPE_THREAD, 0, { t1 } },
        { TRACE_TYPE_PID, 0, { t1 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, { 64 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CHUNK_INSTR_COUNT, { 2 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1002 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 2 } },
        { TRACE_TYPE_INSTR, 4, { 42 } },
        { TRACE_TYPE_INSTR, 4, { 42 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CHUNK_FOOTER, { 0 } },
        // We're testing that the reader hides this duplicate timestamp
        // at the start of a chunk.
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1002 } },
        { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 3 } },
        { TRACE_TYPE_INSTR, 4, { 42 } },
    } };
    const char *expect = R"DELIM(           1           0:          T3 <marker: version 3>
           2           0:          T3 <marker: filetype 0x0>
           3           0:          T3 <marker: cache line size 64>
           4           0:          T3 <marker: chunk instruction count 2>
           5           0:          T3 <marker: timestamp 1002>
           6           0:          T3 <marker: tid 3 on core 2>
           7           1:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
           8           2:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
           9           2:          T3 <marker: chunk footer #0>
          10           3:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
)DELIM";
    instrlist_t *ilist_unused = nullptr;
    view_nomod_test_t view(drcontext, *ilist_unused, 0, 0, 0);
    std::string res = run_serial_test_helper(view, entries);
    // Make 64-bit match our 32-bit expect string.
    res = std::regex_replace(res, std::regex("0x000000000000002a"), "0x0000002a");
    if (res != expect) {
        std::cerr << "Output mismatch: got |" << res << "| expected |" << expect << "|\n";
        return false;
    }
    return true;
}

bool
run_serial_chunk_test(void *drcontext)
{
    // We ensure headers are not omitted incorrectly, which they were
    // in the first implementation of the reader skipping dup headers:
    // i#/5538#issuecomment-1407235283
    const memref_tid_t t1 = 3;
    const memref_tid_t t2 = 7;
    std::vector<std::vector<trace_entry_t>> entries = {
        {
            { TRACE_TYPE_HEADER, 0, { 0x1 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_VERSION, { 3 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_FILETYPE, { 0 } },
            { TRACE_TYPE_THREAD, 0, { t1 } },
            { TRACE_TYPE_PID, 0, { t1 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, { 64 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CHUNK_INSTR_COUNT, { 20 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1001 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 2 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1003 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 3 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
        },
        {
            { TRACE_TYPE_HEADER, 0, { 0x1 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_VERSION, { 3 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_FILETYPE, { 0 } },
            { TRACE_TYPE_THREAD, 0, { t2 } },
            { TRACE_TYPE_PID, 0, { t2 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CACHE_LINE_SIZE, { 64 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CHUNK_INSTR_COUNT, { 2 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1002 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 2 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_TIMESTAMP, { 1004 } },
            { TRACE_TYPE_MARKER, TRACE_MARKER_TYPE_CPU_ID, { 3 } },
            { TRACE_TYPE_INSTR, 4, { 42 } },
        }
    };
    const char *expect =
        R"DELIM(           1           0:          T3 <marker: version 3>
           2           0:          T3 <marker: filetype 0x0>
           3           0:          T3 <marker: cache line size 64>
           4           0:          T3 <marker: chunk instruction count 20>
------------------------------------------------------------
           5           0:          T7 <marker: version 3>
           6           0:          T7 <marker: filetype 0x0>
           7           0:          T7 <marker: cache line size 64>
           8           0:          T7 <marker: chunk instruction count 2>
------------------------------------------------------------
           9           0:          T3 <marker: timestamp 1001>
          10           0:          T3 <marker: tid 3 on core 2>
          11           1:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
          12           2:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
------------------------------------------------------------
          13           2:          T7 <marker: timestamp 1002>
          14           2:          T7 <marker: tid 7 on core 2>
          15           3:          T7 ifetch       4 byte(s) @ 0x0000002a non-branch
          16           4:          T7 ifetch       4 byte(s) @ 0x0000002a non-branch
------------------------------------------------------------
          17           4:          T3 <marker: timestamp 1003>
          18           4:          T3 <marker: tid 3 on core 3>
          19           5:          T3 ifetch       4 byte(s) @ 0x0000002a non-branch
------------------------------------------------------------
          20           5:          T7 <marker: timestamp 1004>
          21           5:          T7 <marker: tid 7 on core 3>
          22           6:          T7 ifetch       4 byte(s) @ 0x0000002a non-branch
)DELIM";
    instrlist_t *ilist_unused = nullptr;
    view_nomod_test_t view(drcontext, *ilist_unused, 0, 0, 0);
    std::string res = run_serial_test_helper(view, entries);
    // Make 64-bit match our 32-bit expect string.
    res = std::regex_replace(res, std::regex("0x000000000000002a"), "0x0000002a");
    if (res != expect) {
        std::cerr << "Output mismatch: got |" << res << "| expected |" << expect << "|\n";
        return false;
    }
    return true;
}

bool
run_chunk_tests(void *drcontext)
{
    return run_single_thread_chunk_test(drcontext) && run_serial_chunk_test(drcontext);
}

} // namespace

int
main(int argc, const char *argv[])
{
    void *drcontext = dr_standalone_init();
    if (run_limit_tests(drcontext) && run_chunk_tests(drcontext)) {
        std::cerr << "view_test passed\n";
        return 0;
    }
    std::cerr << "view_test FAILED\n";
    exit(1);
}
