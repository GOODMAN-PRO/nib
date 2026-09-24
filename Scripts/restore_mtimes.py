#!/usr/bin/env python3
"""Set every tracked file's mtime to the time of the last commit that touched it (CI; needs checkout fetch-depth 0).

A fresh checkout stamps every file "now", so a restored DerivedData would recompile everything. With commit times,
files a commit did not touch look unchanged and only what changed recompiles (ios.yml also sets XCBuild's
IgnoreFileSystemDeviceInodeChanges). Files missing from the history keep "now", which only costs a rebuild.
"""
import os
import subprocess

os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
log =subprocess.run(["git", "-c", "core.quotePath=false", "log", "--format=@%ct", "--name-only", "--no-renames"],
                     capture_output=True, text=True, check=True).stdout
seen, when = set(), 0
for line in log.splitlines():
    if line.startswith("@"):
        when = int(line[1:])
    elif line and line not in seen:
        seen.add(line)  # newest commit first, so the first time a path appears is its last change
        if os.path.isfile(line):
            os.utime(line, (when, when))
print("restore_mtimes: %d paths" % len(seen))
