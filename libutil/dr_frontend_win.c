/* **********************************************************
 * Copyright (c) 2013-2014 Google, Inc.  All rights reserved.
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
 * ARE DISCLAIMED. IN NO EVENT SHALL GOOGLE, INC. OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
 * DAMAGE.
 */

#include "share.h"

#ifndef WINDOWS
# error WINDOWS-only
#endif

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <io.h>
#include "config.h"
#include "share.h"
#include "dr_frontend_private.h" /* for debuglevel/abortlevel */
#include <string.h>
#include <errno.h>
#include "utils.h"
#include <assert.h>
#include <stdio.h>
#include <time.h>
#include <stdlib.h>
#include "dr_frontend.h"


#include <DbgHelp.h>

/* We're using dynamic loading of dbghelp.dll library here.
 * So that only a frontend who called these symbol routines ends up needing it.
 */
static HMODULE hlib;

typedef BOOL (WINAPI *dbghelp_SymInitializeW_t)(IN HANDLE hProcess,
                                                 IN PCTSTR UserSearchPath,
                                                 IN BOOL fInvadeProcess);
typedef BOOL (WINAPI *dbghelp_SymCleanupW_t)(IN HANDLE hProcess);
typedef BOOL (WINAPI *dbghelp_SymSetSearchPathW_t)(IN HANDLE hProcess,
                                                      IN PCTSTR SearchPath);
typedef BOOL (WINAPI *dbghelp_SymLoadModuleExW_t)(IN HANDLE hProcess,
                                                    IN HANDLE hFile,
                                                    IN PCTSTR ImageName,
                                                    IN PCTSTR ModuleName,
                                                    IN DWORD64 BaseOfDll,
                                                    IN DWORD DllSize,
                                                    IN PMODLOAD_DATA Data,
                                                    IN DWORD Flags);
typedef BOOL (WINAPI *dbghelp_SymUnloadModule64_t)(IN HANDLE hProcess,
                                                     IN DWORD64 BaseOfDll);
typedef BOOL (WINAPI *dbghelp_SymGetModuleInfoW64_t)(IN HANDLE hProcess,
                                                        IN DWORD64 dwAddr,
                                                        OUT PIMAGEHLP_MODULEW64 ModuleInfo);
static dbghelp_SymInitializeW_t sym_init_func;
static dbghelp_SymCleanupW_t sym_cleanup_func;
static dbghelp_SymSetSearchPathW_t sym_set_path_func;
static dbghelp_SymLoadModuleExW_t sym_load_module_func;
static dbghelp_SymUnloadModule64_t sym_unload_module_func;
static dbghelp_SymGetModuleInfoW64_t sym_get_module_info_func;

#define MAX_SYMSRV_PATH MAX_PATH

/* Semi-compatibility with the Windows CRT _access function.
 */
drfront_status_t
drfront_access(const char *fname, drfront_access_mode_t mode, OUT bool *ret)
{
    int r;
    int msdn_mode = 00;
    TCHAR wfname[MAX_PATH];
    drfront_status_t status_check = DRFRONT_ERROR;

    if (ret == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;

    status_check = drfront_char_to_tchar(fname, wfname, MAX_PATH);
    if (status_check != DRFRONT_SUCCESS) {
        *ret = false;
        return status_check;
    }

    /* Translate drfront_access_mode_t to msdn _waccess mode */
    if (TEST(mode, DRFRONT_WRITE))
        msdn_mode |= 02;
    if (TEST(mode, DRFRONT_READ))
        msdn_mode |= 04;

    r = _waccess(wfname, msdn_mode);

    if (r == -1) {
        *ret = false;
        if (GetLastError() == EACCES)
            return DRFRONT_SUCCESS;
        return DRFRONT_ERROR;
    }

    *ret = true;
    return DRFRONT_SUCCESS;
}

/* Implements a normal path search for fname on the paths in env_var. Resolves symlinks,
 * which is needed to get the right config filename (i#1062).
 */
drfront_status_t
drfront_searchenv(const char *fname, const char *env_var, OUT char *full_path,
                  const size_t full_path_size, OUT bool *ret)
{
    drfront_status_t status_check = DRFRONT_ERROR;
    size_t size_needed = 0;
    TCHAR wfname[MAX_PATH];
    /* XXX: Not sure what the size for environment variable names should be.
     *      Perhaps we want a drfront_char_to_tchar_size_needed
     */
    TCHAR wenv_var[MAX_PATH];
    TCHAR wfull_path[MAX_PATH];

    if (full_path == NULL && ret == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;

    status_check = drfront_char_to_tchar(fname, wfname, BUFFER_SIZE_ELEMENTS(wfname));
    if (status_check != DRFRONT_SUCCESS) {
        *ret = false;
        return status_check;
    }
    status_check = drfront_char_to_tchar(env_var, wenv_var,
                                         BUFFER_SIZE_ELEMENTS(wenv_var));
    if (status_check != DRFRONT_SUCCESS) {
        *ret = false;
        return status_check;
    }

    _wsearchenv(wfname, wenv_var, wfull_path);

    if (wfull_path[0] == L'\0') {
        *ret = false;
        return DRFRONT_ERROR;
    }

    status_check = drfront_tchar_to_char_size_needed(wfull_path, &size_needed);
    if (status_check != DRFRONT_SUCCESS) {
        *ret = false;
        return status_check;
    } else if (full_path_size < size_needed) {
        *ret = true;
        return DRFRONT_ERROR_INVALID_SIZE;
    }

    status_check = drfront_tchar_to_char(wfull_path, full_path, full_path_size);
    if (status_check != DRFRONT_SUCCESS) {
        *ret = false;
        return status_check;
    }
    full_path[full_path_size - 1] = '\0';
    *ret = true;
    return DRFRONT_SUCCESS;
}

/* always null-terminates */
drfront_status_t
drfront_tchar_to_char(const TCHAR *wstr, OUT char *buf, size_t buflen/*# elements*/)
{
    int res = WideCharToMultiByte(CP_UTF8, 0, wstr, -1/*null-term*/,
                                  buf, (int)buflen, NULL, NULL);
    if (res <= 0)
        return DRFRONT_ERROR;
    buf[buflen - 1] = '\0';
    return DRFRONT_SUCCESS;
}

/* includes the terminating null */
drfront_status_t
drfront_tchar_to_char_size_needed(const TCHAR *wstr, OUT size_t *needed)
{
    if (needed == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;
    *needed =  WideCharToMultiByte(CP_UTF8, 0, wstr, -1/*null-term*/, NULL, 0, NULL,
                                   NULL);
    return DRFRONT_SUCCESS;
}

/* always null-terminates */
drfront_status_t
drfront_char_to_tchar(const char *str, OUT TCHAR *wbuf, size_t wbuflen/*# elements*/)
{
    int res = MultiByteToWideChar(CP_UTF8, 0/*=>MB_PRECOMPOSED*/, str, -1/*null-term*/,
                                  wbuf, (int)wbuflen);
    if (res <= 0)
        return DRFRONT_ERROR;
    wbuf[wbuflen - 1] = L'\0';
    return DRFRONT_SUCCESS;
}

drfront_status_t
drfront_get_env_var(const char *name, OUT char *buf, size_t buflen/*# elements*/)
{
    TCHAR wbuf[MAX_PATH];
    /* XXX: Not sure what the size for environment variable names should be. */
    TCHAR wname[MAX_PATH];
    drfront_status_t res =
        drfront_char_to_tchar(name, wname, BUFFER_SIZE_ELEMENTS(wname));
    if (res != DRFRONT_SUCCESS)
        return res;
    if (GetEnvironmentVariable(wname, wbuf, BUFFER_SIZE_ELEMENTS(wbuf)) > 0) {
        return drfront_tchar_to_char(wbuf, buf, buflen);
    }
    return DRFRONT_ERROR;
}

drfront_status_t
drfront_get_absolute_path(const char *src, OUT char *buf, size_t buflen/*# elements*/)
{
    TCHAR wsrc[MAX_PATH];
    TCHAR wdst[MAX_PATH];
    drfront_status_t status_check = DRFRONT_ERROR;
    int res;

    status_check = drfront_char_to_tchar(src, wsrc, BUFFER_SIZE_ELEMENTS(wsrc));
    if (status_check != DRFRONT_SUCCESS)
        return status_check;

    res = GetFullPathName(wsrc, BUFFER_SIZE_ELEMENTS(wdst), wdst, NULL);
    if (res <= 0)
        return DRFRONT_ERROR;

    NULL_TERMINATE_BUFFER(wdst);
    status_check = drfront_tchar_to_char(wdst, buf, buflen);
    return status_check;
}

drfront_status_t
drfront_get_app_full_path(const char *app, OUT char *buf, size_t buflen/*# elements*/)
{
    TCHAR wbuf[MAX_PATH];
    TCHAR wapp[MAX_PATH];
    drfront_status_t status_check = DRFRONT_ERROR;

    status_check = drfront_char_to_tchar(app, wapp, BUFFER_SIZE_ELEMENTS(wapp));
    if (status_check != DRFRONT_SUCCESS)
        return status_check;

    _tsearchenv(wapp, _T("PATH"), wbuf);
    NULL_TERMINATE_BUFFER(wbuf);
    if (wbuf[0] == _T('\0')) {
        /* may need to append .exe, FIXME : other executable types */
        TCHAR tmp_buf[MAX_PATH];
        _sntprintf(tmp_buf, BUFFER_SIZE_ELEMENTS(tmp_buf), _T("%s%s"), wapp, _T(".exe"));
        NULL_TERMINATE_BUFFER(wbuf);
        _tsearchenv(tmp_buf, _T("PATH"), wbuf);
    }
    if (wbuf[0] == _T('\0')) {
        /* last try: expand w/ cur dir */
        GetFullPathName(wapp, BUFFER_SIZE_ELEMENTS(wbuf), wbuf, NULL);
        NULL_TERMINATE_BUFFER(wbuf);
    }
    status_check = drfront_tchar_to_char(wbuf, buf, buflen);
    return status_check;
}

drfront_status_t
drfront_set_symbol_search_path(const char *symdir, bool ignore_env)
{
    char app_symsrv_path[MAX_SYMSRV_PATH];
    TCHAR wapp_symsrv_path[MAX_SYMSRV_PATH];
    TCHAR wsymsrv_path[MAX_SYMSRV_PATH];
    char tmp_srv_path[MAX_SYMSRV_PATH];
    char tmp_symsrv_path[MAX_SYMSRV_PATH];
    char *cur;
    char *end;
    size_t sofar;
    ssize_t len;
    bool has_srv;
    bool dir_exists;
    bool has_ms_symsrv;
    drfront_status_t sc;
    static const char ms_symsrv[] = "http://msdl.microsoft.com/download/symbols";

    if (sym_set_path_func == NULL)
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    /* If the user set a non-empty _NT_SYMBOL_PATH, then we use that.
     * If not, we use symdir/symbols path and make sure it exists.
     */
    if (ignore_env ||
        drfront_get_env_var("_NT_SYMBOL_PATH", tmp_symsrv_path,
                            BUFFER_SIZE_ELEMENTS(tmp_symsrv_path)) != DRFRONT_SUCCESS ||
        strlen(tmp_symsrv_path) == 0) {
        char pdb_dir[MAXIMUM_PATH];
        _snprintf(pdb_dir, BUFFER_SIZE_ELEMENTS(pdb_dir), "%s/symbols", symdir);
        NULL_TERMINATE_BUFFER(pdb_dir);
        drfront_string_replace_character(pdb_dir, '/', '\\'); /* canonicalize */
        sc = drfront_create_dir(pdb_dir);
        if (sc != DRFRONT_SUCCESS ||
            drfront_access(pdb_dir, DRFRONT_READ, &dir_exists) != DRFRONT_SUCCESS ||
            !dir_exists) {
            DO_DEBUG(DL_WARN,
                     printf("Failed to create directory for symbols: %s\n", pdb_dir);
                     );
            return DRFRONT_ERROR_INVALID_PATH;
        }
        strncpy(tmp_symsrv_path, pdb_dir, BUFFER_SIZE_ELEMENTS(tmp_symsrv_path));
        NULL_TERMINATE_BUFFER(tmp_symsrv_path);
    }
    /* Prepend "srv*" if it isn't there, and append the MS symbol server if it
     * isn't there.
     */
    has_srv = (_strnicmp("srv*", tmp_symsrv_path, 4) == 0);
    has_ms_symsrv = (strstr(tmp_symsrv_path, ms_symsrv) != NULL);
    _snprintf(tmp_srv_path, BUFFER_SIZE_ELEMENTS(tmp_srv_path),
              "%s%s%s%s",
              (has_srv ? "" : "srv*"),
              tmp_symsrv_path,
              (has_ms_symsrv ? "" : "*"),
              (has_ms_symsrv ? "" : ms_symsrv));
    NULL_TERMINATE_BUFFER(tmp_srv_path);
    strncpy(tmp_symsrv_path, tmp_srv_path, BUFFER_SIZE_ELEMENTS(tmp_symsrv_path));
    NULL_TERMINATE_BUFFER(tmp_symsrv_path);

    /* For app_symsrv_path, split tmp_symsrv_path on '*' and filter out all the
     * non-directory elements.
     */
    strncpy(tmp_srv_path, tmp_symsrv_path, BUFFER_SIZE_ELEMENTS(tmp_srv_path));
    NULL_TERMINATE_BUFFER(tmp_srv_path);
    cur = tmp_srv_path;
    end = strchr(tmp_srv_path, '\0');
    drfront_string_replace_character(tmp_srv_path, '*', '\0');
    sofar = 0;
    app_symsrv_path[0] = '\0';
    while (cur < end) {
        char *next = strchr(cur, '\0');
        if (drfront_access(cur, DRFRONT_READ, &dir_exists) == DRFRONT_SUCCESS &&
            dir_exists) {
            drfront_bufprint(app_symsrv_path, BUFFER_SIZE_ELEMENTS(app_symsrv_path),
                             &sofar, &len, "%s*", cur);
        }
        cur = next + 1;
    }
    if (sofar > 0)
        app_symsrv_path[sofar-1] = '\0';  /* Cut trailing '*'. */
    if (app_symsrv_path[0] == '\0') {
        if (!ignore_env) {
            /* Easiest to recurse.  Bool prevents 2nd recursion. */
            DO_DEBUG(DL_WARN,
                     printf("All _NT_SYMBOL_PATH dirs doesn't exist. Trying to"\
                            "use user-provided path.");
                     );
            return drfront_set_symbol_search_path(symdir, true);
        } else {
            DO_DEBUG(DL_WARN,
                     printf("error parsing _NT_SYMBOL_PATH: may fail to fetch symbols\n");
                     );
            return DRFRONT_ERROR;
        }
    }
    DO_DEBUG(DL_INFO,
             printf("using symbol path %s as the local store\n", app_symsrv_path);
             );
    DO_DEBUG(DL_INFO,
             printf("using symbol path %s to fetch symbols\n", tmp_symsrv_path);
             );

    /* Set _NT_SYMBOL_PATH for dbghelp in the app. */
    drfront_char_to_tchar(app_symsrv_path, wapp_symsrv_path,
                          BUFFER_SIZE_ELEMENTS(wapp_symsrv_path));
    if (!SetEnvironmentVariable(_T("_NT_SYMBOL_PATH"), wapp_symsrv_path)) {
        DO_DEBUG(DL_INFO,
                 printf("SetEnvironmentVariable failed: %d\n", GetLastError());
                 );
        return DRFRONT_ERROR;
    }
    /* We're using SymSetSearchPath here to allow symbols fetching with
     * SymLoadModuleEx.
     */
    drfront_char_to_tchar(tmp_symsrv_path, wsymsrv_path,
                          BUFFER_SIZE_ELEMENTS(wsymsrv_path));
    if (!sym_set_path_func(GetCurrentProcess(), wsymsrv_path))  {
         DO_DEBUG(DL_WARN,
                  printf("SymSetSearchPathW failed %d", GetLastError);
                  );
        return DRFRONT_ERROR;
    }
    return DRFRONT_SUCCESS;
}

drfront_status_t
drfront_sym_init(const char *symsrv_path, const char *dbghelp_path)
{
    HANDLE proc_handle = GetCurrentProcess();
    TCHAR wdbghelp_path[MAX_PATH];
    TCHAR wsymsrv_path[MAX_SYMSRV_PATH];
    /* check that it's first call */
    if (hlib != NULL)
        return DRFRONT_ERROR;
    if (dbghelp_path == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;
    drfront_char_to_tchar(dbghelp_path, wdbghelp_path,
                          BUFFER_SIZE_ELEMENTS(wdbghelp_path));
    hlib = LoadLibraryW(wdbghelp_path);
    if (hlib == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("dbghelp.dll load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR;
    }
    sym_init_func = (dbghelp_SymInitializeW_t) GetProcAddress(hlib, "SymInitializeW");
    if (sym_init_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymInitializeW load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    sym_cleanup_func = (dbghelp_SymCleanupW_t) GetProcAddress(hlib, "SymCleanup");
    if (sym_cleanup_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymCleanup load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    sym_set_path_func = (dbghelp_SymSetSearchPathW_t)
                                              GetProcAddress(hlib, "SymSetSearchPathW");
    if (sym_set_path_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymSetSearchPathW load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    sym_load_module_func = (dbghelp_SymLoadModuleExW_t)
                                              GetProcAddress(hlib, "SymLoadModuleExW");
    if (sym_load_module_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymLoadModuleExW load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    sym_unload_module_func = (dbghelp_SymUnloadModule64_t)
                                              GetProcAddress(hlib, "SymUnloadModule64");
    if (sym_unload_module_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymUnloadModule64 load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    sym_get_module_info_func = (dbghelp_SymGetModuleInfoW64_t)
                                              GetProcAddress(hlib, "SymGetModuleInfoW64");
    if (sym_get_module_info_func == NULL) {
        DO_DEBUG(DL_WARN,
                 printf("SymGetModuleInfoW64 load failed %d", GetLastError);
                 );
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    }
    if (symsrv_path != NULL) {
        drfront_char_to_tchar(symsrv_path, wsymsrv_path,
                              BUFFER_SIZE_ELEMENTS(wsymsrv_path));
    }
    if (!sym_init_func(proc_handle, wsymsrv_path, FALSE)) {
        DO_DEBUG(DL_WARN,
                 printf("SymInitializeW failed %d", GetLastError);
                 );
        return DRFRONT_ERROR;
    }

    return DRFRONT_SUCCESS;
}

drfront_status_t
drfront_sym_exit(void)
{
    HANDLE proc = GetCurrentProcess();
    if (sym_cleanup_func == NULL)
        return DRFRONT_ERROR_LIB_UNSUPPORTED;
    if (!sym_cleanup_func(proc))
        return DRFRONT_ERROR;
    if (!FreeLibrary(hlib))
        return DRFRONT_ERROR;
    return DRFRONT_SUCCESS;
}


bool
drfront_fetch_module_symbols(const char *modpath, OUT char *symbol_path,
                             size_t symbol_path_sz)
{
    DWORD64 base;
    IMAGEHLP_MODULEW64 mod_info;
    bool got_pdbs = FALSE;
    TCHAR wmodpath[MAXIMUM_PATH];
    char buf[MAXIMUM_PATH];
    HANDLE proc = GetCurrentProcess();

    if (sym_load_module_func == NULL ||
        sym_get_module_info_func == NULL ||
        sym_unload_module_func == NULL)
        return DRFRONT_ERROR_LIB_UNSUPPORTED;

    drfront_char_to_tchar(modpath, wmodpath, BUFFER_SIZE_ELEMENTS(wmodpath));

    /* The SymSrv* API calls are complicated.  It's easier to set the symbol
     * path to point at a server and rely on SymLoadModuleEx to fetch symbols.
     */
    /* We must use SymLoadModuleEx as there's no wide version of SymLoadModule64 */
    base = sym_load_module_func(proc, NULL, wmodpath, NULL, 0, 0, NULL, 0);
    if (base == 0) {
        DO_DEBUG(DL_WARN,
                 printf("SymLoadModuleEx error: %d", GetLastError());
                 );
        return DRFRONT_ERROR;
    }

    /* Check that we actually got pdbs. */
    memset(&mod_info, 0, sizeof(mod_info));
    mod_info.SizeOfStruct = sizeof(mod_info);
    if (sym_get_module_info_func(proc, base, &mod_info)) {
        switch (mod_info.SymType) {
        case SymPdb:
        case SymDeferred:
            DO_DEBUG(DL_INFO,
                     printf("  pdb for %s stored at %S",
                            modpath, mod_info.LoadedPdbName);
                     );
            got_pdbs = TRUE;
            break;
        case SymExport:
            DO_DEBUG(DL_WARN,
                     printf("  failed to fetch pdb for %s, exports only",
                            modpath);
                     );
            break;
        default:
            DO_DEBUG(DL_WARN,
                     printf("  failed to fetch pdb for %s, got SymType %d",
                            modpath, mod_info.SymType);
                     );
            break;
        }
    } else {
        DO_DEBUG(DL_WARN,
                 printf("SymGetModuleInfoEx failed: %d", GetLastError());
                 );
    }
    if (symbol_path_sz != 0) {
        drfront_tchar_to_char(mod_info.LoadedPdbName,
                              buf, BUFFER_SIZE_ELEMENTS(buf));
        strncpy(symbol_path, buf, symbol_path_sz);
        NULL_TERMINATE_BUFFER(symbol_path);
    }
    /* Unload it. */
    if (!sym_unload_module_func(proc, base)) {
        DO_DEBUG(DL_WARN,
                 printf("SymUnloadModule64 error %d", GetLastError());
                 );
    }

    return got_pdbs;
}

/* On failure returns INVALID_HANDLE_VALUE.
 * On success returns a file handle which must be closed via CloseHandle()
 * by the caller.
 */
static HANDLE
read_nt_headers(const char *exe, IMAGE_NT_HEADERS *nt)
{
    HANDLE f;
    DWORD offs;
    DWORD read;
    IMAGE_DOS_HEADER dos;
    TCHAR wexe[MAX_PATH];
    drfront_status_t status_check = DRFRONT_ERROR;

    status_check = drfront_char_to_tchar(exe, wexe, BUFFER_SIZE_ELEMENTS(wexe));
    if (status_check != DRFRONT_SUCCESS)
        return INVALID_HANDLE_VALUE;

    f = CreateFile(wexe, GENERIC_READ, FILE_SHARE_READ,
                   NULL, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, NULL);
    if (f == INVALID_HANDLE_VALUE)
        goto read_nt_headers_error;
    if (!ReadFile(f, &dos, sizeof(dos), &read, NULL) ||
        read != sizeof(dos) ||
        dos.e_magic != IMAGE_DOS_SIGNATURE)
        goto read_nt_headers_error;
    offs = SetFilePointer(f, dos.e_lfanew, NULL, FILE_BEGIN);
    if (offs == INVALID_SET_FILE_POINTER)
        goto read_nt_headers_error;
    if (!ReadFile(f, nt, sizeof(*nt), &read, NULL) ||
        read != sizeof(*nt) ||
        nt->Signature != IMAGE_NT_SIGNATURE)
        goto read_nt_headers_error;
    return f;
 read_nt_headers_error:
    if (f != INVALID_HANDLE_VALUE)
        CloseHandle(f);
    return INVALID_HANDLE_VALUE;
}

drfront_status_t
drfront_is_64bit_app(const char *exe, OUT bool *is_64)
{
    bool res = false;
    IMAGE_NT_HEADERS nt;
    HANDLE f = NULL;

    if (is_64 == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;

    f = read_nt_headers(exe, &nt);
    if (f == INVALID_HANDLE_VALUE) {
        *is_64 = res;
        return DRFRONT_ERROR_INVALID_PARAMETER;
    }
    res = (nt.OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC);
    CloseHandle(f);
    *is_64 = res;
    return DRFRONT_SUCCESS;
}

drfront_status_t
drfront_is_graphical_app(const char *exe, OUT bool *is_graphical)
{
    /* reads the PE headers to see whether the given image is a graphical app */
    bool res = false; /* err on side of console */
    IMAGE_NT_HEADERS nt;
    HANDLE f = NULL;

    if (is_graphical == NULL)
        return DRFRONT_ERROR_INVALID_PARAMETER;

    f = read_nt_headers(exe, &nt);
    if (f == INVALID_HANDLE_VALUE) {
        *is_graphical = res;
        return DRFRONT_ERROR_INVALID_PARAMETER;
    }
    res = (nt.OptionalHeader.Subsystem == IMAGE_SUBSYSTEM_WINDOWS_GUI);
    CloseHandle(f);
    *is_graphical = res;
    return DRFRONT_SUCCESS;
}
