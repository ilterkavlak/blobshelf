// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Blobshelf",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Blobshelf", targets: ["Blobshelf"])],
    targets: [
        .target(name: "BlobshelfCore"),
        .executableTarget(name: "Blobshelf", dependencies: ["BlobshelfCore"]),
        .testTarget(
            name: "BlobshelfCoreTests",
            dependencies: ["BlobshelfCore"],
            // The Command Line Tools ship Swift Testing's Foundation overlay without its module;
            // the tests do not use it, and skipping it lets them build without Xcode.
            swiftSettings: [.unsafeFlags(["-Xfrontend", "-disable-cross-import-overlays"])]
        ),
    ]
)
