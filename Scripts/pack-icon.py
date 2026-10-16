#!/usr/bin/env python3
"""Pack ImageIO-generated PNGs into an ICNS without extra dependencies."""
from pathlib import Path
import struct
root=Path(__file__).resolve().parents[1]/'Resources'
chunks=[]
for tag,size in [('ic07',128),('ic08',256),('ic09',512),('ic10',1024),('ic11',32),('ic12',64),('ic13',256),('ic14',512)]:
 data=(root/f'IconPNGs/icon-{size}.png').read_bytes()
 chunks.append(tag.encode()+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
(root/'AppIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
