//
//  Project.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import ProjectDescription

let deploymentTarget = "13.0"

let project = Project(
    name: "ScreenLock",
    organizationName: "fgasperini",
    options: .options(
        defaultKnownRegions: ["en", "it"],
        developmentRegion: "en"
    ),
    settings: .settings(
        base: [
            "SWIFT_VERSION": "5.0",
            "ENABLE_HARDENED_RUNTIME": "NO",
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGN_IDENTITY": "-",
            "DEVELOPMENT_TEAM": "",
        ]
    ),
    targets: [
        .target(
            name: "ScreenLock",
            destinations: .macOS,
            product: .app,
            bundleId: "com.fgasperini.screenlock",
            deploymentTargets: .macOS(deploymentTarget),
            infoPlist: .dictionary([
                "CFBundleDevelopmentRegion": "$(DEVELOPMENT_LANGUAGE)",
                "CFBundleExecutable": "$(EXECUTABLE_NAME)",
                "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
                "CFBundleInfoDictionaryVersion": "6.0",
                "CFBundlePackageType": "APPL",
                "CFBundleDisplayName": "ScreenLock",
                "CFBundleName": "ScreenLock",
                "CFBundleShortVersionString": "1.0",
                "CFBundleVersion": "1",
                "LSApplicationCategoryType": "public.app-category.utilities",
                "LSUIElement": true,
                "LSMinimumSystemVersion": .string(deploymentTarget),
                "NSHumanReadableCopyright": "",
            ]),
            sources: ["Sources/ScreenLock/**/*.swift"],
            resources: [
                "Sources/ScreenLock/Assets.xcassets",
                "Sources/ScreenLock/Localizable.xcstrings",
            ],
            settings: .settings(
                base: [
                    "PRODUCT_NAME": "ScreenLock",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
                ]
            )
        ),
    ]
)
