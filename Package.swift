// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentNotch",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentNotch", targets: ["AgentNotch"])
    ],
    targets: [
        .executableTarget(
            name: "AgentNotch",
            path: "Sources/AgentNotch",
            // Anything dropped under Sources/AgentNotch/Resources is
            // bundled into the SPM-generated `AgentNotch_AgentNotch.bundle`
            // and loadable at runtime via `Bundle.module`. The build
            // script copies that bundle into `$APP_CONTENTS/Resources/` so
            // resources work in the packaged .app, not just `swift run`.
            resources: [.process("Resources")]
        )
    ]
)
