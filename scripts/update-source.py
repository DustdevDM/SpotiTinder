#!/usr/bin/env python3
"""Adds a new release to altstore-source.json, newest first, keeping the last 10 versions."""
import argparse
import datetime
import json
from pathlib import Path

SOURCE = Path(__file__).resolve().parent.parent / "altstore-source.json"

parser = argparse.ArgumentParser()
parser.add_argument("--version", required=True)
parser.add_argument("--build", required=True)
parser.add_argument("--url", required=True)
parser.add_argument("--size", required=True, type=int)
parser.add_argument("--notes", default="")
args = parser.parse_args()

source = json.loads(SOURCE.read_text())
app = source["apps"][0]
entry = {
    "version": args.version,
    "buildVersion": args.build,
    "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "localizedDescription": args.notes,
    "downloadURL": args.url,
    "size": args.size,
    "minOSVersion": "18.0",
}
app["versions"] = [entry] + [v for v in app["versions"] if v["version"] != args.version][:9]
SOURCE.write_text(json.dumps(source, indent=2, ensure_ascii=False) + "\n")
print(f"altstore-source.json now offers {args.version}")
