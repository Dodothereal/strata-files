#!/usr/bin/env bash
# Optimized persistence measurements on a synthetic index. Never opens Strata's own index or keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-index-benchmark.XXXXXX")
trap 'rm -rf "$benchmark_dir"' EXIT
xcrun swiftc -O -D DEBUG -swift-version 6 -parse-as-library -module-cache-path "$benchmark_dir/modules" \
  Sources/Strata/Index/IndexStore.swift Sources/Strata/Index/IndexPersistence.swift \
  Sources/Strata/Index/IndexChanges.swift Sources/Strata/Model/SecureStorage.swift \
  Tests/Benchmarks/IndexPersistenceBenchmark.swift -o "$benchmark_dir/benchmark"
"$benchmark_dir/benchmark" "$@"
