#!/usr/bin/env python3
"""Refresh the bundled time zone list from vvo/tzdb (MIT, https://github.com/vvo/tzdb).

Keeps only what the Clocks search needs, one zone per line so diffs stay readable.
Run from anywhere: python3 scripts/update-time-zones.py
"""
import json
import subprocess
from pathlib import Path

URL = "https://raw.githubusercontent.com/vvo/tzdb/main/raw-time-zones.json"
OUT = Path(__file__).resolve().parent.parent / "VibeFlowCore/Sources/VibeFlowCore/Clock/Resources/time-zones.json"

# curl, not urllib: python.org builds of Python ship without root certificates on macOS.
raw = json.loads(subprocess.run(["curl", "-fsSL", URL], check=True, capture_output=True).stdout)

zones = []
for z in raw:
    abbreviations = [a for a in (z.get("abbreviation"), z.get("dstAbbreviation")) if a and not a[0] in "+-"]
    zones.append({
        "id": z["name"],
        "aliases": [g for g in z["group"] if g != z["name"]],
        "name": z["alternativeName"],
        "abbreviations": list(dict.fromkeys(abbreviations)),
        "country": z["countryName"],
        "countryCode": z["countryCode"],
        "cities": z["mainCities"],
    })

OUT.write_text("[\n" + ",\n".join(json.dumps(z, ensure_ascii=False) for z in zones) + "\n]\n", encoding="utf-8")
print(f"{len(zones)} zones -> {OUT}")
