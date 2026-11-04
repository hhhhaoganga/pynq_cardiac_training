"""Adapt the released row compiler in this candidate only."""
from pathlib import Path

root=Path(__file__).resolve().parent
assert not (root/'compile_single.py').exists(), 'Compiler is now maintained directly; preserve stripe support'
s=(root.parent/'sv_knot/compile_program.py').read_text()
for before,after in [
    ('WT:7680,WD:256,PP:1024,PD:512','WT:10240,WD:1536,PP:1024,PD:1024'),
    ('base//1024<4','base//1024<6'),
    ('k in (1,3)','k in (1,3,5)'),
    ('max(icg,ecg,ocg)<=21','max(icg,ecg,ocg)<=42'),
    ('pl in (0,1) and iw%2==0 and iw<=320 and ew*ecg<=480','pl in (0,1,2) and iw<=320 and ew*ecg<=512'),
    ('dw*ocg*(8 if pm==2 else 2)<=512','(not pm or dw*ocg*(8 if pm==2 else 2)<=512)'),
    ('d[46]+d[47]<=1176 and ecg*3<=63','d[46]+d[47]<=1024 and ecg*5<=210'),
    ('5*(d[46]+d[47])','10*(d[46]+d[47])'),
    ('4*ecg*3','7*ecg*5'),
    ('PP,336','PP,ecg*16'),
    ('d[46],336,','d[46],ecg*16,'),
    ('slot=(slot+1)%4','slot=(slot+1)%6'),
    ('(oy*s-pt)%4','(oy*s-pt)%6'),
    ("padded_channels=16,valid_channels=7,dtype='little-endian int32'", "padded_channels=ocg*16,valid_channels=ocg*16,dtype='int8 codes'"),
]:
    assert before in s,before
    s=s.replace(before,after)
(root/'compile_single.py').write_text(s,newline='\n')
