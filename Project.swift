import Foundation
import ProjectDescription

let version: String = {
    if let contents = try? String(contentsOfFile: "version.txt", encoding: .utf8) {
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "0.0.0"
}()

/// Read from DEVELOPMENT_TEAM env var. Xcode Automatic signing picks a team
/// from your Apple ID if this is empty, so local dev works without configuration.
/// CI passes the team ID via secrets.
let teamID: SettingValue = "\(ProcessInfo.processInfo.environment["DEVELOPMENT_TEAM"] ?? "96452FLT2P")"

let project = Project(
    name: "Clusage",
    settings: .settings(
        base: [
            "SWIFT_VERSION": "6.2",
            "DEVELOPMENT_TEAM": teamID,
            "CODE_SIGN_STYLE": "Automatic",
            "CODE_SIGN_IDENTITY": "Apple Development",
            "ENABLE_HARDENED_RUNTIME": "YES",
        ]
    ),
    targets: [
        .target(
            name: "Clusage",
            destinations: .macOS,
            product: .app,
            bundleId: "studio.seventwo.clusage",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "LSUIElement": true,
                "CFBundleShortVersionString": "\(version)",
                "CFBundleVersion": "\(version)",
            ]),
            sources: ["Sources/**", "Shared/**"],
            resources: ["Resources/**"],
            entitlements: .file(path: "Clusage.entitlements"),
            dependencies: [
                .target(name: "ClusageWidgets"),
            ],
            settings: .settings(base: [
                "MARKETING_VERSION": "\(version)",
                "CURRENT_PROJECT_VERSION": "\(version)",
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
        .target(
            name: "ClusageWidgets",
            destinations: .macOS,
            product: .extensionKitExtension,
            bundleId: "studio.seventwo.clusage.widgets",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "EXAppExtensionAttributes": [
                    "EXExtensionPointIdentifier": "com.apple.widgetkit-extension",
                ],
            ]),
            sources: ["Widgets/**", "Shared/**"],
            entitlements: .file(path: "ClusageWidgets.entitlements"),
            dependencies: [],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
        .target(
            name: "ClusageTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "studio.seventwo.clusage.tests",
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "Clusage"),
            ],
            settings: .settings(base: [
                "CODE_SIGN_IDENTITY": "Apple Development",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
    ]
)
