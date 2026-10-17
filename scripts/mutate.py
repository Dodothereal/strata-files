#!/usr/bin/env python3
"""Proves the destructive-action tests guard their rules: each mutation in Tests/mutations.json breaks one rule in the
code, and the tests named for it must then fail. Every mutation is applied alone, its tests run, and the file restored
from git before the next.

    python3 scripts/mutate.py                 # every mutation (an hour or so: one build each)
    python3 scripts/mutate.py Trash Undo      # only mutations whose rule mentions these words
    python3 scripts/mutate.py --list          # the rules, without running anything

Exit 1 when a mutation isn't caught (its tests still pass), its text isn't found in the file (the code moved: update
`find`), or a restore fails. The working tree must be clean for the files mutated; the script refuses otherwise.
The unmodified tests must pass first. Each run has a five-minute limit; a timeout never counts as caught.
CI sets STRATA_MUTATION_RULES to optional space-separated words and STRATA_MUTATION_SHARD to a part such as 1/4.
Each shard needs its own checkout; never run them together in one working tree.

A mutation names: `file` (under Sources/), `find` (text that occurs exactly once), `replace`, `rule` (what it breaks, in
the user's words) and `tests` (a `swift test --filter` pattern). A rule with layered defenses (a check, and a second
behind it) gives `edits`, a list of `{find, replace}` pairs applied together, instead of one `find`/`replace`. Add one
with every new destructive-action test.
"""
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
TEST_TIMEOUT = 300


def sh(args, timeout=None):
    env = dict(os.environ)
    if os.path.isdir(DEVELOPER_DIR) and "DEVELOPER_DIR" not in env:
        env["DEVELOPER_DIR"] = DEVELOPER_DIR
    process = subprocess.Popen(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # SwiftPM's test helper (and any tools it started) must stop before the source is restored.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(args, process.returncode, stdout, stderr)


def tests_fail(pattern, report=False):
    """True for a test failure, False for a pass; None for a build failure, timeout, crash or no tests."""
    try:
        run = sh(["swift", "test", "--filter", pattern], timeout=TEST_TIMEOUT)
    except subprocess.TimeoutExpired:
        print(f"Test run exceeded {TEST_TIMEOUT}s; stopped its processes (this does not count as caught).")
        return None
    out = run.stdout + run.stderr
    if re.search(r"Test run with 0 tests", out):
        print("The filter matched no tests.")
        return None
    if re.search(r"error: .*(Compile|Build failed|fatalError)", out) and "Test run" not in out:
        print("\n".join(out.splitlines()[-30:]))
        return None
    if re.search(r"✘ Test run with \d+ tests? in \d+ suites? failed", out):
        if report:
            print("\n".join(line for line in out.splitlines() if "✘" in line or "↳" in line))
        return True
    if re.search(r"✔ Test run with \d+ tests? in \d+ suites? passed", out):
        return False
    print("\n".join(out.splitlines()[-30:]))
    return None


def main():
    # Progress shows as it happens, in a log file or CI as well as a terminal.
    sys.stdout.reconfigure(line_buffering=True)
    mutations = json.loads(Path(ROOT, "Tests", "mutations.json").read_text())
    words = [a for a in sys.argv[1:] if not a.startswith("--")] or os.environ.get("STRATA_MUTATION_RULES", "").split()
    if words:
        mutations = [m for m in mutations if any(w.lower() in m["rule"].lower() for w in words)]
    selected = len(mutations)
    shard = os.environ.get("STRATA_MUTATION_SHARD", "")
    if shard:
        try:
            part, total = map(int, shard.split("/"))
            if not 1 <= part <= total:
                raise ValueError()
        except ValueError:
            sys.exit("STRATA_MUTATION_SHARD must name a part such as 1/4 (parts start at 1).")
        mutations = mutations[part - 1::total]
    if "--list" in sys.argv:
        for m in mutations:
            print(f"{m['file']}: {m['rule']}  →  {m['tests']}")
        return
    if not mutations:
        if shard and selected:
            print(f"No mutations assigned to shard {shard}.")
            return
        print("No mutations match these rules.")
        sys.exit(1)
    files = sorted({m["file"] for m in mutations})
    dirty = sh(["git", "status", "--porcelain", "--"] + [f"Sources/{f}" for f in files]).stdout.strip()
    if dirty:
        print("These files have uncommitted changes; commit or stash them first:\n" + dirty)
        sys.exit(1)
    print("Checking the tests pass before applying mutations…")
    if tests_fail("|".join(sorted({m["tests"] for m in mutations})), report=True) is not False:
        print("The unmodified tests must pass before mutations can prove their rules.")
        sys.exit(1)
    failures = []
    for n, m in enumerate(mutations, 1):
        start = time.monotonic()
        print(f"[{n}/{len(mutations)}] running: {m['rule']}")
        path = os.path.join(ROOT, "Sources", m["file"])
        source = Path(path).read_text()
        edits = m.get("edits") or [{"find": m["find"], "replace": m["replace"]}]
        counts = [source.count(e["find"]) for e in edits]
        if any(c != 1 for c in counts):
            print(f"[{n}/{len(mutations)}] NOT FOUND ({'/'.join(map(str, counts))}×): {m['file']}: {m['rule']}")
            failures.append(m)
            continue
        mutated = source
        for e in edits:
            mutated = mutated.replace(e["find"], e["replace"])
        try:
            Path(path).write_text(mutated)
            os.utime(path)
            caught = tests_fail(m["tests"])
        finally:
            restore = sh(["git", "checkout", "--", f"Sources/{m['file']}"])
            if restore.returncode != 0 or Path(path).read_text() != source:
                print(f"RESTORE FAILED for {m['file']}; put it back by hand (git checkout -- Sources/{m['file']})")
                sys.exit(2)
        if caught is True:
            print(f"[{n}/{len(mutations)}] caught ({time.monotonic() - start:.1f}s): {m['rule']}")
        elif caught is None:
            print(f"[{n}/{len(mutations)}] DIDN'T BUILD or ran no tests: {m['rule']} ({m['tests']})")
            failures.append(m)
        else:
            print(f"[{n}/{len(mutations)}] NOT CAUGHT: {m['rule']} ({m['tests']})")
            failures.append(m)
    print()
    if failures:
        print(f"{len(failures)} of {len(mutations)} mutations not caught:")
        for m in failures:
            print(f"  {m['file']}: {m['rule']}")
        sys.exit(1)
    print(f"All {len(mutations)} mutations caught: the tests guard their rules.")


if __name__ == "__main__":
    # A stopped CI job still restores the file, just as Ctrl-C does.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    main()
