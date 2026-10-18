#!/usr/bin/env bash
# Print the UDID of an available iPhone simulator on the newest iOS runtime.
set -euo pipefail

xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)["devices"]
runtimes = sorted((r for r in data if "iOS" in r), key=lambda r: [int(x) for x in r.rsplit("iOS-", 1)[-1].split("-")])
for runtime in reversed(runtimes):
    phones = [d for d in data[runtime] if d["name"].startswith("iPhone")]
    if phones:
        print(phones[0]["udid"])
        sys.exit(0)
sys.exit("No available iPhone simulator")
'
