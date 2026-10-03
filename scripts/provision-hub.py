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

ROUTES = {"audio-original", "gps-delivery", "health-snapshot", "geofence", "wifi", "channel-report", "now-playing", "glasses-original"}
ROUTE_DOMAINS = {
    "audio-original": "audio", "gps-delivery": "gps", "health-snapshot": "health",
    "geofence": "status", "wifi": "status", "channel-report": "status",
    "now-playing": "status", "glasses-original": "glasses",
}
SOURCE_FIELDS = {"schema_version", "source", "base_url", "bearer_token", "allowed_domains"}
PRIVATE_FIELDS = {"schemaVersion", "source", "endpoint", "bearerToken", "deviceID", "enabledRoutes", "legacyDisabledRoutes"}


def _private_file(path):
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 65536:
        raise ValueError("invalid private file")


def _https_url(value):
    if not isinstance(value, str) or not value:
        raise ValueError("invalid source configuration")
    parsed = urlsplit(value)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
            or parsed.password is not None or parsed.query or parsed.fragment
            or parsed.path not in ("", "/")):
        raise ValueError("invalid source configuration")
    return parsed


def _token(value):
    if (not isinstance(value, str) or not value
            or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value)):
        raise ValueError("invalid source configuration")


def _load_source_export(path):
    _private_file(path)
    value = json.loads(path.read_bytes())
    if set(value) != SOURCE_FIELDS or type(value["schema_version"]) is not int or value["schema_version"] != 1:
        raise ValueError("invalid source configuration")
    if value["source"] != "recall":
        raise ValueError("invalid source configuration")
    endpoint = _https_url(value["base_url"])
    _token(value["bearer_token"])
    domains = value["allowed_domains"]
    if (not isinstance(domains, list)
            or any(not isinstance(domain, str) or not domain or domain != domain.strip()
                   or "/" in domain or ":" in domain or any(c.isspace() for c in domain)
                   for domain in domains)):
        raise ValueError("invalid source configuration")
    allowed = {domain.lower() for domain in domains}
    if not allowed <= set(ROUTE_DOMAINS.values()):
        raise ValueError("invalid source configuration")
    return value, endpoint


def _write_private(path, value):
    payload = json.dumps(value, separators=(",", ":"), sort_keys=True).encode("utf-8") + b"\n"
    if len(payload) > 65536:
        raise ValueError("invalid private file")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            fd = None
            handle.write(payload)
    finally:
        if fd is not None:
            os.close(fd)


def _convert(args):
    source, endpoint = _load_source_export(args.source_export)
    if not isinstance(args.device_id, str) or not args.device_id:
        raise ValueError("invalid source configuration")
    enabled = args.enable_route or []
    if not set(enabled) <= ROUTES or len(set(enabled)) != len(enabled):
        raise ValueError("invalid source configuration")
    # Route domains are source-owned; no Hub policy fields are copied.
    allowed = {domain.lower() for domain in source["allowed_domains"]}
    if any(ROUTE_DOMAINS[route] not in allowed for route in enabled):
        raise ValueError("invalid source configuration")
    output = {
        "schemaVersion": 1,
        "source": "recall",
        "endpoint": source["base_url"],
        "bearerToken": source["bearer_token"],
        "deviceID": args.device_id,
        "enabledRoutes": enabled,
        "legacyDisabledRoutes": [],
    }
    _write_private(args.output, output)
    print("Private configuration prepared; not staged or activated")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path)
    parser.add_argument("--device")
    parser.add_argument("--source-export", type=Path)
    parser.add_argument("--device-id")
    parser.add_argument("--enable-route", action="append", default=[])
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        if args.source_export is not None:
            if args.config is not None or args.device is not None or args.device_id is None or args.output is None:
                raise ValueError("invalid source configuration")
            return _convert(args)
        if args.config is None or args.device is None or args.device_id is not None or args.output is not None or args.enable_route:
            raise ValueError("invalid source configuration")
        _private_file(args.config)
        info = args.config.lstat()
        value = json.loads(args.config.read_bytes())
        if set(value) != PRIVATE_FIELDS:
            raise ValueError("Unexpected configuration fields")
        endpoint = urlsplit(value["endpoint"])
        if (type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
                or value["source"] != "recall" or not isinstance(value["deviceID"], str) or not value["deviceID"]
                or endpoint.scheme != "https" or not endpoint.hostname
                or endpoint.username is not None or endpoint.password is not None
                or endpoint.query or endpoint.fragment or endpoint.path not in ("", "/")
                or not isinstance(value["bearerToken"], str) or not value["bearerToken"]
                or any(c.isspace() or ord(c) < 32 or ord(c) == 127 for c in value["bearerToken"])
                or not isinstance(value["enabledRoutes"], list) or not isinstance(value["legacyDisabledRoutes"], list)
                or not set(value["enabledRoutes"]) <= ROUTES
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
