"""An installer must not advertise builds with unusable or expired provisioning."""
from datetime import datetime, timedelta, timezone
import plistlib
import unittest

from support import load_tool

ota = load_tool("build_ios_ota")


class IosOtaTests(unittest.TestCase):
    def profile(self):
        return {
            "ProvisionedDevices": ["fixture-device"],
            "Entitlements": {"get-task-allow": False},
            "ExpirationDate": datetime.now(timezone.utc) + timedelta(days=1),
        }

    def test_development_signing_is_not_advertised_as_distribution(self):
        profile = self.profile()
        profile["Entitlements"]["get-task-allow"] = True
        with self.assertRaisesRegex(ValueError, "Ad Hoc"):
            ota.validate_profile(profile)

    def test_app_store_and_enterprise_profiles_cannot_use_registered_device_installer(self):
        store = self.profile()
        del store["ProvisionedDevices"]
        enterprise = self.profile()
        enterprise["ProvisionsAllDevices"] = True
        for profile in [store, enterprise]:
            with self.subTest(profile=profile), self.assertRaisesRegex(ValueError, "Ad Hoc"):
                ota.validate_profile(profile)

    def test_recently_expired_utc_plist_date_is_rejected(self):
        profile = self.profile()
        # plistlib decodes UTC dates without tzinfo; treating them as local time
        # incorrectly extends profile validity on a Mac west of UTC.
        profile["ExpirationDate"] = (datetime.now(timezone.utc) - timedelta(minutes=1)).replace(tzinfo=None)
        with self.assertRaisesRegex(ValueError, "expired"):
            ota.validate_profile(profile)

    def test_qr_destination_rejects_credentials_and_non_https_urls(self):
        for url in ["http://reader.example", "https://user:secret@reader.example",
                    "https://reader.example?token=secret", "https://reader.example/#install"]:
            with self.subTest(url=url), self.assertRaisesRegex(ValueError, "HTTPS"):
                ota.https_base(url)

    def test_build_number_increments_without_touching_the_version_name(self):
        pubspec = "name: reader\nversion: 1.2.3+9\ndependencies:\n  version: 4.5.6+7\n"
        self.assertEqual(ota.current_build_number(pubspec), 9)
        self.assertEqual(
            ota.with_build_number(pubspec, 10),
            "name: reader\nversion: 1.2.3+10\ndependencies:\n  version: 4.5.6+7\n",
        )

    def test_pubspec_without_a_build_number_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "version"):
            ota.current_build_number("version: 1.0.0\n")

    def test_installer_address_is_identical_for_every_build(self):
        info = {"CFBundleIdentifier": "app.reader", "CFBundleVersion": "3",
                "CFBundleShortVersionString": "1.0.0"}
        first = ota.installer_contents(info, "https://mac.ts.net:8443", "a" * 32)
        second = ota.installer_contents(info, "https://mac.ts.net:8443/", "b" * 32)
        self.assertEqual(first[0], "https://mac.ts.net:8443/")
        self.assertEqual(first[0], second[0])
        manifest = plistlib.loads(second[1])
        self.assertEqual(
            manifest["items"][0]["assets"][0]["url"],
            "https://mac.ts.net:8443/" + "b" * 32 + "/reader.ipa",
        )
        self.assertIn("https%3A%2F%2Fmac.ts.net%3A8443%2Fmanifest.plist", second[2])


if __name__ == "__main__":
    unittest.main()
