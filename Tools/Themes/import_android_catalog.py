#!/usr/bin/env python3
"""Import reference palette samples; rendering stays platform-specific."""
import argparse, hashlib, json, re, subprocess
from pathlib import Path
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--android', type=Path, default=root.parent/'obadh-android')
parser.add_argument('--check', action='store_true', help='Verify generated files without changing them')
args=parser.parse_args()
android=args.android
source=android/'integration/heliboard/src/helium314/keyboard/latin/obadh/ObadhThemeCatalog.kt'
s=source.read_text()
starts=list(re.finditer(r'Theme\("([^\"]+)", "([^\"]+)", "([^\"]+)"',s))
def content_at(block,pos):
    start=block.index('(',pos); depth=1; end=start+1
    while depth:
        if block[end]=='(': depth+=1
        if block[end]==')': depth-=1
        end+=1
    return block[start+1:end-1]
rows=[]
for i,m in enumerate(starts):
    block=s[m.start():starts[i+1].start() if i+1<len(starts) else len(s)]
    palette=content_at(block,block.index('ObadhColors.Palette'))
    values=[int(x,16) for x in re.findall(r'0x[0-9a-f]+',palette)]
    arrays=[content_at(block,a.start()) for a in re.finditer('intArrayOf',block)]
    gradients=[int(x,16) for x in re.findall(r'0x[0-9a-f]+',arrays[0])] if arrays else []
    mesh=[int(x,16) for x in re.findall(r'0x[0-9a-f]+',arrays[1])] if len(arrays)>1 else []
    positions=[]
    if 'floatArrayOf' in block:
        positions=[float(x) for x in re.findall(r'([0-9]+\.[0-9]+)f',content_at(block,block.index('floatArrayOf')))]
    assert len(values)==5 and (not gradients or len(positions)==len(gradients))
    rows.append(dict(id=m[1],name=m[2],group=m[3],palette=values,gradient=gradients,positions=positions,mesh=mesh))
assert len(rows)==71 and len({r['id'] for r in rows})==71
manifest=dict(sourceRevision=subprocess.check_output(['git','-C',str(android),'log','-1','--format=%H','--',str(source.relative_to(android))],text=True).strip(),sourceSHA256=hashlib.sha256(source.read_bytes()).hexdigest(),themes=rows)
manifest_text=json.dumps(manifest,indent=2)+'\n'
lines=['// Generated reference palette samples. See Tools/Themes/android-catalog.json.', '// Source Android revision: '+manifest['sourceRevision'], 'import Foundation', '', 'extension KeyboardThemeCatalog {','    static let presets: [KeyboardThemePreset] = [']
for r in rows:
    def arr(v): return '['+', '.join(f'0x{x:08X}' for x in v)+']'
    positions='['+', '.join(str(x) for x in r['positions'])+']'
    lines += [f'        KeyboardThemePreset(id: "{r["id"]}", name: "{r["name"]}", group: "{r["group"]}",',f'            palette: {arr(r["palette"])}, gradient: {arr(r["gradient"])},',f'            positions: {positions}, mesh: {arr(r["mesh"])}),']
lines += ['    ]','}','']
generated={root/'Tools/Themes/android-catalog.json': manifest_text,
           root/'Shared/Sources/Appearance/KeyboardThemeCatalog+Presets.swift': '\n'.join(lines)}
for path, text in generated.items():
    if args.check:
        assert path.read_text()==text, f'{path} differs; regenerate and review the catalog changes'
    else:
        path.write_text(text)
print('Imported',len(rows),'presets;',sum(bool(r['mesh']) for r in rows),'two-dimensional gradients')
