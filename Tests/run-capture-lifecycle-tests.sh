#!/bin/sh
# Exercise the exact neutral production source without the package's iOS-only UI.
# The normal MudmouthTests target runs these same tests on an iOS test destination.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
snapshot=$(mktemp -d "${TMPDIR:-/tmp}/mudmouth-capture-check.XXXXXX")
mkdir -p "$snapshot/Sources/Mudmouth" "$snapshot/Tests/MudmouthTests"
cp "$repo_root/Sources/Mudmouth/Classes/CaptureLifecycleEvent.swift" "$snapshot/Sources/Mudmouth/"
cp "$repo_root/Tests/MudmouthTests/CaptureLifecycleTests.swift" "$snapshot/Tests/MudmouthTests/"
cat > "$snapshot/Package.swift" <<'PACKAGE'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(
    name: "CaptureCheck",
    products: [.library(name: "Mudmouth", targets: ["Mudmouth"])],
    targets: [.target(name: "Mudmouth"), .testTarget(name: "MudmouthTests", dependencies: ["Mudmouth"])]
)
PACKAGE
(
    cd "$snapshot"
    swift --version
    shasum -a 256 Sources/Mudmouth/CaptureLifecycleEvent.swift Tests/MudmouthTests/CaptureLifecycleTests.swift Package.swift
) > "$snapshot/SourceManifest.txt"
printf 'Capture source snapshot and manifest: %s\n' "$snapshot"
swift test --package-path "$snapshot"
