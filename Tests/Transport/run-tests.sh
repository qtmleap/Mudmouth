#!/bin/bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORK=${TRANSPORT_TEST_WORK:-"$ROOT/build/transport-harness"}
mkdir -p "$WORK/Sources/Mudmouth" "$WORK/Tests/TransportTests" "$WORK/fixtures"
cp "$ROOT/Sources/Mudmouth/AutomationHTTPTransport.swift" "$WORK/Sources/Mudmouth/"
cp "$ROOT/Tests/Transport/AutomationHTTPTransportTests.swift" "$WORK/Tests/TransportTests/"
cat > "$WORK/Package.swift" <<'EOF'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "TransportHarness", platforms: [.macOS(.v14), .iOS(.v17)], products: [.library(name: "Mudmouth", targets: ["Mudmouth"])], dependencies: [.package(url: "https://github.com/apple/swift-nio.git", exact: "2.86.0"), .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.33.0")], targets: [.target(name: "Mudmouth", dependencies: [.product(name:"NIOCore",package:"swift-nio"), .product(name:"NIOPosix",package:"swift-nio"), .product(name:"NIOHTTP1",package:"swift-nio"), .product(name:"NIOSSL",package:"swift-nio-ssl")]), .testTarget(name:"TransportTests",dependencies:["Mudmouth", .product(name:"NIOCore",package:"swift-nio"), .product(name:"NIOPosix",package:"swift-nio"), .product(name:"NIOHTTP1",package:"swift-nio"), .product(name:"NIOSSL",package:"swift-nio-ssl")])])
EOF
if [ ! -f "$WORK/fixtures/server.pem" ] || ! openssl x509 -checkend 3600 -noout -in "$WORK/fixtures/server.pem" >/dev/null 2>&1; then
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/fixtures/ca.key" -out "$WORK/fixtures/ca.pem" -days 2 -subj '/CN=Transport Test CA' >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -keyout "$WORK/fixtures/server.key" -out "$WORK/fixtures/server.csr" -subj '/CN=localhost' >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\n' > "$WORK/fixtures/server.ext"
  openssl x509 -req -in "$WORK/fixtures/server.csr" -CA "$WORK/fixtures/ca.pem" -CAkey "$WORK/fixtures/ca.key" -CAcreateserial -out "$WORK/fixtures/server.pem" -days 2 -extfile "$WORK/fixtures/server.ext" >/dev/null 2>&1
fi
export TRANSPORT_FIXTURES="$WORK/fixtures"
shasum -a 256 "$WORK/Sources/Mudmouth/AutomationHTTPTransport.swift" "$WORK/Tests/TransportTests/AutomationHTTPTransportTests.swift" "$WORK/Package.swift" > "$WORK/source-manifest.sha256"
swift test --package-path "$WORK" --jobs 4 "$@" 2>&1 | tee "$WORK/test.log"
