// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Clanker",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Clanker", targets: ["Clanker"])
    ],
    targets: [
        .executableTarget(
            name: "Clanker",
            path: "Sources/Clanker",
            exclude: [
                "Services/Harnesses/AGENTS.md",
                "Services/Harnesses/CLAUDE.md"
            ],
            // Anything dropped under Sources/Clanker/Resources is
            // bundled into the SPM-generated `Clanker_Clanker.bundle`
            // and loadable at runtime via `Bundle.module`. The build
            // script copies that bundle into `$APP_CONTENTS/Resources/` so
            // resources work in the packaged .app, not just `swift run`.
            resources: [.process("Resources")]
        )
    ]
)
