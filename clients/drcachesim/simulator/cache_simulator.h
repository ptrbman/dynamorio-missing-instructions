/* **********************************************************
 * Copyright (c) 2015 Google, Inc.  All rights reserved.
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

/* cache_simulator: controls the multi-cache-level simulation.
 */

#ifndef _CACHE_SIMULATOR_H_
#define _CACHE_SIMULATOR_H_ 1

#include <map>
#include "simulator.h"
#include "cache_stats.h"
#include "cache.h"
#include "ipc_reader.h"

class cache_simulator_t : public simulator_t
{
 public:
    virtual bool init();
    virtual ~cache_simulator_t();
    virtual bool run();
    virtual bool print_stats();

 protected:
    // Create a cache_t object with a specific replacement policy.
    virtual cache_t *create_cache(std::string policy);

    // Currently we only support a simple 2-level hierarchy.
    // XXX i#1715: add support for arbitrary cache layouts.

    // Implement a set of ICaches and DCaches with pointer arrays.
    // This is useful for implementing polymorphism correctly.
    cache_t **icaches;
    cache_t **dcaches;

    cache_t *llcache;
};

#endif /* _CACHE_SIMULATOR_H_ */
