#!/usr/bin/env python3
"""Proves the destructive-action tests guard their rules: each mutation in Tests/mutations.json breaks one rule in the
code, and the tests named for it must then fail. Every mutation is applied alone, its tests run, and the file restored
from git before the next.

    python3 scripts/mutate.py                 # every mutation (an hour or so: one build each)
    python3 scripts/mutate.py Trash Undo      # only mutations whose rule mentions these words
    python3 scripts/mutate.py --list          # the rules, without running anything

Exit 1 when a mutation isn't caught (its tests still pass), its text isn't found in the file (the code moved: update
`find`), or a restore fails. The working tree must be clean for the files mutated; the script refuses otherwise.

A mutation names: `file` (under Sources/), `find` (text that occurs exactly once), `replace`, `rule` (what it breaks, in
the user's words) and `tests` (a `swift test --filter` pattern). A rule with layered defenses (a check, and a second
behind it) gives `edits`, a list of `{find, replace}` pairs applied together, instead of one `find`/`replace`. Add one
with every new destructive-action test.
"""
import json
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


def sh(args, **kw):
    env = dict(os.environ)
    if os.path.isdir(DEVELOPER_DIR) and "DEVELOPER_DIR" not in env:
        env["DEVELOPER_DIR"] = DEVELOPER_DIR
    return subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, **kw)


def tests_fail(pattern):
    """True when the test run fails (the mutation is caught); None when it doesn't build."""
    run = sh(["swift", "test", "--filter", pattern])
    out = run.stdout + run.stderr
    if re.search(r"error: .*(Compile|Build failed|fatalError)", out) and "Test run" not in out:
        return None
    if re.search(r"✘ Test run with \d+ tests? in \d+ suites? failed", out):
        return True
    if re.search(r"✔ Test run with \d+ tests? in \d+ suites? passed", out):
        return False
    if re.search(r"Test run with 0 tests", out):
        return None
    return None


def main():
    # Progress shows as it happens, in a log file or CI as well as a terminal.
    sys.stdout.reconfigure(line_buffering=True)
    mutations = json.load(open(os.path.join(ROOT, "Tests", "mutations.json")))
    words = [a for a in sys.argv[1:] if not a.startswith("--")]
    if words:
        mutations = [m for m in mutations if any(w.lower() in m["rule"].lower() for w in words)]
    if "--list" in sys.argv:
        for m in mutations:
            print(f"{m['file']}: {m['rule']}  →  {m['tests']}")
        return
    files = sorted({m["file"] for m in mutations})
    dirty = sh(["git", "status", "--porcelain", "--"] + [f"Sources/{f}" for f in files]).stdout.strip()
    if dirty:
        print("These files have uncommitted changes; commit or stash them first:\n" + dirty)
        sys.exit(1)
    failures = []
    for n, m in enumerate(mutations, 1):
        path = os.path.join(ROOT, "Sources", m["file"])
        source = open(path).read()
        edits = m.get("edits") or [{"find": m["find"], "replace": m["replace"]}]
        counts = [source.count(e["find"]) for e in edits]
        if any(c != 1 for c in counts):
            print(f"[{n}/{len(mutations)}] NOT FOUND ({'/'.join(map(str, counts))}×): {m['file']}: {m['rule']}")
            failures.append(m)
            continue
        mutated = source
        for e in edits:
            mutated = mutated.replace(e["find"], e["replace"])
        open(path, "w").write(mutated)
        os.utime(path)
        try:
            caught = tests_fail(m["tests"])
        finally:
            restore = sh(["git", "checkout", "--", f"Sources/{m['file']}"])
            if restore.returncode != 0 or open(path).read() != source:
                print(f"RESTORE FAILED for {m['file']}; put it back by hand (git checkout -- Sources/{m['file']})")
                sys.exit(2)
        if caught is True:
            print(f"[{n}/{len(mutations)}] caught: {m['rule']}")
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
    main()
