"""Offline checks for deployment boundaries and resumable Terraform ownership moves."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tool" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


migration = load_tool("migrate_illustration_state")
defines = load_tool("write_firebase_defines")


def fixture_state():
    """Retain private data and for_each keys so moves exercise complete records."""
    state = migration.empty_state()
    state["serial"] = 7
    for kind, name, key, attributes in [
        ("google_project", "environment", None, {"id": "reader-test"}),
        ("google_project_service", "required", "firestore.googleapis.com", {"id": "core-api"}),
        ("google_project_service", "required", "run.googleapis.com", {"id": "runtime-api"}),
        ("google_firestore_index", "composite", "illustrationJobs", {"id": "index-1"}),
        ("random_password", "fingerprint", None, {"id": "password", "result": "private-fingerprint"}),
        ("google_secret_manager_secret_version", "fingerprint", None, {"id": "secret-1", "secret_data": "private-fingerprint"}),
    ]:
        provider = "random" if kind == "random_password" else "google"
        instance = {"schema_version": 0, "attributes": attributes, "sensitive_attributes": [], "private": "cHJpdmF0ZQ=="}
        if key is not None:
            instance["index_key"] = key
        state["resources"].append({"module": "module.foundation", "mode": "managed", "type": kind,
                                   "name": name, "provider": f'provider["registry.terraform.io/hashicorp/{provider}"]',
                                   "instances": [instance]})
    return state


class MigrationTests(unittest.TestCase):
    """Exercise migration with real local state edits and mocked remote commits."""
    def setUp(self):
        self.states = {"foundation": fixture_state(), "illustrations": None}
        self.events = []
        self.fail_source = False
        self.output = io.StringIO()
        self.original_run = migration.run

    def pull(self, infra, stack):
        return copy.deepcopy(self.states[stack])

    def terraform_run(self, infra, stack, *args, **kwargs):
        if args[:2] == ("state", "push"):
            self.events.append(stack)
            if stack == "foundation" and self.fail_source:
                raise RuntimeError("simulated source push failure")
            state = json.loads(Path(args[2]).read_text())
            existing = self.states[stack]
            if existing:
                self.assertEqual(existing["lineage"], state["lineage"])
                self.assertGreater(state["serial"], existing["serial"])
            self.states[stack] = state
            return ""
        # Real local Terraform edits verify serialization without touching a backend.
        self.assertEqual(stack, ".")
        self.assertFalse((infra / ".terraform").exists())
        return self.original_run(infra, stack, *args, **kwargs)

    def migrate(self, apply):
        with patch.object(migration, "pull", self.pull), patch.object(migration, "run", self.terraform_run), contextlib.redirect_stdout(self.output):
            migration.migrate(ROOT / "infra", apply)

    def test_preview_reports_addresses_without_writing_or_logging_secrets(self):
        before = copy.deepcopy(self.states)
        self.migrate(False)
        self.assertEqual(before, self.states)
        self.assertEqual([], self.events)
        self.assertNotIn("private-fingerprint", self.output.getvalue())

    def test_moves_complete_records_and_commits_destination_before_source(self):
        before = migration.inventory(self.states["foundation"])
        lineage = self.states["foundation"]["lineage"]
        self.migrate(True)
        self.assertEqual(["illustrations", "foundation"], self.events)
        self.assertEqual(lineage, self.states["foundation"]["lineage"])
        for address, record in before.items():
            target = migration.destination(address)
            stack = "illustrations" if target else "foundation"
            self.assertEqual(record, migration.inventory(self.states[stack])[target or address])
        self.assertNotIn("private-fingerprint", self.output.getvalue())

    def test_retry_finishes_after_destination_commit_and_failed_source_push(self):
        self.fail_source = True
        with self.assertRaisesRegex(RuntimeError, "simulated"):
            self.migrate(True)
        self.assertIsNotNone(self.states["illustrations"])
        self.assertTrue(any(migration.destination(a) for a in migration.inventory(self.states["foundation"])))
        self.fail_source = False
        target = copy.deepcopy(self.states["illustrations"])
        self.migrate(True)
        self.assertEqual(target, self.states["illustrations"])
        self.assertFalse(any(migration.destination(a) for a in migration.inventory(self.states["foundation"])))
        self.assertEqual(["illustrations", "foundation", "foundation"], self.events)
        self.migrate(True)
        self.assertEqual(["illustrations", "foundation", "foundation"], self.events)

    def test_conflicting_destination_stops_before_any_write(self):
        self.migrate(True)
        self.states["foundation"] = fixture_state()
        self.states["illustrations"]["resources"][0]["instances"][0]["attributes"]["id"] = "unexpected"
        before = copy.deepcopy(self.states)
        self.events.clear()
        with self.assertRaisesRegex(RuntimeError, "Conflicting"):
            self.migrate(True)
        self.assertEqual(before, self.states)
        self.assertEqual([], self.events)

    def test_same_resource_ids_with_changed_secret_data_are_rejected(self):
        self.migrate(True)
        self.states["foundation"] = fixture_state()
        password = next(r for r in self.states["illustrations"]["resources"] if r["type"] == "random_password")
        password["instances"][0]["attributes"]["result"] = "unexpected-secret"
        before = copy.deepcopy(self.states)
        self.events.clear()
        with self.assertRaisesRegex(RuntimeError, "Conflicting"):
            self.migrate(True)
        self.assertEqual(before, self.states)
        self.assertEqual([], self.events)

    def test_empty_installation_needs_no_state_transfer(self):
        self.states = {"foundation": None, "illustrations": None}
        self.migrate(True)
        self.assertEqual([], self.events)
        self.assertEqual({"foundation": None, "illustrations": None}, self.states)

    def test_failed_destination_push_retains_all_source_ownership(self):
        before = copy.deepcopy(self.states)
        original_run = self.terraform_run

        def fail_destination(infra, stack, *args, **kwargs):
            if stack == "illustrations" and args[:2] == ("state", "push"):
                raise RuntimeError("simulated destination failure")
            return original_run(infra, stack, *args, **kwargs)

        with patch.object(migration, "pull", self.pull), patch.object(migration, "run", fail_destination), contextlib.redirect_stdout(self.output):
            with self.assertRaisesRegex(RuntimeError, "destination failure"):
                migration.migrate(ROOT / "infra", True)
        self.assertEqual(before, self.states)
        self.assertEqual([], self.events)

    def test_concurrent_state_change_stops_before_destination_push(self):
        calls = 0
        original_pull = self.pull

        def changed(infra, stack):
            nonlocal calls
            result = original_pull(infra, stack)
            if stack == "foundation":
                calls += 1
                if calls > 1:
                    result["serial"] += 1
            return result

        with patch.object(migration, "pull", changed), patch.object(migration, "run", self.terraform_run), contextlib.redirect_stdout(self.output):
            with self.assertRaisesRegex(RuntimeError, "concurrently"):
                migration.migrate(ROOT / "infra", True)
        self.assertEqual([], self.events)


class ConfigurationTests(unittest.TestCase):
    """Verify persisted configuration and disjoint Terraform ownership."""
    def test_core_only_defines_omit_endpoint_then_preserve_existing_endpoint(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "firebase.plist"
            config.write_bytes(plistlib.dumps({"API_KEY": "key", "GOOGLE_APP_ID": "app", "GCM_SENDER_ID": "sender", "PROJECT_ID": "project"}))
            output = Path(directory) / "defines.json"
            defines.write_defines(config, output)
            self.assertNotIn("ILLUSTRATION_API_BASE_URL", json.loads(output.read_text()))
            defines.write_defines(config, output, "https://api.test")
            defines.write_defines(config, output)
            self.assertEqual("https://api.test", json.loads(output.read_text())["ILLUSTRATION_API_BASE_URL"])
            self.assertEqual(0o600, output.stat().st_mode & 0o777)
            self.assertEqual([], list(output.parent.glob(".defines-*")))

    def test_feature_manifest_matches_resources_and_api_ownership_is_disjoint(self):
        core = (ROOT / "infra/modules/foundation/main.tf").read_text()
        feature = (ROOT / "infra/modules/illustrations/main.tf").read_text()
        pattern = r'resource "([^"]+)" "([^"]+)"'
        feature_addresses = {f"module.illustrations.{kind}.{name}" for kind, name in re.findall(pattern, feature) if kind != "google_project_service"}
        moves = json.loads(migration.MANIFEST.read_text())
        self.assertEqual(feature_addresses, {a for a in moves.values() if "google_project_service" not in a})
        core_apis = set(re.findall(r'"([a-z]+\.googleapis\.com)"', core))
        feature_apis = set(re.findall(r'"([a-z]+\.googleapis\.com)"', feature))
        self.assertFalse(core_apis & feature_apis)
        self.assertEqual(feature_apis, {json.loads(a[a.index("[")+1:-1]) for a in moves if "google_project_service" in a})


# These stubs execute the actual shell entrypoints against a disposable checkout.
# They record cloud/tool requests, never contacting a service or changing the repo.
STUB = r'''#!/usr/bin/env python3
import base64,json,os,pathlib,plistlib,sys
name=pathlib.Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['CALL_LOG'],'a') as log: log.write(json.dumps([name,*args])+'\n')
if name=='terraform':
    if args==['version','-json']: print('{"terraform_version":"1.14.8"}')
    if 'pull' in args:
        if os.environ.get('LEGACY_STATE')=='1':
            print(json.dumps({'resources':[{'module':'module.foundation','mode':'managed','type':'random_password','name':'fingerprint','provider':'random','instances':[{'attributes':{'id':'test'}}]}]}))
        else: print('{"resources":[]}')
    if 'show' in args: print('{"resource_changes":[]}')
    if 'output' in args:
        key=args[-1]
        if key=='project_id' and os.environ.get('MISSING_CORE')=='1': sys.exit(1)
        if key=='firebase_config':
            print(base64.b64encode(plistlib.dumps({'API_KEY':'key','GOOGLE_APP_ID':'app','GCM_SENDER_ID':'sender','PROJECT_ID':'project'})).decode())
        else: print({'project_id':'reader-test','build_service_account':'build@example.test','openai_secret_id':'openai','api_url':'https://api.test','worker_url':'https://worker.test','image':'test@sha256:'+'a'*64}.get(key,''))
    if 'list' in args: print('google_project.state\ngoogle_storage_bucket.state')
elif name=='gcloud':
    if args[:2]==['auth','list']: print('test@example.test')
    if args[:2]==['storage','ls'] and os.environ.get('RUNTIME_EXISTS')!='1': sys.exit(1)
    if args[:3]==['secrets','versions','list']: print('1')
    if args[:3]==['artifacts','docker','images']: print('sha256:'+'a'*64)
elif name=='curl' and '--write-out' in args: print('403',end='')
elif name=='git': print('abc123')
'''


class DeploymentTests(unittest.TestCase):
    """Verify executable deployment paths using disposable tool stubs."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        shutil.copytree(ROOT / "tool", self.root / "tool", ignore=shutil.ignore_patterns("__pycache__"))
        shutil.copytree(ROOT / "infra/environments", self.root / "infra/environments")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ["terraform", "gcloud", "npm", "curl", "git"]:
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.log = self.root / "calls.jsonl"
        self.env = {**os.environ, "PATH": f"{self.bin}:{os.environ['PATH']}", "CALL_LOG": str(self.log),
                    "TF_VAR_apple_client_id": "client", "TF_VAR_apple_client_secret": "secret"}

    def execute(self, script, *args, **env):
        result = subprocess.run([str(self.root / "tool" / script), "dev", *args], env={**self.env, **env}, capture_output=True, text=True, stdin=subprocess.DEVNULL)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        return result, calls

    def test_core_deployment_skips_feature_stack_build_and_openai(self):
        result, calls = self.execute("deploy_backend", "--scope", "core")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any(c[0] in {"npm", "curl"} for c in calls))
        self.assertFalse(any(c[0]=='gcloud' and c[1] in {'secrets','builds'} for c in calls))
        self.assertFalse(any('/illustrations' in c[1] for c in calls if c[0]=='terraform' and len(c)>1))
        config = json.loads((self.root / ".dart-defines/dev.json").read_text())
        self.assertNotIn("ILLUSTRATION_API_BASE_URL", config)

    def test_default_deployment_keeps_full_workflow_and_one_build(self):
        result, calls = self.execute("deploy_backend")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(1, sum(c[:3]==['gcloud','builds','submit'] for c in calls))
        self.assertTrue(any('/illustrations' in c[1] for c in calls if c[0]=='terraform' and len(c)>1))
        self.assertEqual('https://api.test', json.loads((self.root / ".dart-defines/dev.json").read_text())['ILLUSTRATION_API_BASE_URL'])

    def test_illustrations_requires_existing_core_before_feature_apply(self):
        result, calls = self.execute("deploy_backend", "--scope", "illustrations", MISSING_CORE='1')
        self.assertNotEqual(0, result.returncode)
        self.assertIn('core is not initialized', result.stderr)
        self.assertFalse(any('apply' in c for c in calls))
        self.assertFalse(any(c[:3]==['gcloud','builds','submit'] for c in calls))

    def test_illustrations_deployment_does_not_request_apple_credentials(self):
        result, calls = self.execute("deploy_backend", "--scope", "illustrations", TF_VAR_apple_client_id='', TF_VAR_apple_client_secret='')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any('apply' in c and '/foundation' in c[1] for c in calls if c[0]=='terraform'))
        self.assertFalse(any(c[:3]==['gcloud','projects','create'] for c in calls))

    def test_legacy_ownership_blocks_infrastructure_apply(self):
        result, calls = self.execute("deploy_backend", "--scope", "illustrations", LEGACY_STATE='1')
        self.assertNotEqual(0, result.returncode)
        self.assertIn('migrate_backend_state', result.stderr)
        self.assertFalse(any('apply' in c for c in calls))

    def test_legacy_ownership_blocks_default_deployment_before_bootstrap_apply(self):
        result, calls = self.execute("deploy_backend", LEGACY_STATE='1')
        self.assertNotEqual(0, result.returncode)
        self.assertIn('migrate_backend_state', result.stderr)
        self.assertFalse(any('apply' in c for c in calls))
        self.assertFalse(any(c[:3]==['gcloud','billing','projects'] for c in calls))

    def test_core_plan_has_no_runtime_image_requirement_or_apply(self):
        result, calls = self.execute("plan_infra", "--scope", "core")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertFalse(any('apply' in c for c in calls))
        self.assertFalse(any('/runtime' in c[1] or '/illustrations' in c[1] for c in calls if c[0]=='terraform'))

    def test_new_installation_plan_reviews_infrastructure_without_image(self):
        result, calls = self.execute("plan_infra")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('Runtime is not deployed', result.stdout)
        self.assertFalse(any('apply' in c for c in calls))

    def test_core_deployment_retains_existing_runtime_endpoint(self):
        result, calls = self.execute("deploy_backend", "--scope", "core", RUNTIME_EXISTS='1')
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual('https://api.test', json.loads((self.root / '.dart-defines/dev.json').read_text())['ILLUSTRATION_API_BASE_URL'])
        self.assertFalse(any('apply' in c and '/runtime' in c[1] for c in calls if c[0]=='terraform'))


if __name__ == "__main__":
    unittest.main()
