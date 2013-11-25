/* **********************************************************
 * Copyright (c) 2012 Google, Inc.  All rights reserved.
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

/*
 * test nudging another process (i#742)
 * also tests dr_exit_process() (i#743)
 */

#include "tools.h"

#ifdef UNIX
# include <sys/types.h>
# include <unistd.h>
# include <sys/types.h> /* for wait */
# include <sys/wait.h>  /* for wait */
# include <assert.h>
# include <stdio.h>
# include <string.h>
# include <syscall.h>
#else
# include "windows.h"
# include <stdio.h>
#endif

int
main(int argc, char** argv)
{
#ifdef UNIX
    pid_t child = fork();
    if (child < 0) {
        perror("ERROR on fork");
    } else if (child > 0) {
        pid_t result;
        int status = 0;
        /* don't print here: could be out-of-order wrt client prints */
        result = waitpid(child, &status, 0);
        assert(result == child);
        print("child has exited with status %d\n",
              WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    } else {
        /* client nudge handler will terminate us earlier */
        int left = 20;
        while (left > 0)
            left = sleep(left); /* unfortunately, nudge signal interrupts us */
    }   
#else
    STARTUPINFO si = { sizeof(STARTUPINFO) };
    PROCESS_INFORMATION pi;
    if (argc == 1) {
        /* parent */
        if (!CreateProcess(argv[0], "nudge_ex.exe 1", NULL, NULL, FALSE, 0,
                           NULL, NULL, &si, &pi)) 
            print("ERROR on CreateProcess\n"); 
        else {
            int status;
            WaitForSingleObject(pi.hProcess, INFINITE);
            GetExitCodeProcess(pi.hProcess, (LPDWORD) &status);
            print("child has exited with status %d\n", status);
            CloseHandle(pi.hProcess);
        }
    }
    else {
        /* child */
        Sleep(20000);
    }
#endif
    print("app exiting\n");
    return 0;
}
