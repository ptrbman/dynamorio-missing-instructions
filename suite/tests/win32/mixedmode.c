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

/* Built as 32-bit and then run on WOW64 with 64-bit DR to test mixed-mode
 * (i#49, i#751)
 */

#ifndef ASM_CODE_ONLY /* C code */
#include "tools.h" /* for print() */

/* asm routines */
void test_top_bits(void);
int test_iret(void);

char global_data[8];

int main(int argc, char *argv[])
{
    test_top_bits();
    print("r8 was 0x%I64x\n", *(__int64*)global_data);

    print("test_iret() returned %d\n", test_iret());
    return 0;
}

#else /* asm code *************************************************************/
#include "asm_defines.asm"
START_FILE

/* N.B.: it's tricky to write this code b/c it's built with a 32-bit assembler
 * so we have to use raw bytes and play games to get the 64-bit code generated.
 * It's also quite difficult to get a disasm listing for this all in one
 * shot.
 *
 * We can use exx in 64-bit mode, making it easier to read the
 * assembly, b/c we know top bits are zeroed.
 */

# define CS32_SELECTOR HEX(23)
# define CS64_SELECTOR HEX(33)
# define SS_SELECTOR   HEX(2b)

DECL_EXTERN(global_data)

/* These are messy to make functions b/c the call/ret are different modes,
 * so we do macros and pass in a name to make the labels unique.
 */
# define SWITCH_32_TO_64(label)                         \
        /* far jmp to next instr w/ 64-bit switch */ @N@\
        /* jmp 0033:<topbits_transfer_to_64> */      @N@\
        RAW(ea)                                      @N@\
          DD offset switch_32_to_64_##label          @N@\
          DB CS64_SELECTOR                           @N@\
          RAW(00)                                    @N@\
    switch_32_to_64_##label:                         @N@\
        nop

# define SWITCH_64_TO_32(label)                                                       \
        /* far jmp to next instr w/ 32-bit switch */                               @N@\
        /* jmp 0023:<topbits_return_to_32_A> */                                    @N@\
        push     offset switch_64_to_32_##label  /* 8-byte push */                 @N@\
        mov      dword ptr [esp + 4], CS32_SELECTOR /* top 4 bytes of prev push */ @N@\
        jmp      fword ptr [esp]                                                   @N@\
    switch_64_to_32_##label:                                                       @N@\
        lea  esp, [esp + 8]     /* undo the x64 push */

/* Tests whether r8's value is preserved across mode switches */
# define FUNCNAME test_top_bits
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        SWITCH_32_TO_64(set_r8)
        /* mov r8, $0x1234567812345678 */
        RAW(49)
          mov      eax, HEX(12345678)
          DD HEX(12345678)
        SWITCH_64_TO_32(no_more_r8)
        SWITCH_32_TO_64(retrieve_r8)
        /* We can't do "mov [global_data], r8" by just prefixing 32-bit instr b/c
         * abs addr turns into rip-rel, so we put global_data into ecx
         */
        mov      ecx, offset global_data
        /* mov qword ptr [rcx], r8 */
        RAW(4c)
          mov      dword ptr [ecx], eax
        SWITCH_64_TO_32(back_to_normal)
        ret
        END_FUNC(FUNCNAME)
# undef FUNCNAME

# define FUNCNAME test_iret
        DECLARE_FUNC(FUNCNAME)
GLOBAL_LABEL(FUNCNAME:)
        pushfd
        push     CS64_SELECTOR
        push     offset iret_32_to_64
        iretd
    iret_32_to_64:
        /* back to 32-bit via 64-bit iret */
        mov      edx, esp
        push     SS_SELECTOR
        push     edx
        pushfd   /* really pushfq */
        push     CS32_SELECTOR
        push     offset iret_64_to_32
        RAW(48)
          iretd  /* iretq */
    iret_64_to_32:
        /* ensure we're 32-bit */
        daa

        pushfd
        push     CS64_SELECTOR
        push     offset iret_32_to_64_B
        iretd
    iret_32_to_64_B:
        /* ensure we're 64-bit by returning ecx */
        mov ecx, 0
        /* 64-bit "add r8,1" vs 32-bit "dec ecx; add eax,1" */
        RAW(49)
          add    eax, 1
        mov      eax, ecx
        /* back to 32-bit via 32-bit iret => need 4-byte stack operands */
        /* XXX: despite the Intel manual pseudocode, 32-bit iret pops ss:rsp */
        pushfd   /* really pushfq */
        pop      ecx
        mov      edx, esp
        lea      esp, [esp - 20]
        mov      dword ptr [esp + 16], SS_SELECTOR
        mov      dword ptr [esp + 12], edx
        mov      dword ptr [esp + 8], ecx
        mov      dword ptr [esp + 4], CS32_SELECTOR
        mov      dword ptr [esp], offset iret_64_to_32_B
        iretd
    iret_64_to_32_B:
        nop

        ret                      /* return value already in eax */
        END_FUNC(FUNCNAME)
# undef FUNCNAME

END_FILE
#endif /* ASM_CODE_ONLY */
