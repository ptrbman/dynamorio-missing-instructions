/* **********************************************************
 * Copyright (c) 2022 Google, Inc.  All rights reserved.
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

/* trace_filter: represents a tool that filters trace_entry_t in a stored
 * offline trace file.
 */

#ifndef _TRACE_FILTER_H_
#define _TRACE_FILTER_H_ 1

#include <iterator>
#include <memory>
#include <string>
#include <vector>
#include "trace_entry_file_reader.h"

class trace_filter_t {
public:
    /**
     * Usage:
     */
    trace_filter_t();
    virtual ~trace_filter_t() {};

    /**
     * Filter the trace files present at trace_dir.
     */
    trace_filter_t(const std::string &trace_dir, const std::string &output_dir,
                   int worker_count = 0, int verbosity = 0);
    /** Launches the process. */
    virtual bool
    run();

    std::string
    get_error_string()
    {
        return error_string_;
    }

    void
    print_stats()
    {
        // std::cout << "Trace filter stats:" << std::endl;
    }
#ifdef HAS_SNAPPY
    const char *snappy_suffix = ".sz";
#endif

#ifdef HAS_ZIP
    const char *zip_suffix = ".zip";
#endif

#ifdef HAS_ZLIB
    const char *gzip_suffix = ".gz";
#endif

private:
    // Data for one trace shard.  Our concurrency model has each shard
    // filtered by a single worker thread, eliminating the need for locks.
    struct shard_data_t {
        shard_data_t(int index, std::unique_ptr<trace_entry_reader_t> iter,
                     std::unique_ptr<std::ostream> writer, const std::string &trace_file)
            : index(index)
            , worker(0)
            , iter(std::move(iter))
            , writer(std::move(writer))
            , trace_file(trace_file)
        {
        }
        shard_data_t(shard_data_t &&src)
        {
            index = src.index;
            worker = src.worker;
            iter = std::move(src.iter);
            writer = std::move(src.writer);
            trace_file = std::move(src.trace_file);
            error = std::move(src.error);
        }

        int index;
        int worker;
        std::unique_ptr<trace_entry_reader_t> iter;
        std::unique_ptr<std::ostream> writer;
        std::string trace_file;
        std::string error;

        shard_data_t(const shard_data_t &) = delete;
        shard_data_t &
        operator=(const shard_data_t &) = delete;
    };

    bool
    init_file_reader(const std::string &trace_path, const std::string &output_path,
                     int verbosity = 0);

    void
    process_tasks(std::vector<shard_data_t *> *tasks);

    std::unique_ptr<trace_entry_reader_t>
    get_reader(const std::string &path, int verbosity);

    std::unique_ptr<std::ostream>
    get_writer(const std::string &path, int verbosity);

    typedef enum {
        FILE_FORMAT_UNKNOWN = 0,
        FILE_FORMAT_GZIP,
        FILE_FORMAT_ZIP,
        FILE_FORMAT_SNAPPY
    } file_format_t;
    int verbosity_;
    bool success_;
    int worker_count_;
    std::string trace_dir_, output_dir_;
    file_format_t input_file_format;
    std::string error_string_;
    std::vector<shard_data_t> thread_data_;
    std::unique_ptr<trace_entry_reader_t> trace_end_;
    std::vector<std::vector<shard_data_t *>> worker_tasks_;
    const char *output_prefix_ = "[trace_filter]";
};

#endif /* _TRACE_FILTER_H_ */