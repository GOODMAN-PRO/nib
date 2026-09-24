#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime that the selected SDK supports."""
import json
import subprocess
import sys

sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
sdk_major = int(sdk.split(".")[0])
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if ".iOS-" not in runtime:
        continue
    version = tuple(int(x) for x in runtime.split(".iOS-")[-1].split("-") if x.isdigit())
    if not version or version[0] > sdk_major:
        continue  # a runtime newer than the SDK cannot run what we build
    for d in devices:
        if not d.get("isAvailable", True):
            continue
        score = (version, "iPhone" in d["name"], "Pro" in d["name"])
        if best is None or score > best[0]:
            best = (score, d["udid"], d["name"], runtime)
if best is None:
    sys.exit("no available iOS simulator for SDK %s" % sdk)
print(best[1])
print("picked %s (%s) for SDK %s" % (best[2], best[3], sdk), file=sys.stderr)
