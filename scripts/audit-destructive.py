#!/usr/bin/env python3
"""Lists every function in Sources/ that holds a call able to delete, move, rename, overwrite, truncate, evict or
change the metadata of a file, or that runs a tool, and checks each is named in docs/destructive-actions.md.

    python3 scripts/audit-destructive.py          # the list, then any function the map doesn't name
    python3 scripts/audit-destructive.py --check  # only the check (CI); exits 1 when the map falls behind

A function only reaches the map by being read: add its row (or add it to one) with the tests that cover it.
"""
import collections
import glob
import re
import sys

API = re.compile(
    r"removeItem\(|trashItem\(|recycle\(|\bunlink(?:at)?\(|\brmdir\(|renamex_np|renameatx_np|\brename(?:at)?\(|exchangedata"
    r"|moveItem\(|replaceItem|copyItem\(|linkItem\(|createSymbolicLink|\blinkat\(|symlinkat\(|\blink\(|\bsymlink\(|clonefile"
    r"|copyfile\(|fcopyfile|\.write\(to:|write\(toFile|writeToFile|createFile\(|FileHandle\(forWriting|FileHandle\(forUpdating"
    r"|O_TRUNC|\bf?truncate\(|\bl?chmod\(|fchmod|fchmodat|\bl?chflags\(|fchflags|\bl?chown\(|fchown|\bf?setxattr|\bf?removexattr"
    r"|acl_set|setResourceValue|setResourceValues|setAttributes\(|\butimes\(|\blutimes|futimes|utimensat|futimens|setTimes"
    r"|evictUbiquitous|setUbiquitous|unmount|eject|Process\(\)|executableURL|NSAppleScript|osascript|performFileOperation"
    r"|mkdirat\(|createDirectory\("
)
FUNCTION = re.compile(r"\b(?:func\s+(\w+)|(init)\s*[(<?])")


def audit():
    found = collections.OrderedDict()
    for path in sorted(glob.glob("Sources/**/*.swift", recursive=True)):
        function = "(top level)"
        for line in open(path):
            code = line.split("//")[0]
            match = FUNCTION.search(code)
            if match:
                function = match.group(1) or match.group(2)
            hits = [m.group(0).rstrip("(") for m in API.finditer(code)]
            if hits:
                key = (path.removeprefix("Sources/").removesuffix(".swift"), function)
                found.setdefault(key, set()).update(hits)
    return found


def named_in_map():
    text = open("docs/destructive-actions.md").read()
    table = text[text.index("## Every function, by file"):]
    names = set()
    for row in table.splitlines():
        if not row.startswith("| `"):
            continue
        cell = row.split("|")[1]
        # `File :: a`, `b`, `c`: the first function shares the file's backticks, the rest have their own. A row may
        # hold several files, each with its functions, up to the next `File ::`.
        for match in re.finditer(r"`([\w/+]+) :: (\(top level\)|\w+)`", cell):
            file, first = match.group(1), match.group(2)
            names.add((file, first))
            rest = cell[match.end():]
            next_file = re.search(r"`[\w/+]+ ::", rest)
            if next_file:
                rest = rest[: next_file.start()]
            for function in re.findall(r"`(\(top level\)|\w+)`", rest):
                names.add((file, function))
        # Files named without functions cover the whole file (plan steps named `rename`, say).
        for file in re.findall(r"`([\w/+]+)`(?! ::)", cell):
            if "/" in file:
                names.add((file, "*"))
    return names


def main():
    check_only = "--check" in sys.argv
    found = audit()
    if not check_only:
        for (file, function), hits in found.items():
            print(f"{file} :: {function} :: {', '.join(sorted(hits))}")
        print()
    named = named_in_map()
    missing = []
    for file, function in found:
        short = file.removeprefix("Strata/")
        if (short, function) in named or (short, "*") in named or (file, function) in named:
            continue
        # A row may name the file with the folder dropped ("ContainerFiles"), as the prose does.
        if any(n[0].endswith("/" + short.split("/")[-1]) or n[0] == short.split("/")[-1] for n in named if n[1] in (function, "*")):
            continue
        missing.append(f"{short} :: {function}")
    if missing:
        print("Not in docs/destructive-actions.md:")
        for item in missing:
            print("  " + item)
        sys.exit(1)
    print(f"docs/destructive-actions.md names all {len(found)} functions the audit found.")


if __name__ == "__main__":
    main()
