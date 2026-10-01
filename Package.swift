// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppGateKit",
    // iOS is the supported platform. The macOS floor is not a support claim,
    // and it must stay. `swift build` and `swift test` run on a Mac host, so
    // this package's tests run there. Without the line, SwiftPM uses its
    // default macOS deployment target, which is too old for the APIs used
    // here and produces hundreds of availability errors.
    // The README's Platforms section states what is supported.
    //
    // watchOS, tvOS and visionOS are not declared. A watch app is paired to
    // its phone app, so gating the phone app gates both. Nothing here builds
    // or tests the other two, so declaring them would claim support that does
    // not exist.
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        // The pure logic: the comparator, the states, the precedence rule, the
        // OS-install check and the suppression rules. It imports Foundation
        // only, so its tests run on a Mac host with no simulator. A host whose
        // own server already decides the floor can use it alone.
        .library(name: "AppGateCore", targets: ["AppGateCore"]),
        // The store that fetches, caches and publishes the decision. A
        // separate product, so Core stays usable without it.
        .library(name: "AppGateClient", targets: ["AppGateClient"]),
        // The presentation code. A separate product, so an app that writes
        // its own presentation links the gate without linking SwiftUI. It
        // provides the ordering rules, and no wall, sheet or text.
        .library(name: "AppGateUI", targets: ["AppGateUI"]),
    ],
    targets: [
        // The privacy manifest ships in the target and is not left to the
        // host, because an app's manifest cannot report a package's API use on
        // the package's behalf.
        //
        // `.copy` and not `.process`, so the file keeps its exact name.
        // Apple's tooling looks for `PrivacyInfo.xcprivacy`.
        .target(
            name: "AppGateCore",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Ships its own manifest and does not rely on Core's. A manifest
        // covers the target it ships in, and this target is the one that uses
        // `UserDefaults`.
        .target(
            name: "AppGateClient",
            dependencies: ["AppGateCore"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Ships its own manifest for the same reason. The manifest is empty,
        // because this module has no storage, no clock and no network of its
        // own.
        .target(
            name: "AppGateUI",
            dependencies: ["AppGateClient"],
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "AppGateCoreTests", dependencies: ["AppGateCore"]),
        .testTarget(name: "AppGateClientTests", dependencies: ["AppGateClient", "AppGateCore"]),
        .testTarget(name: "AppGateUITests", dependencies: ["AppGateUI", "AppGateCore"]),
    ]
)
