#!/usr/bin/env python3
"""Generates Miroo.xcodeproj: the iOS app target (sources in PhoneApp/) backed by the root Swift package."""
import os
PROJ = "Miroo.xcodeproj"
os.makedirs(PROJ + "/project.xcworkspace", exist_ok=True)
os.makedirs(PROJ + "/xcshareddata/xcschemes", exist_ok=True)

def i(n): return "4F%022X" % n
PROJECT, TARGET, APPREF, MAINGRP, PRODGRP, SRCGRP, EXC = i(1), i(2), i(3), i(4), i(5), i(6), i(7)
SRCPH, FWPH, RESPH, CFGLIST_P, CFGLIST_T = i(8), i(9), i(10), i(11), i(12)
DBG_P, REL_P, DBG_T, REL_T, LOCALPKG = i(13), i(14), i(15), i(16), i(17)
PRODUCTS = ["MirooCore", "MirooMedia", "MirooNet", "MirooSession"]
PRODDEP = {p: i(20 + k) for k, p in enumerate(PRODUCTS)}
BUILDFILE = {p: i(30 + k) for k, p in enumerate(PRODUCTS)}

common = """ALWAYS_SEARCH_USER_PATHS = NO; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES;
DEVELOPMENT_TEAM = 6NNWP5NQ7Z; ENABLE_USER_SCRIPT_SANDBOXING = YES; GCC_C_LANGUAGE_STANDARD = gnu17;
IPHONEOS_DEPLOYMENT_TARGET = 16.0; LOCALIZATION_PREFERS_STRING_CATALOGS = YES; SDKROOT = iphoneos;"""
pbx = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 77;
	objects = {{

/* Begin PBXBuildFile section */
""" + "".join(f"\t\t{BUILDFILE[p]} /* {p} in Frameworks */ = {{isa = PBXBuildFile; productRef = {PRODDEP[p]} /* {p} */; }};\n" for p in PRODUCTS) + f"""/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{APPREF} /* Miroo.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Miroo.app; sourceTree = BUILT_PRODUCTS_DIR; }};
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedBuildFileExceptionSet section */
		{EXC} /* Exceptions for "PhoneApp" folder in "Miroo" target */ = {{
			isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
			membershipExceptions = (
				Info.plist,
			);
			target = {TARGET} /* Miroo */;
		}};
/* End PBXFileSystemSynchronizedBuildFileExceptionSet section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		{SRCGRP} /* PhoneApp */ = {{
			isa = PBXFileSystemSynchronizedRootGroup;
			exceptions = (
				{EXC},
			);
			path = PhoneApp;
			sourceTree = "<group>";
		}};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		{FWPH} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
""" + "".join(f"\t\t\t\t{BUILDFILE[p]} /* {p} in Frameworks */,\n" for p in PRODUCTS) + f"""			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{MAINGRP} = {{
			isa = PBXGroup;
			children = (
				{SRCGRP} /* PhoneApp */,
				{PRODGRP} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{PRODGRP} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{APPREF} /* Miroo.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{TARGET} /* Miroo */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {CFGLIST_T} /* Build configuration list for PBXNativeTarget "Miroo" */;
			buildPhases = (
				{SRCPH} /* Sources */,
				{FWPH} /* Frameworks */,
				{RESPH} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				{SRCGRP} /* PhoneApp */,
			);
			name = Miroo;
			packageProductDependencies = (
""" + "".join(f"\t\t\t\t{PRODDEP[p]} /* {p} */,\n" for p in PRODUCTS) + f"""			);
			productName = Miroo;
			productReference = {APPREF} /* Miroo.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{PROJECT} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2620;
				LastUpgradeCheck = 2620;
				TargetAttributes = {{
					{TARGET} = {{
						CreatedOnToolsVersion = 26.2;
					}};
				}};
			}};
			buildConfigurationList = {CFGLIST_P} /* Build configuration list for PBXProject "Miroo" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {MAINGRP};
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				{LOCALPKG} /* XCLocalSwiftPackageReference "Miroo" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = {PRODGRP} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{TARGET} /* Miroo */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{RESPH} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{SRCPH} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{DBG_P} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				{common} DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES; GCC_OPTIMIZATION_LEVEL = 0;
				ONLY_ACTIVE_ARCH = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			}};
			name = Debug;
		}};
		{REL_P} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				{common} DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; ENABLE_NS_ASSERTIONS = NO; SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O"; VALIDATE_PRODUCT = YES;
			}};
			name = Release;
		}};
		{DBG_T} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; DEVELOPMENT_TEAM = 6NNWP5NQ7Z;
				GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = PhoneApp/Info.plist; MARKETING_VERSION = 2.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.nurulhasan.MirooPhone; PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
			}};
			name = Debug;
		}};
		{REL_T} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_STYLE = Automatic; CURRENT_PROJECT_VERSION = 1; DEVELOPMENT_TEAM = 6NNWP5NQ7Z;
				GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = PhoneApp/Info.plist; MARKETING_VERSION = 2.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.nurulhasan.MirooPhone; PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0; TARGETED_DEVICE_FAMILY = 1; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon; ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{CFGLIST_P} /* Build configuration list for PBXProject "Miroo" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{DBG_P} /* Debug */,
				{REL_P} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{CFGLIST_T} /* Build configuration list for PBXNativeTarget "Miroo" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{DBG_T} /* Debug */,
				{REL_T} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{LOCALPKG} /* XCLocalSwiftPackageReference "Miroo" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = .;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
""" + "".join(f"\t\t{PRODDEP[p]} /* {p} */ = {{\n\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = {p};\n\t\t}};\n" for p in PRODUCTS) + f"""/* End XCSwiftPackageProductDependency section */
	}};
	rootObject = {PROJECT} /* Project object */;
}}
"""
open(PROJ + "/project.pbxproj", "w").write(pbx)
open(PROJ + "/project.xcworkspace/contents.xcworkspacedata", "w").write('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version = "1.0">\n   <FileRef location = "self:">\n   </FileRef>\n</Workspace>\n')
open(PROJ + "/xcshareddata/xcschemes/Miroo.xcscheme", "w").write(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2620" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET}" BuildableName = "Miroo.app" BlueprintName = "Miroo" ReferencedContainer = "container:Miroo.xcodeproj"></BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES"><Testables></Testables></TestAction>
   <LaunchAction buildConfiguration = "Release" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{TARGET}" BuildableName = "Miroo.app" BlueprintName = "Miroo" ReferencedContainer = "container:Miroo.xcodeproj"></BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES"></ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
''')
print("generated", PROJ)
