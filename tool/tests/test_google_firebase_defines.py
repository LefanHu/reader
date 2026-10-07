"""Native OAuth callbacks and Dart identity must use matching registrations."""
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest

spec = importlib.util.spec_from_file_location(
    "google_defines", Path(__file__).resolve().parents[1] / "write_firebase_defines.py"
)
defines = importlib.util.module_from_spec(spec)
spec.loader.exec_module(defines)


class GoogleFirebaseDefinesTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "dev.json"

    def config(self, platform, project="reader", callback=True):
        values = dict(API_KEY=f"{platform}-key", GOOGLE_APP_ID=f"{platform}-app",
                      GCM_SENDER_ID="sender", PROJECT_ID=project)
        if callback:
            values.update(CLIENT_ID=f"{platform}.apps.googleusercontent.com",
                          REVERSED_CLIENT_ID=f"com.googleusercontent.apps.{platform}")
        path = self.root / f"{platform}.plist"
        path.write_bytes(plistlib.dumps(values))
        return path

    def test_generates_matching_private_callbacks_for_both_platforms(self):
        defines.write_defines(self.config("ios"), self.output, "", self.config("macos"),
                              "web.apps.googleusercontent.com")
        values = json.loads(self.output.read_text())
        self.assertEqual("ios.apps.googleusercontent.com", values["FIREBASE_GOOGLE_CLIENT_ID"])
        self.assertEqual("macos.apps.googleusercontent.com", values["FIREBASE_GOOGLE_MACOS_CLIENT_ID"])
        self.assertEqual("web.apps.googleusercontent.com", values["FIREBASE_GOOGLE_SERVER_CLIENT_ID"])
        self.assertNotIn("ILLUSTRATION_API_BASE_URL", values)
        for platform in ["ios", "macos"]:
            path = self.root / f"{platform}.xcconfig"
            self.assertIn(f"GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.{platform}", path.read_text())
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    def test_core_refresh_retains_platform_and_server_identity(self):
        ios = self.config("ios")
        defines.write_defines(ios, self.output, "https://api.example", self.config("macos"), "web-id")
        defines.write_defines(ios, self.output)
        values = json.loads(self.output.read_text())
        self.assertEqual("macos.apps.googleusercontent.com", values["FIREBASE_GOOGLE_MACOS_CLIENT_ID"])
        self.assertEqual("web-id", values["FIREBASE_GOOGLE_SERVER_CLIENT_ID"])
        self.assertEqual("https://api.example", values["ILLUSTRATION_API_BASE_URL"])

    def test_mismatched_callback_does_not_replace_configuration(self):
        ios = self.config("ios")
        defines.write_defines(ios, self.output)
        before = self.output.read_bytes()
        values = plistlib.loads(ios.read_bytes())
        values["REVERSED_CLIENT_ID"] = "wrong.callback"
        ios.write_bytes(plistlib.dumps(values))
        with self.assertRaisesRegex(ValueError, "callback"):
            defines.write_defines(ios, self.output)
        self.assertEqual(before, self.output.read_bytes())

    def test_old_firebase_configuration_without_google_fields_remains_supported(self):
        defines.write_defines(self.config("ios", callback=False), self.output)
        self.assertFalse((self.root / "ios.xcconfig").exists())

    def test_supplied_platform_without_google_config_clears_old_callback(self):
        defines.write_defines(self.config("ios"), self.output, "", self.config("macos"), "web-id")
        defines.write_defines(self.config("ios", callback=False), self.output,
                              "", self.config("macos", callback=False))
        values = json.loads(self.output.read_text())
        self.assertNotIn("FIREBASE_GOOGLE_CLIENT_ID", values)
        self.assertNotIn("FIREBASE_GOOGLE_MACOS_CLIENT_ID", values)
        self.assertFalse((self.root / "ios.xcconfig").exists())
        self.assertFalse((self.root / "macos.xcconfig").exists())

    def test_project_switch_clears_omitted_platform_and_previous_callbacks(self):
        defines.write_defines(self.config("ios"), self.output, "https://old.example",
                              self.config("macos"), "old-server-id")
        defines.write_defines(self.config("ios", project="new", callback=False), self.output)
        values = json.loads(self.output.read_text())
        self.assertNotIn("FIREBASE_GOOGLE_CLIENT_ID", values)
        self.assertNotIn("FIREBASE_GOOGLE_MACOS_CLIENT_ID", values)
        self.assertNotIn("FIREBASE_MACOS_APP_ID", values)
        self.assertNotIn("FIREBASE_GOOGLE_SERVER_CLIENT_ID", values)
        self.assertNotIn("ILLUSTRATION_API_BASE_URL", values)
        self.assertFalse((self.root / "ios.xcconfig").exists())
        self.assertFalse((self.root / "macos.xcconfig").exists())

    def test_omitted_same_project_platform_reconstructs_matching_callback(self):
        defines.write_defines(self.config("ios"), self.output, "", self.config("macos"))
        (self.root / "macos.xcconfig").write_text("GOOGLE_REVERSED_CLIENT_ID = stale")
        defines.write_defines(self.config("ios", callback=False), self.output)
        self.assertIn("com.googleusercontent.apps.macos", (self.root / "macos.xcconfig").read_text())
        self.assertFalse((self.root / "ios.xcconfig").exists())

    def test_mixed_projects_are_rejected_before_native_configuration_is_written(self):
        with self.assertRaisesRegex(ValueError, "share a project"):
            defines.write_defines(self.config("ios"), self.output, "", self.config("macos", project="other"))
        self.assertFalse(self.output.exists())
        self.assertFalse((self.root / "ios.xcconfig").exists())


if __name__ == "__main__":
    unittest.main()
