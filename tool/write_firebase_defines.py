#!/usr/bin/env python3
"""Generate local Firebase configuration atomically, retaining a core-only API URL."""
import json
import os
from pathlib import Path
import plistlib
import sys
import tempfile


def native_callback_contents(config):
    """Validate the native OAuth client before it becomes an Xcode build setting."""
    client_id = config.get("CLIENT_ID", "")
    reversed_id = config.get("REVERSED_CLIENT_ID", "")
    if not client_id and not reversed_id:
        return None
    if not client_id or reversed_id != ".".join(reversed(client_id.split("."))):
        raise ValueError("Google callback must match its native OAuth client")
    if not all(character.isalnum() or character in ".-" for character in reversed_id):
        raise ValueError("Google callback contains invalid build setting characters")
    return ("// Generated locally; never commit environment configuration.\n"
            f"GOOGLE_REVERSED_CLIENT_ID = {reversed_id}\n")


def atomic_write(output, contents):
    """Publish complete private configuration without exposing a partial file."""
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".defines-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(contents)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_defines(config_file, output, api_url="", macos_config_file="", google_server_client_id=""):
    """Write public Firebase/OAuth IDs and matching native callbacks, never secrets.

    Auth-only installs omit the endpoint; later core updates retain its value.
    Native callback files live beside the defines so ignored environment config
    stays out of the Xcode project while both platforms use their own OAuth IDs.
    """
    config = plistlib.loads(Path(config_file).read_bytes())
    fields = {
        "FIREBASE_API_KEY": "API_KEY",
        "FIREBASE_APP_ID": "GOOGLE_APP_ID",
        "FIREBASE_MESSAGING_SENDER_ID": "GCM_SENDER_ID",
        "FIREBASE_PROJECT_ID": "PROJECT_ID",
    }
    values = {target: config[source] for target, source in fields.items()}
    output = Path(output)
    previous = json.loads(output.read_text()) if output.exists() else {}
    same_project = previous.get("FIREBASE_PROJECT_ID") == values["FIREBASE_PROJECT_ID"]
    if config.get("CLIENT_ID"):
        values["FIREBASE_GOOGLE_CLIENT_ID"] = config["CLIENT_ID"]
    if google_server_client_id:
        values["FIREBASE_GOOGLE_SERVER_CLIENT_ID"] = google_server_client_id
    if config.get("STORAGE_BUCKET"):
        values["FIREBASE_STORAGE_BUCKET"] = config["STORAGE_BUCKET"]
    if macos_config_file:
        macos_config = plistlib.loads(Path(macos_config_file).read_bytes())
        if macos_config["PROJECT_ID"] != config["PROJECT_ID"]:
            raise ValueError("Apple Firebase registrations must share a project")
        values["FIREBASE_MACOS_APP_ID"] = macos_config["GOOGLE_APP_ID"]
        values["FIREBASE_MACOS_API_KEY"] = macos_config["API_KEY"]
        if macos_config.get("CLIENT_ID"):
            values["FIREBASE_GOOGLE_MACOS_CLIENT_ID"] = macos_config["CLIENT_ID"]
    if same_project and not macos_config_file and previous.get("FIREBASE_MACOS_APP_ID"):
        values["FIREBASE_MACOS_APP_ID"] = previous["FIREBASE_MACOS_APP_ID"]
        for key in ["FIREBASE_MACOS_API_KEY", "FIREBASE_GOOGLE_MACOS_CLIENT_ID"]:
            if previous.get(key):
                values[key] = previous[key]
    if not api_url and same_project:
        api_url = previous.get("ILLUSTRATION_API_BASE_URL", "")
    if api_url:
        values["ILLUSTRATION_API_BASE_URL"] = api_url
        values["NARRATION_API_BASE_URL"] = api_url
    # Validate both registrations before replacing any file; a mismatched project
    # or callback must leave the previously usable environment intact.
    callbacks = {"ios": native_callback_contents(config), "macos": None}
    if macos_config_file:
        callbacks["macos"] = native_callback_contents(macos_config)
    elif values.get("FIREBASE_GOOGLE_MACOS_CLIENT_ID"):
        # Only an omitted same-project platform retains its known registration.
        # Rebuild its callback from the retained client, never trust an old file.
        client = values["FIREBASE_GOOGLE_MACOS_CLIENT_ID"]
        callbacks["macos"] = native_callback_contents({
            "CLIENT_ID": client,
            "REVERSED_CLIENT_ID": ".".join(reversed(client.split("."))),
        })
    if same_project and not google_server_client_id:
        if previous.get("FIREBASE_GOOGLE_SERVER_CLIENT_ID"):
            values["FIREBASE_GOOGLE_SERVER_CLIENT_ID"] = previous["FIREBASE_GOOGLE_SERVER_CLIENT_ID"]
    for platform, contents in callbacks.items():
        callback_file = output.parent / f"{platform}.xcconfig"
        if contents is None:
            # Explicit missing OAuth configuration and project switches fail
            # closed instead of leaving an unrelated native callback registered.
            callback_file.unlink(missing_ok=True)
        else:
            atomic_write(callback_file, contents)
    atomic_write(output, json.dumps(values, indent=2) + "\n")


if __name__ == "__main__":
    write_defines(*sys.argv[1:])
