#!/usr/bin/env bash
# Optimized code with DEBUG storage isolation: no real index, cache, preferences or Keychain access.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
memory_benchmark_dir=$(mktemp -d "${TMPDIR:-/tmp}/strata-memory-benchmark.XXXXXX")
trap 'rm -rf "$memory_benchmark_dir"' EXIT
git show 8cad325:Sources/Strata/Index/IndexPersistence.swift \
  | sed 's/enum IndexPersistence {/enum IndexPersistenceBaseline {/' > "$memory_benchmark_dir/IndexPersistenceBaseline.swift"
memory_benchmark_secure_source=Sources/Strata/Model/SecureStorage.swift
if [[ "${1:-}" == index-growth* ]]; then
  # A public, synthetic-only key lets separate fixture-builder and reader processes share the encrypted fixture.
  # This changes only a temporary compiler input; the app's source and its Keychain behavior are untouched.
  python3 - "$memory_benchmark_dir/SecureStorage.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Sources/Strata/Model/SecureStorage.swift').read_text()
old = 'isTestRun ? SymmetricKey(size: .bits256) : loadOrCreateKey()'
assert source.count(old) == 1
Path(sys.argv[1]).write_text(source.replace(old, 'isTestRun ? SymmetricKey(data: Data(repeating: 0x5a, count: 32)) : loadOrCreateKey()'))
PY
  memory_benchmark_secure_source="$memory_benchmark_dir/SecureStorage.swift"
fi
xcrun swiftc -O -D DEBUG -D MEMORY_BENCHMARK -swift-version 6 -parse-as-library \
  -default-isolation MainActor -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -Xllvm -sil-disable-pass=optimize-hop-to-executor \
  -module-cache-path "$memory_benchmark_dir/modules" \
  Sources/Strata/AI/SemanticIndex.swift Sources/Strata/AI/TextExtractor.swift "$memory_benchmark_secure_source" \
  Sources/Strata/Views/ThumbnailCache.swift \
  Sources/Strata/Index/IndexStore.swift Sources/Strata/Index/IndexPersistence.swift "$memory_benchmark_dir/IndexPersistenceBaseline.swift" \
  Tests/StrataTests/Support/SemanticFixture.swift Tests/Benchmarks/ThumbnailCacheBaseline.swift Tests/Benchmarks/MemoryBenchmark.swift \
  -o "$memory_benchmark_dir/benchmark"
if [[ "${1:-}" == index-growth* ]]; then
  "$memory_benchmark_dir/benchmark" index-fixture "${2:-1000000}" "$memory_benchmark_dir/index.sealed"
fi
for memory_benchmark_run in 1 2 3; do
  if [[ "${1:-}" == "index-growth-comparison" ]]; then
    "$memory_benchmark_dir/benchmark" index-growth-baseline "${2:-1000000}" "$memory_benchmark_dir/index.sealed"
    "$memory_benchmark_dir/benchmark" index-growth "${2:-1000000}" "$memory_benchmark_dir/index.sealed"
  elif [[ "${1:-}" == index-growth* ]]; then
    "$memory_benchmark_dir/benchmark" "$1" "${2:-1000000}" "$memory_benchmark_dir/index.sealed"
  else
    "$memory_benchmark_dir/benchmark" "$@"
  fi
done
