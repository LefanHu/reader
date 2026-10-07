#!/usr/bin/env python3
"""Generate local Firebase configuration atomically, retaining a core-only API URL."""
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile


def write_defines(config_file, output, api_url="", macos_config_file=""):
    """Auth-only installs omit the endpoint; later core updates retain its value."""
    config = plistlib.loads(Path(config_file).read_bytes())
    fields = {
        "FIREBASE_API_KEY": "API_KEY",
        "FIREBASE_APP_ID": "GOOGLE_APP_ID",
        "FIREBASE_MESSAGING_SENDER_ID": "GCM_SENDER_ID",
        "FIREBASE_PROJECT_ID": "PROJECT_ID",
    }
    values = {target: config[source] for target, source in fields.items()}
    if config.get("STORAGE_BUCKET"):
        values["FIREBASE_STORAGE_BUCKET"] = config["STORAGE_BUCKET"]
    if macos_config_file:
        macos_config = plistlib.loads(Path(macos_config_file).read_bytes())
        if macos_config["PROJECT_ID"] != config["PROJECT_ID"]:
            raise ValueError("Apple Firebase registrations must share a project")
        values["FIREBASE_MACOS_APP_ID"] = macos_config["GOOGLE_APP_ID"]
        values["FIREBASE_MACOS_API_KEY"] = macos_config["API_KEY"]
    output = Path(output)
    if output.exists() and not macos_config_file:
        previous = json.loads(output.read_text())
        if previous.get("FIREBASE_PROJECT_ID") == values["FIREBASE_PROJECT_ID"] and previous.get("FIREBASE_MACOS_APP_ID"):
            values["FIREBASE_MACOS_APP_ID"] = previous["FIREBASE_MACOS_APP_ID"]
            if previous.get("FIREBASE_MACOS_API_KEY"):
                values["FIREBASE_MACOS_API_KEY"] = previous["FIREBASE_MACOS_API_KEY"]
    if not api_url and output.exists():
        api_url = json.loads(output.read_text()).get("ILLUSTRATION_API_BASE_URL", "")
    if api_url:
        values["ILLUSTRATION_API_BASE_URL"] = api_url
        values["NARRATION_API_BASE_URL"] = api_url
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".defines-", dir=output.parent)
    try:
        # mkstemp creates a private file before any configuration is written.
        with os.fdopen(descriptor, "w") as handle:
            json.dump(values, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


if __name__ == "__main__":
    write_defines(*sys.argv[1:])
