#!/usr/bin/env python3
"""Build a clean public app, source archive and documented experimental installer.
Requires an explicit OpenCore 1.0.8 ocvalidate; never accesses or changes live EFI.
"""
from pathlib import Path
import argparse, hashlib, os, plistlib, shutil, subprocess, tempfile, zipfile
root=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--validator',type=Path,required=True);p.add_argument('--local-artwork',action='store_true',help='Build a private local installer preserving optional artwork');args=p.parse_args()
validator=args.validator.resolve()
def run(*args,**kwargs):return subprocess.run([str(a) for a in args],check=True,**kwargs)
release_label='Omen-Control-Alpha-1.0V'
version=plistlib.loads((root/'Resources/Info.plist').read_bytes())['CFBundleShortVersionString']
info=subprocess.run([str(validator)],capture_output=True,text=True)
assert 'OpenCore version 1.0.8' in info.stdout+info.stderr,'Provide the matching ocvalidate 1.0.8.'
run('zsh',root/'build-app.sh')
run('zsh',root/'Driver/build-fan-bridge.sh')
release=root/('dist/LocalRelease' if args.local_artwork else 'dist/Release');release.mkdir(parents=True,exist_ok=True)
for old in [*release.glob('OMEN-Control-*'),*release.glob('Omen-Control-Alpha-*')]:
 if old.is_file():old.unlink()
with tempfile.TemporaryDirectory(prefix='omen-release-') as folder:
 stage=Path(folder);payload=stage/'payload';scripts=stage/'scripts';scripts.mkdir()
 app=payload/'Applications/OmenControl.app';app.parent.mkdir(parents=True)
 shutil.copytree(root/'dist/OmenControl.app',app)
 # Optional local artwork is excluded from public installers.
 if not args.local_artwork:shutil.rmtree(app/'Contents/Resources/LocalFanArtwork',ignore_errors=True)
 shutil.copy2(root/'LICENSE',app/'Contents/Resources/LICENSE')
 run('codesign','--force','--sign','-',app)
 run('codesign','--verify','--deep','--strict',app)
 support=payload/'Library/Application Support/OMEN Control';tools=support/'Tools';tools.mkdir(parents=True)
 run('swiftc','-O','-target','x86_64-apple-macos13.0','-framework','IOKit',root/'Installer/Tools/main.swift','-o',tools/'omen-installer')
 run(tools/'omen-installer','--self-test')
 shutil.copy2(validator,tools/'ocvalidate')
 shutil.copy2(root/'Installer/Tools/configure-login.sh',tools/'configure-login.sh')
 driver=support/'Driver/OmenFanBridge.kext';driver.parent.mkdir()
 shutil.copytree(root/'dist/OmenFanBridge.kext',driver)
 docs=support/'Documentation';docs.mkdir()
 for name in ['README.md','INSTALLATION.md','LICENSE','THIRD-PARTY-NOTICES.md']:
  shutil.copy2(root/name,docs/name)
 shutil.copytree(root/'Docs',docs/'Docs')
 shutil.copy2(root/'Installer/Resources/OpenCore-LICENSE.txt',docs/'OpenCore-LICENSE.txt')
 for name in ['preinstall','postinstall']:shutil.copy2(root/'Installer/Scripts'/name,scripts/name)
 for name in ['omen-installer','ocvalidate']:shutil.copy2(tools/name,scripts/name)
 for path in scripts.iterdir():path.chmod(0o755)
 for path in payload.rglob('*'):
  if path.is_dir():path.chmod(0o755)
  elif path in [tools/'omen-installer',tools/'ocvalidate',tools/'configure-login.sh',app/'Contents/MacOS/OmenControl',app/'Contents/MacOS/OmenPowerHelper',driver/'Contents/MacOS/OmenFanBridge']:path.chmod(0o755)
  else:path.chmod(0o644)
 components=stage/'components.plist'
 run('pkgbuild','--analyze','--root',payload,components)
 values=plistlib.loads(components.read_bytes())
 for item in values:
  item['BundleIsRelocatable']=False;item['BundleIsVersionChecked']=True;item['BundleOverwriteAction']='upgrade'
 components.write_bytes(plistlib.dumps(values))
 run('pkgbuild','--root',payload,'--scripts',scripts,'--component-plist',components,'--identifier','local.omen.control.package','--version',version,'--install-location','/','--ownership','recommended',stage/'omen-component.pkg')
 distribution=(root/'Installer/Distribution.xml').read_text().replace('@VERSION@',version)
 (stage/'Distribution.xml').write_text(distribution)
 installer=release/f'{release_label}-8C78-Experimental.pkg'
 run('productbuild','--distribution',stage/'Distribution.xml','--resources',root/'Installer/Resources','--package-path',stage,installer)
 with zipfile.ZipFile(release/f'{release_label}-App.zip','w',zipfile.ZIP_DEFLATED) as z:
  for file in sorted(app.rglob('*')):
   if file.is_file():z.write(file,Path('OmenControl.app')/file.relative_to(app))
 # Source exporter copies only allowlisted public files.
 run('python3',root/'Scripts/package-source.py')
 shutil.copy2(root/'dist/OMEN-Control-Source.zip',release/f'{release_label}-Source.zip')
 shutil.copy2(root/'Docs/RELEASE-NOTES.md',release/'RELEASE-NOTES.md')
 shutil.copy2(root/'Docs/LIMITATIONS.md',release/'LIMITATIONS.md')
shas=[]
for file in sorted(release.iterdir()):
 if file.is_file() and file.name!='SHA256SUMS.txt':shas.append(f'{hashlib.sha256(file.read_bytes()).hexdigest()}  {file.name}')
(release/'SHA256SUMS.txt').write_text('\n'.join(shas)+'\n')
print('Release assets:',release)
print('Unsigned experimental PKG: not Developer-ID signed or notarized. No live EFI was modified.')
# One convenient local download; individual Release assets remain ready for GitHub.
bundle=root/'dist'/f'{release_label}-{"Local-" if args.local_artwork else ""}All-Files.zip'
with zipfile.ZipFile(bundle,'w',zipfile.ZIP_DEFLATED) as z:
 prefix=Path(release_label)
 for file in sorted(release.iterdir()):
  if file.is_file():z.write(file,prefix/file.name)
 for name in ['README.md','INSTALLATION.md','LICENSE','THIRD-PARTY-NOTICES.md']:
  z.write(root/name,prefix/'Documentation'/name)
 for file in sorted((root/'Docs').rglob('*')):
  if file.is_file():z.write(file,prefix/'Documentation/Docs'/file.relative_to(root/'Docs'))
print('All files bundle:',bundle)
