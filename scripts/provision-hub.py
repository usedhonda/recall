#!/usr/bin/env python3
"""Stage a Recall-only private configuration; never print its contents."""

import argparse
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--device", required=True)
    args = parser.parse_args()
    try:
        info = args.config.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 65536:
            raise ValueError("Private configuration must be a regular file with mode 600 and at most 64 KiB")
        value = json.loads(args.config.read_bytes())
        if set(value) != {"schemaVersion", "source", "endpoint", "bearerToken", "deviceID", "enabledRoutes", "legacyDisabledRoutes"}:
            raise ValueError("Unexpected configuration fields")
        endpoint = urlsplit(value["endpoint"])
        routes = {"audio-original", "gps-delivery", "health-snapshot", "geofence", "wifi", "channel-report", "now-playing", "glasses-original"}
        if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
                or value["source"] != "recall" or not isinstance(value["deviceID"], str) or not value["deviceID"]
                or endpoint.scheme != "https" or not endpoint.hostname
                or endpoint.username is not None or endpoint.password is not None
                or endpoint.query or endpoint.fragment or endpoint.path not in ("", "/")
                or not isinstance(value["bearerToken"], str) or not value["bearerToken"]
                or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value["bearerToken"])
                or not isinstance(value["enabledRoutes"], list) or not isinstance(value["legacyDisabledRoutes"], list)
                or not set(value["enabledRoutes"]) <= routes
                or not set(value["legacyDisabledRoutes"]) <= set(value["enabledRoutes"])):
            raise ValueError("Invalid source configuration")
        # No token or URL in argv, environment, stdout, or devicectl diagnostics.
        result = subprocess.run([
            "xcrun", "devicectl", "device", "copy", "to", "--device", args.device,
            "--source", str(args.config.resolve()), "--destination", "Documents/hub-provisioning.json",
            "--domain-type", "appDataContainer", "--domain-identifier", "com.example.recall",
        ], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if result.returncode:
            print(f"Private transfer failed (exit {result.returncode}); configuration not confirmed", file=sys.stderr)
            return 1
        print("Private configuration staged; app Keychain import and route acceptance are not yet confirmed")
        return 0
    except Exception:
        # Input errors can contain a credential. Do not print exception strings.
        print("Private configuration validation or transfer failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
