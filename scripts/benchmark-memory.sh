#!/usr/bin/env bash
# Optimized code with DEBUG storage isolation: no real index, cache, preferences or Keychain access.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
memory_benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-memory-benchmark.XXXXXX")
trap 'rm -rf "$memory_benchmark_dir"' EXIT
xcrun swiftc -O -D DEBUG -D MEMORY_BENCHMARK -swift-version 6 -parse-as-library \
  -Xllvm -sil-disable-pass=optimize-hop-to-executor \
  -module-cache-path "$memory_benchmark_dir/modules" \
  Sources/Strata/AI/SemanticIndex.swift Sources/Strata/AI/TextExtractor.swift Sources/Strata/Model/SecureStorage.swift \
  Tests/StrataTests/Support/SemanticFixture.swift Tests/Benchmarks/MemoryBenchmark.swift \
  -o "$memory_benchmark_dir/benchmark"
for memory_benchmark_run in 1 2 3; do
  "$memory_benchmark_dir/benchmark" "$@"
done
