"""An installer must not advertise builds with unusable or expired provisioning."""
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "ios_ota", Path(__file__).resolve().parents[1] / "build_ios_ota.py"
)
ota = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ota)


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


if __name__ == "__main__":
    unittest.main()
