#!/usr/bin/env python3
"""Genera src/parc_presets_data.inc desde las fuentes de FreeArc: la tabla builtinMethodSubsts
de Compression.hs y el orden/patrones de grupos de arc.groups. Así la tabla es la de FreeArc
textual, sin transcribir a mano. Uso: tools/gen_presets.py Compression.hs tools/freearc/arc.groups src/parc_presets_data.inc"""
import re, sys
hs = open(sys.argv[1], encoding='cp1251').read()
m = re.search(r'builtinMethodSubsts = \[(.*?)\n    \]', hs, re.S)
lines = re.findall(r'^\s*,?\s*"((?:[^"\\]|\\.)*)"', m.group(1), re.M)
groups = open(sys.argv[2], encoding='cp1251').read().splitlines()
def pas(s):
    return "'" + s.replace("'", "''") + "'"
out = ['{ GENERADO por tools/gen_presets.py desde Compression.hs (builtinMethodSubsts) y arc.groups',
       '  de FreeArc 0.67. No editar a mano. }', '',
       'const', f'  BUILTIN_METHOD_SUBSTS: array[0..{len(lines)-1}] of string = (']
out += ['    ' + pas(l) + (',' if i < len(lines)-1 else '') for i, l in enumerate(lines)]
out += ['  );', '']
g = [x.strip() for x in groups if x.strip() and not x.strip().startswith(';')]
out += [f'  ARC_GROUPS: array[0..{len(g)-1}] of string = (']
out += ['    ' + pas(l) + (',' if i < len(g)-1 else '') for i, l in enumerate(g)]
out += ['  );', '']
open(sys.argv[3], 'w', encoding='utf-8').write('\n'.join(out))
print(f'{len(lines)} sustituciones, {len(g)} líneas de grupos')
