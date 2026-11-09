#!/usr/bin/env bash
# Print the UDID of an available iPhone simulator on the newest iOS runtime.
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]

def version(runtime):
    # Runtime keys look like "...SimRuntime.iOS-27-0". Newer runner images
    # also list keys whose suffix is not a plain version (e.g. containing a
    # device family name); those cannot be ordered as versions, so skip them
    # instead of crashing on int().
    parts = runtime.rsplit("iOS-", 1)[-1].split("-")
    if not all(part.isdigit() for part in parts):
        return None
    return [int(part) for part in parts]

runtimes = [r for r in data if "iOS" in r and version(r) is not None]
runtimes.sort(key=version)
for runtime in reversed(runtimes):
    phones = [d for d in data[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("No available iPhone simulator")
'
