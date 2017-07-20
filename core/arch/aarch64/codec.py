#!/usr/bin/python

# **********************************************************
# Copyright (c) 2016 ARM Limited. All rights reserved.
# **********************************************************

# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# * Redistributions of source code must retain the above copyright notice,
#   this list of conditions and the following disclaimer.
#
# * Redistributions in binary form must reproduce the above copyright notice,
#   this list of conditions and the following disclaimer in the documentation
#   and/or other materials provided with the distribution.
#
# * Neither the name of ARM Limited nor the names of its contributors may be
#   used to endorse or promote products derived from this software without
#   specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL ARM LIMITED OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
# DAMAGE.

# This script reads "codec.txt" and generates "decode_gen.h", "encode_gen.h",
# "opcode.h" and "opcode_names.h". Run it manually, in this directory, when
# "codec.txt" has been changed.

import re

N = 32 # bits in an instruction word
ONES = (1 << N) - 1

header = '/* This file was generated by codec.py from codec.txt. */\n\n'

class Opnd:
    def __init__(self, gen, used):
        self.gen = gen
        self.used = used

class Opndset:
    def __init__(self, fixed, dsts, srcs, enc_order):
        for (ds, i, ot) in enc_order:
            if not ((ds == 'dst' or ds == 'src') and
                    (dsts if ds == 'dst' else srcs)[i] == ot):
                raise Exception
        self.fixed = fixed
        self.dsts = dsts
        self.srcs = srcs
        self.enc_order = enc_order

def generate_decoder(patterns, opndsettab, opndtab):

    def generate_opndset_decoders(c, opndsettab):
        for name in sorted(opndsettab):
            os = opndsettab[name]
            (dsts, srcs) = (os.dsts, os.srcs)
            c += ['static bool',
                  ('decode_opnds%s' % name) + '(uint enc, dcontext_t *dcontext, ' +
                  'byte *pc, instr_t *instr, int opcode)',
                  '{']
            if dsts + srcs != []:
                vars = (['dst%d' % i for i in range(len(dsts))] +
                        ['src%d' % i for i in range(len(srcs))])
                tests = (['!decode_opnd_%s(enc & 0x%08x, opcode, pc, &dst%d)' %
                          (dsts[i], opndtab[dsts[i]].gen | opndtab[dsts[i]].used, i)
                          for i in range(len(dsts))]
                         +
                         ['!decode_opnd_%s(enc & 0x%08x, opcode, pc, &src%d)' %
                          (srcs[i], opndtab[srcs[i]].gen | opndtab[srcs[i]].used, i)
                          for i in range(len(srcs))])
                c += ['    opnd_t ' + ', '.join(vars) + ';']
                c += ['    if (' + ' ||\n        '.join(tests) + ')']
                c += ['        return false;']
            c.append('    instr_set_opcode(instr, opcode);')
            c.append('    instr_set_num_opnds(dcontext, instr, %d, %d);' %
                     (len(dsts), len(srcs)))
            for i in range(len(dsts)):
                c.append('    instr_set_dst(instr, %d, dst%d);' % (i, i))
            for i in range(len(srcs)):
                c.append('    instr_set_src(instr, %d, src%d);' % (i, i))
            c.append('    return true;')
            c.append('}')
            c.append('')

    # Recursive function to generate nested conditionals in main decoder.
    def gen(c, pats, depth):
        indent = "    " * depth
        if len(pats) < 4:
            for (f, v, m, t) in sorted(pats, key = lambda (f, v, m, t): (m, t, f, v)):
                c.append('%sif ((enc & 0x%08x) == 0x%08x)' %
                         (indent, ((1 << N) - 1) & ~v, f))
                c.append('%s    return decode_opnds%s(enc, dc, pc, instr, OP_%s);' %
                         (indent, t, m))
            return
        # Look for best bit to test. We aim to reduce the number of patterns remaining.
        best_b = -1
        best_x = len(pats)
        for b in range(N):
            x0 = 0
            x1 = 0
            for (f, v, _, _) in pats:
                if (1 << b) & (~f | v):
                    x0 += 1
                if (1 << b) & (f | v):
                    x1 += 1
            x = max(x0, x1)
            if x < best_x:
                best_b = b
                best_x = x
        c.append('%sif ((enc >> %d & 1) == 0) {' % (indent, best_b))
        pats0 = []
        pats1 = []
        for p in pats:
            (f, v, _, _) = p
            if (1 << best_b) & (~f | v):
                pats0.append(p)
            if (1 << best_b) & (f | v):
                pats1.append(p)
        gen(c, pats0, depth + 1)
        c.append('%s} else {' % indent)
        gen(c, pats1, depth + 1)
        c.append('%s}' % indent)

    c = []
    generate_opndset_decoders(c, opndsettab)
    c += ['static bool',
          'decoder(uint enc, dcontext_t *dc, byte *pc, instr_t *instr)',
          '{']
    gen(c, patterns, 1)
    c.append('    return false;')
    c.append('}')
    return '\n'.join(c) + '\n'

def find_required(fixed, reordered, i, opndtab):
    known = fixed
    used = opndtab[reordered[i][2]].used
    req = []
    for j in range(i):
        if used & ~known == 0:
            break
        if opndtab[reordered[j][2]].gen & used & ~known != 0:
            req = req + ['%s%d' % (reordered[j][0], reordered[j][1])]
            known = known | opndtab[reordered[j][2]].gen
    return ('enc' if req == [] else '(enc | %s)' % ' | '.join(req))

def make_enc(n, reordered, f, opndtab):
    (ds, i, ot) = reordered[n]
    return ('encode_opnd_%s(%s, opcode, '
            'pc, instr_get_%s(instr, %d), &%s%d)' %
            (ot, ("0" if opndtab[ot].used == 0 else
                  'enc & 0x%08x' % opndtab[ot].used
                  if opndtab[ot].used & ~f == 0 else
                  '%s & 0x%08x' % (find_required(f, reordered, n, opndtab),
                                   opndtab[ot].used)),
             ds, i, ds, i))

def generate_encoder(patterns, opndsettab, opndtab):
    c = []
    for name in sorted(opndsettab):
        os = opndsettab[name]
        (fixed, dsts, srcs, enc_order) = (os.fixed, os.dsts, os.srcs, os.enc_order)
        c += ['static uint',
              ('encode_opnds%s' % name) + '(byte *pc, instr_t *instr, uint enc)',
              '{']
        if dsts + srcs == []:
            c.append('    return enc;')
        else:
            vars = (['dst%d' % i for i in range(len(dsts))] +
                    ['src%d' % i for i in range(len(srcs))])
            c += ['    int opcode = instr->opcode;']
            # The initial values are only required to silence a bad compiler warning:
            c += ['    uint ' + ' = 0, '.join(vars) + ' = 0;']
            tests = (['instr_num_dsts(instr) == %d && instr_num_srcs(instr) == %d' %
                      (len(dsts), len(srcs))] +
                     [make_enc(i, enc_order, fixed, opndtab)
                      for i in range(len(enc_order))])

            tests2 = (['dst%d == (enc & 0x%08x)' % (i, opndtab[dsts[i]].gen)
                       for i in range(len(dsts))] +
                      ['src%d == (enc & 0x%08x)' % (i, opndtab[srcs[i]].gen)
                       for i in range(len(srcs))])
            c += ['    if (' + ' &&\n        '.join(tests) + ') {']
            c += ['        ASSERT((dst%d & 0x%08x) == 0);' %
                  (i, ONES & ~opndtab[dsts[i]].gen) for i in range(len(dsts))]
            c += ['        ASSERT((src%d & 0x%08x) == 0);' %
                  (i, ONES & ~opndtab[srcs[i]].gen) for i in range(len(srcs))]
            c += ['        enc |= ' + ' | '.join(vars) + ';']
            c += ['        if (' + ' &&\n            '.join(tests2) + ')']
            c += ['            return enc;']
            c += ['    }']
            c += ['    return ENCFAIL;']
        c.append('}')
        c.append('')
    case = dict()
    for p in patterns:
        (b, m, mn, f) = p
        if not mn in case:
            case[mn] = []
        case[mn].append(p)
    c += ['static uint',
          'encoder(byte *pc, instr_t *instr)',
          '{',
          '    uint enc;',
          '    (void)enc;',
          '    switch (instr->opcode) {']
    for mn in sorted(case):
        c.append('    case OP_%s:' % mn)
        pats = sorted(case[mn], key = lambda (b, m, mn, f): (mn, f, b, m))
        pat1 = pats.pop()
        for p in pats:
            (b, m, mn, f) = p
            c.append('        enc = encode_opnds%s(pc, instr, 0x%08x);' % (f, b))
            c.append('        if (enc != ENCFAIL)')
            c.append('            return enc;')
        (b, m, mn, f) = pat1
        c.append('        return encode_opnds%s(pc, instr, 0x%08x);' % (f, b))
    c += ['    }',
          '    return ENCFAIL;',
          '}']
    return '\n'.join(c) + '\n'

def generate_opcodes(patterns):
    mns = dict()
    for p in patterns:
        mns[p[2]] = 1
    c = ['#ifndef OPCODE_H',
         '#define OPCODE_H 1',
         '',
         '/* DR_API EXPORT TOFILE dr_ir_opcodes_aarch64.h */',
         '/* DR_API EXPORT BEGIN */',
         '',
         '/****************************************************************************',
         ' * OPCODES',
         ' */',
         '/**',
         ' * @file dr_ir_opcodes_aarch64.h',
         ' * @brief Instruction opcode constants for AArch64.',
         ' */',
         '/** Opcode constants for use in the instr_t data structure. */',
         'enum {',
         '/*   0 */     OP_INVALID,  /* NULL, */ /**< INVALID opcode */',
         '/*   1 */     OP_UNDECODED,  /* NULL, */ /**< UNDECODED opcode */',
         '/*   2 */     OP_CONTD,    /* NULL, */ /**< CONTD opcode */',
         '/*   3 */     OP_LABEL,    /* NULL, */ /**< LABEL opcode */',
         '']
    i = 4
    for mn in sorted(mns):
        t = '/*%4d */     OP_%s,' % (i, mn)
        t += ' ' * max(0, 34 - len(t))
        c.append(t + '/**< AArch64 %s opcode.*/' % mn)
        i += 1
    c += ['',
          '    OP_ldstex, /* single-entry single-exit block with exclusive load/store */',
          '    OP_xx, /* placeholder for undecoded instructions */',
          '',
          '    OP_AFTER_LAST,',
          '    OP_FIRST = OP_LABEL + 1,      /**< First real opcode. */',
          '    OP_LAST  = OP_AFTER_LAST - 1, /**< Last real opcode. */',
          '};',
          '',
          '/* alternative names */',
          '#define OP_jmp       OP_b      '
          '/**< Platform-independent opcode name for jump. */',
          '#define OP_jmp_short OP_b      '
          '/**< Platform-independent opcode name for short jump. */',
          '#define OP_load      OP_ldr    '
          '/**< Platform-independent opcode name for load. */',
          '#define OP_store     OP_str    '
          '/**< Platform-independent opcode name for store. */',
          '',
          '/******************************'
          '**********************************************/',
          '/* DR_API EXPORT END */',
          '',
          '#endif /* OPCODE_H */']
    return '\n'.join(c) + '\n'

def generate_opcode_names(patterns):
    mns = dict()
    for p in patterns:
        mns[p[2]] = 1
    c = ['#ifndef OPCODE_NAMES_H',
         '#define OPCODE_NAMES_H 1',
         '',
         'const char *opcode_names[] = {',
         '/*   0 */ "<invalid>",',
         '/*   1 */ "<undecoded>",',
         '/*   2 */ "<contd>",',
         '/*   3 */ "<label>",']
    i = 4
    for mn in sorted(mns):
        c.append('/*%4d */ "%s",' % (i, mn))
        i += 1
    c += ['          "ldstex",',
          '          "xx",',
          '};',
          '',
          '#endif /* OPCODE_NAMES_H */']
    return '\n'.join(c) + '\n'

def write_if_changed(file, data):
    try:
        if open(file, 'r').read() == data:
            return
    except IOError:
        pass
    open(file, 'w').write(data)

def read_file(path):
    file = open(path, 'r')
    opndtab = dict()
    patterns = []
    for line in file:
        # Remove comment and trailing spaces.
        line = re.sub("\s*(#.*)?\n?$", "", line)
        if line == '':
            continue
        if re.match("^[x\?-]{32} +[a-zA-Z_0-9]+$", line):
            # Syntax: mask opndtype
            (mask, opndtype) = line.split()
            if opndtype in opndtab:
                raise Exception('Repeated definition of opndtype %s' % opndtype)
            opndtab[opndtype] = Opnd(int(re.sub("x", "1", re.sub("[^x]", "0", mask)), 2),
                                     int(re.sub("\?", "1", re.sub("[^\?]", "0", mask)), 2))
            continue
        if re.match("^[01x]{32} +[a-zA-Z_0-9][a-zA-Z_0-9 ]*:[a-zA-Z_0-9 ]*$", line):
            # Syntax: pattern opcode opndtype* : opndtype*
            (str1, str2) = line.split(":")
            (words, srcs) = (str1.split(), str2.split())
            (pattern, opcode, dsts) = (words[0], words[1], words[2:])
            opcode_bits = int(re.sub("x", "0", pattern), 2)
            opnd_bits = int(re.sub("x", "1", re.sub("1", "0", pattern)), 2)
            patterns.append((opcode_bits, opnd_bits, opcode, (dsts, srcs)))
            continue
        if re.match("^[01x]{32} +[a-zA-Z_0-9]+ +[a-zA-Z_0-9]+", line):
            # Syntax: pattern opcode opndset
            (pattern, opcode, opndset) = line.split()
            opcode_bits = int(re.sub("x", "0", pattern), 2)
            opnd_bits = int(re.sub("x", "1", re.sub("1", "0", pattern)), 2)
            patterns.append((opcode_bits, opnd_bits, opcode, opndset))
            continue
        raise Exception('Cannot parse line: %s' % line)
    return (patterns, opndtab)

def pattern_to_str((opcode_bits, opnd_bits, opcode, opndset)):
    p = ''
    for i in range(N - 1, -1, -1):
        p += 'x' if (opnd_bits >> i & 1) else '%d' % (opcode_bits >> i & 1)
    t = opndset
    if not type(t) is str:
        (dsts, srcs) = t
        t = ' '.join(dsts) + ' : ' + ' '.join(srcs)
    return '%s %s %s' % (p, opcode, t)

def consistency_check(patterns, opndtab):
    for p in patterns:
        (opcode_bits, opnd_bits, opcode, opndset) = p
        if not type(opndset) is str:
            (dsts, srcs) = opndset
            bits = opnd_bits
            bits0 = bits
            for ot in dsts + srcs:
                if not ot in opndtab:
                    raise Exception('Undefined opndtype %s in:\n%s' %
                                    (ot, pattern_to_str(p)))
                bits &= ~opndtab[ot].gen
            if bits != 0:
                raise Exception('Unhandled bits:\n%32s in:\n%s' %
                                (re.sub('1', 'x', re.sub('0', ' ', bin(bits)[2:])),
                                 pattern_to_str(p)))
    for i in range(len(patterns)):
        for j in range(i):
            if ((patterns[j][0] ^ patterns[i][0]) &
                ~patterns[j][1] & ~patterns[i][1] == 0):
                raise Exception('Overlapping patterns:\n%s\n%s' %
                                (pattern_to_str(patterns[j]),
                                 pattern_to_str(patterns[i])))

# This function reorders the operands for encoding so that no operand encoder
# requires bits that are generated by an operand encoder that has not yet
# been executed.
def reorder_opnds(fixed, dsts, srcs, opndtab):
    def reorder(known, opnds):
        if opnds == []:
            return []
        for i in range(len(opnds)):
            (_, _, _, gen, used) = opnds[i]
            if used & ~known == 0:
                return [opnds[i]] + reorder(known | gen, opnds[0:i] + opnds[i + 1:])
        raise Exception('Cyclic dependency: %s' %
                        ' '.join([x for (_, _, x, _, _) in opnds]))
    opnds = ([('dst', i, dsts[i]) for i in range(len(dsts))] +
             [('src', i, srcs[i]) for i in range(len(srcs))])
    opnds_expanded = [(ds, i, ot, opndtab[ot].gen, opndtab[ot].used)
                      for (ds, i, ot) in opnds]
    opnds_reordered = [(ds, i, ot)
                       for (ds, i, ot, _, _) in reorder(fixed, opnds_expanded)]
    return Opndset(fixed, dsts, srcs, opnds_reordered)

# Here we give the opndsets names, which will be used in function names.
# Opndsets specified in "codec.txt" are prefixed with '_', while generated
# names have the form "gen_X", where X is the hex representation of the
# smallest matching instruction word.
def opndset_naming(patterns, opndtab):
    opndsets = dict() # maps (dst, src, opnd_bits) to smallest pattern seen so far
    for (opcode_bits, opnd_bits, opcode, opndset) in patterns:
        if not type(opndset) is str:
            (dsts, srcs) = opndset
            h = (' '.join(dsts), ' '.join(srcs), opnd_bits)
            if not h in opndsets or opcode_bits < opndsets[h]:
                opndsets[h] = opcode_bits

    opndsettab = dict() # maps generated name to original opndsets
    new_patterns = []
    for (opcode_bits, opnd_bits, opcode, opndset) in patterns:
        if type(opndset) is str:
            new_opndset = '_' + opndset
        else:
            (dsts, srcs) = opndset
            h = (' '.join(dsts), ' '.join(srcs), opnd_bits)
            new_opndset = 'gen_%08x' % opndsets[h]
            reordered = reorder_opnds(ONES & ~opnd_bits, dsts, srcs, opndtab)
            if not new_opndset in opndsettab:
                opndsettab[new_opndset] = reordered
        new_patterns.append((opcode_bits, opnd_bits, opcode, new_opndset))
    return (new_patterns, opndsettab)

def main():
    (patterns, opndtab) = read_file('codec.txt')
    consistency_check(patterns, opndtab)
    (patterns, opndsettab) = opndset_naming(patterns, opndtab)
    write_if_changed('decode_gen.h',
                     header + generate_decoder(patterns, opndsettab, opndtab))
    write_if_changed('encode_gen.h',
                     header + generate_encoder(patterns, opndsettab, opndtab))
    write_if_changed('opcode.h',
                     header + generate_opcodes(patterns))
    write_if_changed('opcode_names.h',
                     header + generate_opcode_names(patterns))

if __name__ == "__main__":
    main()
