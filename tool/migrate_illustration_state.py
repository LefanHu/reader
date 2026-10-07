#!/usr/bin/env python3
"""Move existing illustration ownership without recreating resources or secrets.

Remote destination is committed first. An interrupted migration can leave duplicate
ownership, which is removed on retry only when both complete instance records agree.
Run during a maintenance window: Terraform cannot lock two backends atomically.
"""
import argparse
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid

MANIFEST = Path(__file__).with_name("illustration_state_moves.json")


def destination(address):
    """Resolve only explicitly inventoried resources, including for_each instances."""
    for source, target in json.loads(MANIFEST.read_text()).items():
        if address == source or address.startswith(source + "["):
            return target + address[len(source):]
    return None


def inventory(state):
    """Index complete instance records; IDs alone cannot safely detect conflicts."""
    result = {}
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        base = (resource.get("module", "") + "." if resource.get("module") else "")
        base += resource["type"] + "." + resource["name"]
        for instance in resource.get("instances", []):
            key = instance.get("index_key")
            suffix = "" if key is None else "[" + json.dumps(key, separators=(",", ":")) + "]"
            # Terraform 1.14 serializes the default identity schema explicitly
            # when editing older states. Compare that default semantically while
            # preserving all attributes, sensitive paths, and private metadata.
            normalized = copy.deepcopy(instance)
            normalized.setdefault("identity_schema_version", 0)
            result[base + suffix] = {
                "provider": resource["provider"],
                "instance": normalized,
            }
    return result


def run(infra, stack, *args, allow_empty=False):
    """Keep Terraform diagnostics private because state commands handle secrets."""
    result = subprocess.run(
        ["terraform", f"-chdir={infra / stack}", *args],
        capture_output=True, text=True,
    )
    if result.returncode:
        if allow_empty and "No state file was found" in result.stderr:
            return ""
        raise RuntimeError(f"Terraform {stack} {args[0]} failed; no state contents were logged")
    return result.stdout


def pull(infra, stack):
    """An absent backend is distinct from authentication or connectivity failures."""
    raw = run(infra, stack, "state", "pull", allow_empty=True)
    return json.loads(raw) if raw.strip() else None


def empty_state():
    """Create a destination lineage only when the remote backend is genuinely empty."""
    return {"version": 4, "terraform_version": "1.14.0", "serial": 0,
            "lineage": str(uuid.uuid4()), "outputs": {}, "resources": []}


def unchanged(infra, stack, expected):
    """Abort on concurrent state writes; never bypass Terraform serial protection."""
    if pull(infra, stack) != expected:
        raise RuntimeError(f"{stack} state changed concurrently; stop other deployments and retry")


def migrate(infra, apply=False):
    """Preview by default; apply uses Terraform's local state operations and safe pushes."""
    source = pull(infra, "foundation")
    target = pull(infra, "illustrations")
    source_records = inventory(source or {})
    target_records = inventory(target or {})
    moves = [(old, destination(old)) for old in source_records if destination(old)]
    for old, new in moves:
        if new in target_records and source_records[old] != target_records[new]:
            raise RuntimeError(f"Conflicting destination ownership at {new}; no state was changed")
    print(f"Illustration ownership migration: {len(moves)} instance(s).")
    for old, new in moves:
        print(f"  {old} -> {new}")
    if not moves:
        print("No legacy illustration ownership remains.")
        return
    if not apply:
        print("Preview only. Stop concurrent Terraform operations, then rerun with --apply.")
        return

    # The versioned remote bucket preserves durable prior snapshots. Local backups
    # and working copies are private and removed even when a state command fails.
    os.umask(0o077)
    with tempfile.TemporaryDirectory(prefix="reader-state-migration-") as temporary:
        workspace = Path(temporary)
        source_file = workspace / "foundation.tfstate"
        target_file = workspace / "illustrations.tfstate"
        source_file.write_text(json.dumps(source))
        target_file.write_text(json.dumps(target or empty_state()))
        # Run local edits from a backend-free directory. Remote-backend roots
        # can ignore legacy -state flags and must never execute these edits.
        for old, new in moves:
            if new in target_records:
                run(workspace, ".", "state", "rm", f"-state={source_file}", old)
            else:
                run(workspace, ".", "state", "mv", f"-state={source_file}",
                    f"-state-out={target_file}", old, new)
        desired_source = json.loads(source_file.read_text())
        desired_target = json.loads(target_file.read_text())
        expected_source = copy.deepcopy(source_records)
        expected_target = copy.deepcopy(target_records)
        for old, new in moves:
            expected_target[new] = expected_source.pop(old)
        if inventory(desired_source) != expected_source or inventory(desired_target) != expected_target:
            raise RuntimeError("Local migration validation failed; remote states are unchanged")
        if desired_source["lineage"] != source["lineage"]:
            raise RuntimeError("Source lineage changed; remote states are unchanged")
        if target and desired_target["lineage"] != target["lineage"]:
            raise RuntimeError("Destination lineage changed; remote states are unchanged")
        unchanged(infra, "foundation", source)
        unchanged(infra, "illustrations", target)
        if desired_target != target:
            run(infra, "illustrations", "state", "push", str(target_file))
        committed_target = pull(infra, "illustrations")
        if not committed_target or inventory(committed_target) != expected_target:
            raise RuntimeError("Destination verification failed; source ownership was retained")
        unchanged(infra, "foundation", source)
        unchanged(infra, "illustrations", committed_target)
        # A failed source push leaves destination intact and is safe to resume.
        run(infra, "foundation", "state", "push", str(source_file))
        if inventory(pull(infra, "foundation") or {}) != expected_source:
            raise RuntimeError("Source verification failed; rerun migration before deploying")
    print("Ownership migrated. Review core and illustration plans before deploying.")


def main():
    """Expose a credential-free address guard and an explicit migration apply option."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("infra", nargs="?", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--check-addresses", type=Path)
    parser.add_argument("--check-state", type=Path)
    args = parser.parse_args()
    if args.check_addresses:
        return 1 if any(destination(a) for a in args.check_addresses.read_text().splitlines()) else 0
    if args.check_state:
        try:
            records = inventory(pull(args.check_state.resolve(), "foundation") or {})
            return 1 if any(destination(address) for address in records) else 0
        except (RuntimeError, ValueError, OSError):
            print("Cannot verify core state; no changes are safe to apply.", file=sys.stderr)
            return 1
    if args.infra is None:
        parser.error("infra directory is required")
    try:
        migrate(args.infra.resolve(), args.apply)
    except (RuntimeError, ValueError, OSError) as error:
        # JSON decoding exceptions contain no raw state; avoid subprocess stderr.
        print(f"Migration stopped: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
