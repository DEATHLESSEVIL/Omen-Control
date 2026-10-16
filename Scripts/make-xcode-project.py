#!/usr/bin/env python3
"""Generate a small native app project; no third-party project generator needed."""
from pathlib import Path
import hashlib, json, plistlib
root=Path(__file__).resolve().parents[1]
project=root/'OmenControl.xcodeproj';project.mkdir(exist_ok=True)
def uid(s):return hashlib.sha256(s.encode()).hexdigest()[:24].upper()
def q(s):return json.dumps(str(s))
objects=[]
def obj(key,body):objects.append(f'{uid(key)} = {{ {body} }};');return uid(key)
sources=sorted([*root.glob('Sources/OmenControl/*.swift'),*root.glob('Sources/OmenCore/*.swift'),*root.glob('Sources/PowerProtocol/*.swift'),*root.glob('Sources/SMCReader/*.c')])
refs=[]; builds=[]
for p in sources:
 rel=str(p.relative_to(root));typ='sourcecode.swift' if p.suffix=='.swift' else 'sourcecode.c.c'
 ref=obj(rel,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(rel)}; sourceTree = "<group>";');refs.append(ref)
 builds.append(obj('build'+rel,f'isa = PBXBuildFile; fileRef = {ref};'))
icon=obj('icon','isa = PBXFileReference; lastKnownFileType = image.icns; path = Resources/AppIcon.icns; sourceTree = "<group>";');refs.append(icon)
iconbuild=obj('iconbuild',f'isa = PBXBuildFile; fileRef = {icon};')
notice=obj('notice','isa = PBXFileReference; lastKnownFileType = text; path = "THIRD-PARTY-NOTICES.md"; sourceTree = "<group>";');refs.append(notice)
noticebuild=obj('noticebuild',f'isa = PBXBuildFile; fileRef = {notice};')
license_ref=obj('license','isa = PBXFileReference; lastKnownFileType = text; path = LICENSE; sourceTree = \"<group>\";');refs.append(license_ref)
license_build=obj('licensebuild',f'isa = PBXBuildFile; fileRef = {license_ref};')
for rel,typ in [('README.md','net.daringfireball.markdown'),('Resources/Info.plist','text.plist.xml'),('Sources/SMCReader/include/SMCReader.h','sourcecode.c.h'),('Sources/OmenPowerHelper/main.swift','sourcecode.swift'),('Resources/LaunchDaemons/local.omen.power.plist','text.plist.xml')]:refs.append(obj(rel,f'isa = PBXFileReference; lastKnownFileType = {typ}; path = {q(rel)}; sourceTree = "<group>";'))
product=obj('product','isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = OmenControl.app; sourceTree = BUILT_PRODUCTS_DIR;')
products=obj('products',f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group=obj('group',f'isa = PBXGroup; children = ({",".join(refs)},{products},); sourceTree = "<group>";')
src=obj('sources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
res=obj('resources',f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({iconbuild},{noticebuild},{license_build},); runOnlyForDeploymentPostprocessing = 0;')
fw=obj('frameworks','isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
helper_script = 'set -eu\nmkdir -p "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons"\ncp "$SRCROOT/Resources/LaunchDaemons/local.omen.power.plist" "$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchDaemons/"\nxcrun swiftc -parse-as-library -O -target x86_64-apple-macos13.0 "$SRCROOT/Sources/PowerProtocol/PowerProtocol.swift" "$SRCROOT/Sources/OmenPowerHelper/main.swift" -o "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OmenPowerHelper"\n/usr/bin/codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/OmenPowerHelper"\n/bin/rm -rf "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LocalFanArtwork"'
helper_script += '\nif [ -d "$SRCROOT/Resources/LocalFanArtwork" ]; then ditto "$SRCROOT/Resources/LocalFanArtwork" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/LocalFanArtwork"; fi'

helper_script += '\nditto "$SRCROOT/Resources/Branding" "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Branding"'

helper=obj('powerhelper',f'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); alwaysOutOfDate = 1; runOnlyForDeploymentPostprocessing = 0; name = "Build power helper"; shellPath = /bin/sh; shellScript = {q(helper_script)};')
common={'ARCHS':'x86_64','SDKROOT':'macosx','MACOSX_DEPLOYMENT_TARGET':'13.0','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CODE_SIGN_IDENTITY':'-','CODE_SIGN_STYLE':'Manual','PRODUCT_BUNDLE_IDENTIFIER':'local.omen.control','PRODUCT_NAME':'OmenControl','INFOPLIST_FILE':'Resources/Info.plist','SWIFT_INCLUDE_PATHS':'$(SRCROOT)/Sources/SMCReader/include','HEADER_SEARCH_PATHS':'$(SRCROOT)/Sources/SMCReader/include','LD_RUNPATH_SEARCH_PATHS':'$(inherited) @executable_path/../Frameworks','OTHER_LDFLAGS':'-framework AppKit -framework IOKit -framework CoreFoundation','ENABLE_USER_SCRIPT_SANDBOXING':'NO','ENABLE_APP_SANDBOX':'NO','GENERATE_INFOPLIST_FILE':'NO'}
configs=[]
for name in ['Debug','Release']:
 settings=dict(common);settings['SWIFT_OPTIMIZATION_LEVEL']='-Onone' if name=='Debug' else '-O'
 if name=='Debug':settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
 body=' '.join(f'{k} = {q(v)};' for k,v in settings.items())
 configs.append(obj('config'+name,f'isa = XCBuildConfiguration; buildSettings = {{ {body} }}; name = {name};'))
cl=obj('configs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target=obj('target',f'isa = PBXNativeTarget; buildConfigurationList = {cl}; buildPhases = ({src},{fw},{res},{helper},); buildRules = (); dependencies = (); name = OmenControl; productName = OmenControl; productReference = {product}; productType = "com.apple.product-type.application";')
pconfigs=[]
for name in ['Debug','Release']:pconfigs.append(obj('project'+name,f'isa = XCBuildConfiguration; buildSettings = {{}}; name = {name};'))
pcl=obj('projectconfigs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(pconfigs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
pid=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 1600; }}; buildConfigurationList = {pcl}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {pid}; }}\n')
scheme=project/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
ref=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="OmenControl.app" BlueprintName="OmenControl" ReferencedContainer="container:OmenControl.xcodeproj"/>'
(scheme/'OmenControl.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="YES" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
info={'CFBundleIdentifier':'local.omen.control','CFBundleName':'Omen Control Alpha 1.0V','CFBundleDisplayName':'Omen Control Alpha 1.0V','CFBundleExecutable':'OmenControl','CFBundlePackageType':'APPL','CFBundleShortVersionString':'1.0','CFBundleVersion':'20','CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':'13.0','LSUIElement':True,'NSHighResolutionCapable':True,'NSPrincipalClass':'NSApplication'}
with (root/'Resources/Info.plist').open('wb') as f:plistlib.dump(info,f)
print('Generated OmenControl.xcodeproj')
