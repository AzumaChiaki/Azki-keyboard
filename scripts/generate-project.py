#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Generate an original, dependency-free Xcode project for the app, keyboard extension and UI tests."""
from pathlib import Path
import hashlib
import json
import plistlib
import shutil

ROOT = Path(__file__).resolve().parent.parent
objects = {}

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def obj(object_key, isa, **values):
    key = ident(object_key)
    objects[key] = dict(isa=isa, **values)
    return key

def quote(value, depth=0):
    indent = "\t" * depth
    child = "\t" * (depth + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        return "{\n" + "\n".join(f"{child}{quote(k)} = {quote(v, depth + 1)};" for k, v in value.items()) + "\n" + indent + "}"
    if isinstance(value, list):
        if not value:
            return "()"
        return "(\n" + "\n".join(f"{child}{quote(x, depth + 1)}," for x in value) + "\n" + indent + ")"
    return json.dumps(str(value), ensure_ascii=False)

def plist(path, contents):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        plistlib.dump(contents, f, sort_keys=True)

config = ROOT / "Configuration"
base_info = dict(CFBundleDevelopmentRegion="zh_CN", CFBundleDisplayName="Azki输入法",
                 CFBundleExecutable="$(EXECUTABLE_NAME)", CFBundleIdentifier="$(PRODUCT_BUNDLE_IDENTIFIER)", AzkiAppGroup="$(AZKI_APP_GROUP)",
                 CFBundleInfoDictionaryVersion="6.0", CFBundleName="$(PRODUCT_NAME)",
                 CFBundleShortVersionString="1.0", CFBundleVersion="1", LSRequiresIPhoneOS=True)
voice_usage = dict(NSMicrophoneUsageDescription="语音输入需要使用麦克风，声音只在本机识别。",
                   NSSpeechRecognitionUsageDescription="语音输入在本机把声音转成文字，不会上传。")
plist(config / "App-Info.plist", dict(base_info, **voice_usage, CFBundlePackageType="APPL", UILaunchScreen={},
      UIFileSharingEnabled=True, LSSupportsOpeningDocumentsInPlace=True, UIBackgroundModes=["audio"],
      CFBundleURLTypes=[{"CFBundleURLName": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleURLSchemes": ["azkiinput"]}],
      UISupportedInterfaceOrientations=["UIInterfaceOrientationPortrait", "UIInterfaceOrientationPortraitUpsideDown", "UIInterfaceOrientationLandscapeLeft", "UIInterfaceOrientationLandscapeRight"],
      UIApplicationSceneManifest={"UIApplicationSupportsMultipleScenes": False}))
plist(config / "Keyboard-Info.plist", dict(base_info, CFBundlePackageType="XPC!",
      NSExtension={"NSExtensionPointIdentifier": "com.apple.keyboard-service",
                   "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).KeyboardViewController",
                   "NSExtensionAttributes": {"IsASCIICapable": True, "PrefersRightToLeft": False,
                                             "PrimaryLanguage": "zh-Hans", "RequestsOpenAccess": True}}))
for target in ("App", "Keyboard"):
    plist(config / f"{target}.entitlements", {"com.apple.security.application-groups": ["$(AZKI_APP_GROUP)"]})

# Build the original branding into native appearance-aware asset catalogs.
assets = ROOT / "Resources/Assets.xcassets"
(assets / "AppIcon.appiconset").mkdir(parents=True, exist_ok=True)
(assets / "BrandMark.imageset").mkdir(parents=True, exist_ok=True)
(assets / "Contents.json").write_text(json.dumps({"info": {"author": "Azki Native", "version": 1}}), encoding="utf-8")
images = []
for appearance, suffix in ((None, "light"), ("dark", "dark"), ("tinted", "tinted")):
    filename = f"AzkiInputMethod-{suffix}-1024.png"
    source = ROOT / "Resources/Branding" / filename
    if not source.is_file():
        raise SystemExit(f"Missing original brand asset: {source}")
    shutil.copyfile(source, assets / "AppIcon.appiconset" / filename)
    item = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
    if appearance:
        item["appearances"] = [{"appearance": "luminosity", "value": appearance}]
    images.append(item)
(assets / "AppIcon.appiconset/Contents.json").write_text(json.dumps({"images": images, "info": {"author": "Azki Native", "version": 1}}, indent=2), encoding="utf-8")
markimages = []
for appearance, suffix in ((None, "light"), ("dark", "dark")):
    filename = f"AzkiInputMethod-{suffix}-1024.png"
    shutil.copyfile(ROOT / "Resources/Branding" / filename, assets / "BrandMark.imageset" / filename)
    item = {"filename": filename, "idiom": "universal"}
    if appearance:
        item["appearances"] = [{"appearance": "luminosity", "value": appearance}]
    markimages.append(item)
(assets / "BrandMark.imageset/Contents.json").write_text(json.dumps({"images": markimages, "info": {"author": "Azki Native", "version": 1}}, indent=2), encoding="utf-8")

file_refs = {}
for path in sorted((ROOT / "Sources").rglob("*.swift")):
    relative = path.relative_to(ROOT).as_posix()
    file_refs[relative] = obj("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
for path in sorted((ROOT / "Tests/UI").glob("*.swift")):
    relative = path.relative_to(ROOT).as_posix()
    file_refs[relative] = obj("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift", path=relative, sourceTree="SOURCE_ROOT")
resources = {"Resources/PrivacyInfo.xcprivacy": "text.xml", "Resources/lexicon.sqlite": "file", "Resources/dictionary-manifest.json": "text.json", "Resources/Licenses": "folder", "Resources/Assets.xcassets": "folder.assetcatalog", "Sources/Core/Resources/dialects.json": "text.json", "Sources/Core/Resources/emoji.json": "text.json", "Sources/Core/Resources/traditional.tsv": "text", "Sources/Core/Resources/traditional-tw.tsv": "text", "Sources/Core/Resources/traditional-hk.tsv": "text"}
for path, kind in resources.items():
    file_refs[path] = obj("file:" + path, "PBXFileReference", lastKnownFileType=kind, path=path, sourceTree="SOURCE_ROOT")

app_product = obj("product:app", "PBXFileReference", explicitFileType="wrapper.application", path="AzkiInputMethod.app", sourceTree="BUILT_PRODUCTS_DIR")
extension_product = obj("product:keyboard", "PBXFileReference", explicitFileType="wrapper.app-extension", path="AzkiKeyboard.appex", sourceTree="BUILT_PRODUCTS_DIR")
products = obj("products", "PBXGroup", children=[app_product, extension_product], name="Products", sourceTree="<group>")
# Navigator references do not imply target membership. Core remains compiled into
# both native products; Package.swift independently exposes its unit tests.
for folder in ("Configuration", "scripts", "docs", "Tests/CoreTests"):
    for path in sorted((ROOT / folder).rglob("*")):
        if path.is_file() and "__pycache__" not in path.parts:
            relative = path.relative_to(ROOT).as_posix()
            kind = {".xcconfig": "text.xcconfig", ".plist": "text.plist.xml", ".entitlements": "text.plist.entitlements", ".swift": "sourcecode.swift"}.get(path.suffix, "text")
            file_refs[relative] = obj("file:" + relative, "PBXFileReference", lastKnownFileType=kind, path=relative, sourceTree="SOURCE_ROOT")
for relative in ("README.md", "LICENSE", "Package.swift", "resources.lock.json"):
    file_refs[relative] = obj("file:" + relative, "PBXFileReference", lastKnownFileType="sourcecode.swift" if relative.endswith(".swift") else "text", path=relative, sourceTree="SOURCE_ROOT")

def navigator(prefix=""):
    children = []
    folders = set()
    for path, ref in file_refs.items():
        if not path.startswith(prefix):
            continue
        remaining = path[len(prefix):]
        if "/" in remaining:
            folders.add(remaining.split("/", 1)[0])
        else:
            children.append(ref)
    groups = [obj("group:" + prefix + folder, "PBXGroup", name=folder,
                  children=navigator(prefix + folder + "/"), sourceTree="<group>")
              for folder in sorted(folders)]
    return groups + children

main_group = obj("main", "PBXGroup", children=navigator() + [products], sourceTree="<group>")

def configs(target):
    configs = []
    for mode in ("Debug", "Release"):
        common = dict(SWIFT_VERSION="5.0", IPHONEOS_DEPLOYMENT_TARGET="16.3", CLANG_ENABLE_MODULES="YES",
                      SWIFT_STRICT_CONCURRENCY="targeted", SDKROOT="iphoneos", TARGETED_DEVICE_FAMILY="1,2",
                      SUPPORTED_PLATFORMS="iphoneos iphonesimulator", SUPPORTS_MACCATALYST="NO",
                      ENABLE_USER_SCRIPT_SANDBOXING="YES",
                      DEBUG_INFORMATION_FORMAT="dwarf" if mode == "Debug" else "dwarf-with-dsym",
                      SWIFT_OPTIMIZATION_LEVEL="-Onone" if mode == "Debug" else "-O",
                      SWIFT_ACTIVE_COMPILATION_CONDITIONS="DEBUG" if mode == "Debug" else "",
                      GCC_PREPROCESSOR_DEFINITIONS=["$(inherited)", "DEBUG=1"] if mode == "Debug" else ["$(inherited)"])
        if target == "UITests":
            common.update(IPHONEOS_DEPLOYMENT_TARGET="17.0",
                          PRODUCT_NAME="AzkiNativeUITests", PRODUCT_MODULE_NAME="AzkiNativeUITests",
                          PRODUCT_BUNDLE_IDENTIFIER="$(AZKI_BUNDLE_IDENTIFIER).UITests", GENERATE_INFOPLIST_FILE="YES",
                          TEST_TARGET_NAME="AzkiInputMethod")
        elif target != "Project":
            app = target == "App"
            common.update(PRODUCT_NAME="AzkiInputMethod" if app else "AzkiKeyboard",
                          PRODUCT_MODULE_NAME="AzkiInputMethod" if app else "AzkiKeyboard",
                          PRODUCT_BUNDLE_IDENTIFIER="$(AZKI_BUNDLE_IDENTIFIER)" + ("" if app else ".Keyboard"),
                          INFOPLIST_FILE=f"Configuration/{target}-Info.plist", GENERATE_INFOPLIST_FILE="NO",
                          CODE_SIGN_ENTITLEMENTS=f"Configuration/{target}.entitlements",
                          CURRENT_PROJECT_VERSION="1", MARKETING_VERSION="1.0", OTHER_LDFLAGS=["$(inherited)", "-lsqlite3"],
                          LD_RUNPATH_SEARCH_PATHS=["$(inherited)", "@executable_path/Frameworks", "@executable_path/../../Frameworks"])
            if app:
                common.update(ASSETCATALOG_COMPILER_APPICON_NAME="AppIcon", ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS="NO")
            else:
                common.update(APPLICATION_EXTENSION_API_ONLY="YES", SKIP_INSTALL="YES")
        values = dict(buildSettings=common, name=mode)
        if target == "Project":
            values["baseConfigurationReference"] = file_refs["Configuration/Project.xcconfig"]
        configs.append(obj(f"config:{target}:{mode}", "XCBuildConfiguration", **values))
    return obj("configlist:" + target, "XCConfigurationList", buildConfigurations=configs, defaultConfigurationIsVisible="0", defaultConfigurationName="Debug")

keyboard_id = ident("target:Keyboard")
proxy = obj("proxy:Keyboard", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=keyboard_id, remoteInfo="AzkiKeyboard")
dependency = obj("dependency:Keyboard", "PBXTargetDependency", target=keyboard_id, targetProxy=proxy)
embed_file = obj("embed:Keyboard", "PBXBuildFile", fileRef=extension_product, settings={"ATTRIBUTES": ["RemoveHeadersOnCopy"]})
embed_phase = obj("phase:embed", "PBXCopyFilesBuildPhase", buildActionMask="2147483647", dstPath="", dstSubfolderSpec="13", files=[embed_file], name="Embed App Extensions", runOnlyForDeploymentPostprocessing="0")

targets = []
for target in ("App", "Keyboard"):
    source_files = []
    for path, ref in file_refs.items():
        if path.endswith(".swift") and path.startswith(("Sources/Core/", "Sources/SharedUI/", f"Sources/{target}/")):
            source_files.append(obj("build:" + target + ":" + path, "PBXBuildFile", fileRef=ref))
    resource_files = []
    for path in resources:
        if target == "Keyboard" and path.endswith(".xcassets"):
            continue
        resource_files.append(obj("build:" + target + ":" + path, "PBXBuildFile", fileRef=file_refs[path]))
    phases = [obj("phase:sources:" + target, "PBXSourcesBuildPhase", buildActionMask="2147483647", files=source_files, runOnlyForDeploymentPostprocessing="0"),
              obj("phase:frameworks:" + target, "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0"),
              obj("phase:resources:" + target, "PBXResourcesBuildPhase", buildActionMask="2147483647", files=resource_files, runOnlyForDeploymentPostprocessing="0")]
    if target == "App": phases.append(embed_phase)
    targets.append(obj("target:" + target, "PBXNativeTarget", buildConfigurationList=configs(target), buildPhases=phases, buildRules=[],
                       dependencies=[dependency] if target == "App" else [], name="AzkiInputMethod" if target == "App" else "AzkiKeyboard",
                       productName="AzkiInputMethod" if target == "App" else "AzkiKeyboard", productReference=app_product if target == "App" else extension_product,
                       productType="com.apple.product-type.application" if target == "App" else "com.apple.product-type.app-extension"))
test_product = obj("product:UITests", "PBXFileReference", explicitFileType="wrapper.cfbundle", path="AzkiNativeUITests.xctest", sourceTree="BUILT_PRODUCTS_DIR")
objects[products]["children"].append(test_product)
test_proxy = obj("proxy:App", "PBXContainerItemProxy", containerPortal=ident("project"), proxyType="1", remoteGlobalIDString=ident("target:App"), remoteInfo="AzkiInputMethod")
test_dependency = obj("dependency:App", "PBXTargetDependency", target=ident("target:App"), targetProxy=test_proxy)
test_sources = [obj("build:UITests:" + path, "PBXBuildFile", fileRef=ref) for path, ref in file_refs.items() if path.startswith("Tests/UI/")]
test_source_phase = obj("phase:sources:UITests", "PBXSourcesBuildPhase", buildActionMask="2147483647", files=test_sources, runOnlyForDeploymentPostprocessing="0")
test_framework_phase = obj("phase:frameworks:UITests", "PBXFrameworksBuildPhase", buildActionMask="2147483647", files=[], runOnlyForDeploymentPostprocessing="0")
targets.append(obj("target:UITests", "PBXNativeTarget", buildConfigurationList=configs("UITests"), buildPhases=[test_source_phase, test_framework_phase], buildRules=[], dependencies=[test_dependency], name="AzkiNativeUITests", productName="AzkiNativeUITests", productReference=test_product, productType="com.apple.product-type.bundle.ui-testing"))
project = obj("project", "PBXProject", attributes={"BuildIndependentTargetsInParallel": "YES", "LastUpgradeCheck": "2710", "TargetAttributes": {ident("target:UITests"): {"TestTargetID": ident("target:App")}}}, buildConfigurationList=configs("Project"), compatibilityVersion="Xcode 14.0", developmentRegion="zh_CN", hasScannedForEncodings="0", knownRegions=["zh_CN", "en", "ja", "Base"], mainGroup=main_group, productRefGroup=products, projectDirPath="", projectRoot="", targets=targets)
bundle = ROOT / "AzkiInputMethod.xcodeproj"
bundle.mkdir(exist_ok=True)
(bundle / "project.pbxproj").write_text("// !$*UTF8*$!\n" + quote({"archiveVersion": "1", "classes": {}, "objectVersion": "56", "objects": objects, "rootObject": project}) + "\n", encoding="utf-8")
schemes = bundle / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
(schemes / "AzkiInputMethod.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target:App')}" BuildableName="AzkiInputMethod.app" BlueprintName="AzkiInputMethod" ReferencedContainer="container:AzkiInputMethod.xcodeproj"/></BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target:UITests')}" BuildableName="AzkiNativeUITests.xctest" BlueprintName="AzkiNativeUITests" ReferencedContainer="container:AzkiInputMethod.xcodeproj"/></TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target:App')}" BuildableName="AzkiInputMethod.app" BlueprintName="AzkiInputMethod" ReferencedContainer="container:AzkiInputMethod.xcodeproj"/></BuildableProductRunnable></LaunchAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('target:App')}" BuildableName="AzkiInputMethod.app" BlueprintName="AzkiInputMethod" ReferencedContainer="container:AzkiInputMethod.xcodeproj"/></BuildableProductRunnable></ProfileAction>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n''', encoding="utf-8")
print(f"Generated {bundle} with {sum(1 for p in file_refs if p.endswith('.swift'))} original Swift source files.")
