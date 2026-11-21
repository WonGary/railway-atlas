import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

// Deterministic Xcode project generation, without XcodeGen or third-party gems.
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const releaseVersion = fs.readFileSync(path.join(root, "VERSION"), "utf8").trim();
const buildNumber = fs.readFileSync(path.join(root, "Config/Info.plist"), "utf8")
  .match(/<key>CFBundleVersion<\/key>\s*<string>(\d+)<\/string>/)?.[1];
if (!/^\d+\.\d+\.\d+$/.test(releaseVersion) || !buildNumber) throw new Error("Invalid release version or build number");
const id = (name) => crypto.createHash("sha256").update(name).digest("hex").slice(0, 24).toUpperCase();
const quote = JSON.stringify;
const objects = [];
const object = (name, content) => { objects.push(`${id(name)} = { ${content} };`); return id(name); };
const list = (values) => `(${values.join(", ")})`;
const sourceRoot = path.join(root, "Sources/RailwayAtlas");
function swiftFiles(directory) {
  return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? swiftFiles(file) : entry.name.endsWith(".swift") ? [file] : [];
  }).sort();
}
const files = swiftFiles(sourceRoot).map((file) => {
  const relative = path.relative(root, file);
  return object(relative, `isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ${quote(relative)}; sourceTree = SOURCE_ROOT;`);
});
const resources = object("resources", 'isa = PBXFileReference; lastKnownFileType = folder; path = Sources/RailwayAtlas/Resources; sourceTree = SOURCE_ROOT;');
// On iOS an app is a flat bundle. A top-level "Resources" directory makes
// Apple's bundle reader look there for Info.plist and misidentify the binary.
const iosResources = fs.readdirSync(path.join(sourceRoot, "Resources"), {withFileTypes: true})
  .filter(entry => entry.isFile() && !entry.name.startsWith("."))
  .map(entry => `Sources/RailwayAtlas/Resources/${entry.name}`).sort()
  .concat("Config/PrivacyInfo.xcprivacy")
  .map(relative => object(relative, `isa = PBXFileReference; lastKnownFileType = file; path = ${quote(relative)}; sourceTree = SOURCE_ROOT;`));
const catalog = object("catalog", 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Design/Assets.xcassets; sourceTree = SOURCE_ROOT;');
object("package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";');
const targets = [];
const products = [];
for (const platform of ["macOS", "iOS"]) {
  const prefix = `RailwayAtlas-${platform}`;
  const sourceBuilds = files.map((file, n) => object(`${prefix}-source-${n}`, `isa = PBXBuildFile; fileRef = ${file};`));
  const resourceBuilds = (platform === "iOS" ? [...iosResources, catalog] : [resources, catalog]).map((file, n) => object(`${prefix}-resource-${n}`, `isa = PBXBuildFile; fileRef = ${file};`));
  const dependency = object(`${prefix}-core`, `isa = XCSwiftPackageProductDependency; package = ${id("package")}; productName = RailwayCore;`);
  const link = object(`${prefix}-link`, `isa = PBXBuildFile; productRef = ${dependency};`);
  const sourcesPhase = object(`${prefix}-sources`, `isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ${list(sourceBuilds)}; runOnlyForDeploymentPostprocessing = 0;`);
  const resourcesPhase = object(`${prefix}-resources`, `isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ${list(resourceBuilds)}; runOnlyForDeploymentPostprocessing = 0;`);
  const frameworksPhase = object(`${prefix}-frameworks`, `isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (${link}); runOnlyForDeploymentPostprocessing = 0;`);
  const product = object(`${prefix}-product`, `isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ${quote(`${prefix}.app`)}; sourceTree = BUILT_PRODUCTS_DIR;`);
  products.push(product);
  const configs = [];
  for (const configuration of ["Debug", "Release"]) {
    const settings = {
      PRODUCT_NAME: prefix,
      PRODUCT_BUNDLE_IDENTIFIER: `app.railwayatlas.${platform === "macOS" ? "mac" : "ios"}`,
      SWIFT_VERSION: "6.0",
      SWIFT_STRICT_CONCURRENCY: "complete",
      GENERATE_INFOPLIST_FILE: "YES",
      INFOPLIST_FILE: "Config/XcodeInfo.plist",
      INFOPLIST_KEY_CFBundleDisplayName: "铁道图鉴",
      MARKETING_VERSION: releaseVersion,
      CURRENT_PROJECT_VERSION: buildNumber,
      ASSETCATALOG_COMPILER_APPICON_NAME: "AppIcon",
      CODE_SIGN_STYLE: "Automatic",
      MACOSX_DEPLOYMENT_TARGET: "14.0",
      IPHONEOS_DEPLOYMENT_TARGET: "17.0",
      SDKROOT: platform === "macOS" ? "macosx" : "iphoneos",
      SUPPORTED_PLATFORMS: platform === "macOS" ? "macosx" : "iphoneos iphonesimulator",
      SWIFT_OPTIMIZATION_LEVEL: configuration === "Debug" ? "-Onone" : "-O",
      ENABLE_USER_SCRIPT_SANDBOXING: "YES",
      INFOPLIST_KEY_LSApplicationCategoryType: "public.app-category.travel"
    };
    if (platform === "iOS") {
      settings.INFOPLIST_KEY_UISupportedInterfaceOrientations_iPad = "UIInterfaceOrientationPortrait UIInterfaceOrientationPortraitUpsideDown UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight";
      settings.INFOPLIST_KEY_CFBundleDisplayName = "铁道漫游";
      settings.TARGETED_DEVICE_FAMILY = "1,2";
      settings.INFOPLIST_KEY_UILaunchScreen_Generation = "YES";
      settings.INFOPLIST_KEY_UIApplicationSceneManifest_Generation = "YES";
      settings.SUPPORTS_MACCATALYST = "NO";
    } else {
      settings.ENABLE_APP_SANDBOX = "YES";
      settings.ENABLE_HARDENED_RUNTIME = "YES";
      settings.ENABLE_OUTGOING_NETWORK_CONNECTIONS = "YES";
      settings.ENABLE_USER_SELECTED_FILES = "readwrite";
    }
    configs.push(object(`${prefix}-${configuration}`, `isa = XCBuildConfiguration; name = ${configuration}; buildSettings = { ${Object.entries(settings).map(([key, value]) => `${key} = ${quote(value)};`).join(" ")} };`));
  }
  const configList = object(`${prefix}-configurations`, `isa = XCConfigurationList; buildConfigurations = ${list(configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;`);
  const target = object(prefix, `isa = PBXNativeTarget; name = ${quote(prefix)}; productName = ${quote(prefix)}; productType = "com.apple.product-type.application"; productReference = ${product}; buildConfigurationList = ${configList}; buildPhases = (${sourcesPhase}, ${frameworksPhase}, ${resourcesPhase}); buildRules = (); dependencies = (); packageProductDependencies = (${dependency});`);
  targets.push(target);
}
const productGroup = object("products", `isa = PBXGroup; name = Products; children = ${list(products)}; sourceTree = "<group>";`);
const mainGroup = object("main-group", `isa = PBXGroup; children = ${list([...files, resources, ...iosResources, catalog, productGroup])}; sourceTree = "<group>";`);
const projectConfigs = ["Debug", "Release"].map((name) => object(`project-${name}`, `isa = XCBuildConfiguration; name = ${name}; buildSettings = { CLANG_ENABLE_MODULES = YES; };`));
const projectConfigList = object("project-configs", `isa = XCConfigurationList; buildConfigurations = ${list(projectConfigs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;`);
object("project", `isa = PBXProject; attributes = { LastUpgradeCheck = 1600; }; buildConfigurationList = ${projectConfigList}; compatibilityVersion = "Xcode 14.0"; developmentRegion = zh_CN; knownRegions = (en, zh_CN, Base); mainGroup = ${mainGroup}; productRefGroup = ${productGroup}; projectDirPath = ""; projectRoot = ""; targets = ${list(targets)}; packageReferences = (${id("package")});`);
const projectDirectory = path.join(root, "RailwayAtlas.xcodeproj");
fs.mkdirSync(projectDirectory, { recursive: true });
fs.writeFileSync(path.join(projectDirectory, "project.pbxproj"),
  `// !$*UTF8*$!\n{\narchiveVersion = 1;\nclasses = {};\nobjectVersion = 56;\nobjects = {\n${objects.join("\n")}\n};\nrootObject = ${id("project")};\n}\n`);
const schemes = path.join(projectDirectory, "xcshareddata/xcschemes");
fs.mkdirSync(schemes, { recursive: true });
for (const platform of ["macOS", "iOS"]) {
  const name = `RailwayAtlas-${platform}`;
  const reference = `<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id(name)}" BuildableName="${name}.app" BlueprintName="${name}" ReferencedContainer="container:RailwayAtlas.xcodeproj"/>`;
  fs.writeFileSync(path.join(schemes, `${name}.xcscheme`),
    `<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">${reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">${reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">${reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n`);
}
const assets = path.join(root, "Design/Assets.xcassets");
fs.mkdirSync(assets, { recursive: true });
fs.writeFileSync(path.join(assets, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2));
fs.cpSync(path.join(root, "Design/AppIcon.appiconset"), path.join(assets, "AppIcon.appiconset"), { recursive: true });
// Modern Xcode supports a single opaque 1024px iOS source; retain all macOS slots.
const original = JSON.parse(fs.readFileSync(path.join(root, "Design/AppIcon.appiconset/Contents.json"), "utf8"));
const manifest = { images: [
  ...original.images.filter((image) => image.idiom === "mac"),
  { filename: "Icon-1024.png", idiom: "universal", platform: "ios", size: "1024x1024" }
], info: { author: "xcode", version: 1 } };
fs.writeFileSync(path.join(assets, "AppIcon.appiconset/Contents.json"), JSON.stringify(manifest, null, 2));
console.log("Generated Xcode project with macOS and iOS app targets.");
