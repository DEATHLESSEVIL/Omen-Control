#!/usr/bin/env python3
"""Export only reviewed project sources; never glob the private workspace."""
from pathlib import Path
import shutil,zipfile,hashlib,json
root=Path(__file__).resolve().parents[1]
out=root/'Source-project'
if out.exists():shutil.rmtree(out)
out.mkdir()
folders=['.github','Sources','Tests','Scripts','OmenControl.xcodeproj','Installer','Docs']
for name in folders:
 shutil.copytree(root/name,out/name,ignore=shutil.ignore_patterns('__pycache__','xcuserdata','*.xcuserstate'))
for name in ['LICENSE','THIRD-PARTY-NOTICES.md','Package.swift','README.md','INSTALLATION.md','.gitignore','build-app.sh','Install-OMEN-Control.command']:
 shutil.copy2(root/name,out/name)
for name in ['FanPolicy.h','OmenFanBridge.cpp','FanModule.cpp','test-fan-policy.cpp','build-fan-bridge.sh','PROTOCOL.md']:
 dest=out/'Driver'/name;dest.parent.mkdir(exist_ok=True);shutil.copy2(root/'Driver'/name,dest)
for name in ['Info.plist','AppIcon.icns']:
 dest=out/'Resources'/name;dest.parent.mkdir(exist_ok=True);shutil.copy2(root/'Resources'/name,dest)
shutil.copytree(root/'Resources/IconPNGs',out/'Resources/IconPNGs')
shutil.copytree(root/'Resources/Branding',out/'Resources/Branding')
shutil.copytree(root/'Resources/LaunchDaemons',out/'Resources/LaunchDaemons')
files=sorted(p for p in out.rglob('*') if p.is_file())
manifest={str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
(out/'SOURCE-SHA256.json').write_text(json.dumps(manifest,indent=2)+'\n')
archive=root/'dist/OMEN-Control-Source.zip';archive.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
 for p in sorted(out.rglob('*')):
  if p.is_file():z.write(p,Path('OMEN-Control')/p.relative_to(out))
print(f'Exported {len(manifest)} source files to {out}')
print(f'Source archive: {archive}')
