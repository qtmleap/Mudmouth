#!/bin/sh
# Runtime-test exact production handlers on macOS; omit the iOS-only UI and facade.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
snapshot=$(mktemp -d "${TMPDIR:-/tmp}/mudmouth-handler-check.XXXXXX")
cp "$repo_root/Package.swift" "$repo_root/Package.resolved" "$snapshot/"
cp -R "$repo_root/Sources" "$snapshot/"
mkdir -p "$snapshot/Tests"
cp -R "$repo_root/Tests/MudmouthTests" "$snapshot/Tests/"
python3 - "$snapshot/Package.swift" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1]);s=p.read_text().replace('platforms: [.iOS(.v17)]', 'platforms: [.macOS(.v14)]')
s=s.replace('''                .product(name: "Gzip", package: "GzipSwift"),
            ],''','''                .product(name: "Gzip", package: "GzipSwift"),
            ],
            exclude: ["Views", "Classes/Mudmouth.swift"],''')
p.write_text(s)
PY
(
    cd "$snapshot"
    swift --version
    find Sources Tests -type f -print0 | sort -z | xargs -0 shasum -a 256
    shasum -a 256 Package.swift Package.resolved
) > "$snapshot/SourceManifest.txt"
printf 'Handler source snapshot and manifest: %s\n' "$snapshot"
test_status=0
CI=true swift test --package-path "$snapshot" --jobs 4 || test_status=$?
# CI removes unused developer-tool dependencies from the lock. Retain its actual
# resolved bytes after testing as well as the original source manifest.
shasum -a 256 "$snapshot/Package.resolved" > "$snapshot/ResolvedManifest.txt"
exit "$test_status"
