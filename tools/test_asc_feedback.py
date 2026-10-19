"""Offline tests for tools/asc_feedback.py (no network, throwaway EC key)."""

import io
import json
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc_feedback as asc  # noqa: E402


def write_test_key(directory: Path) -> Path:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec

    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption())
    path = directory / "AuthKey_TESTKEY123.p8"
    path.write_bytes(pem)
    return path


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeOpener:
    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append(request)
        for prefix, reply in self.routes:
            if request.full_url.startswith(prefix):
                if isinstance(reply, Exception):
                    raise reply
                return FakeResponse(reply if isinstance(reply, bytes) else json.dumps(reply).encode())
        raise AssertionError(f"unexpected URL {request.full_url}")


class AscFeedbackTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.key_path = write_test_key(self.dir)
        self.config = {"key_id": "TESTKEY123", "issuer": "issuer-uuid", "key_path": str(self.key_path),
                       "app_id": "6824194188"}

    def tearDown(self):
        self.tmp.cleanup()

    def test_missing_env_is_config_error(self):
        with self.assertRaises(asc.ConfigError):
            asc.load_config({})

    def test_explicit_key_path_and_default_app(self):
        config = asc.load_config({"ASC_KEY_ID": "TESTKEY123", "ASC_ISSUER_ID": "i",
                                  "ASC_PRIVATE_KEY_PATH": str(self.key_path)})
        self.assertEqual(config["app_id"], "6824194188")

    def test_token_claims_follow_apple_rules(self):
        import jwt
        token = asc.make_token(self.config, now=1_700_000_000)
        header = jwt.get_unverified_header(token)
        claims = jwt.decode(token, options={"verify_signature": False})
        self.assertEqual(header["alg"], "ES256")
        self.assertEqual(header["kid"], "TESTKEY123")
        self.assertEqual(claims["aud"], "appstoreconnect-v1")
        self.assertEqual(claims["iss"], "issuer-uuid")
        self.assertLessEqual(claims["exp"] - claims["iat"], 20 * 60)

    def test_fetch_saves_screenshot_and_crash_without_auth_on_image_host(self):
        shot = {"id": "SHOT1", "type": "betaFeedbackScreenshotSubmissions",
                "attributes": {"createdDate": "2026-10-19T10:11:12Z", "comment": "要約が遅い", "deviceModel": "iPhone15,4",
                               "osVersion": "26.1", "batteryPercentage": 80, "appUptimeInMilliseconds": 125000,
                               "screenshots": [{"url": "https://images.example/abc.png", "width": 1, "height": 1}]},
                "relationships": {"build": {"data": {"type": "builds", "id": "B1"}}}}
        crash = {"id": "CRASH1", "type": "betaFeedbackCrashSubmissions",
                 "attributes": {"createdDate": "2026-10-19T11:00:00Z", "comment": "落ちた"}}
        opener = FakeOpener([
            (f"{asc.API}/v1/apps/6824194188/betaFeedbackScreenshotSubmissions",
             {"data": [shot], "included": [{"type": "builds", "id": "B1", "attributes": {"version": "7"}}]}),
            (f"{asc.API}/v1/apps/6824194188/betaFeedbackCrashSubmissions", {"data": [crash]}),
            (f"{asc.API}/v1/betaFeedbackCrashSubmissions/CRASH1/crashLog",
             {"data": {"attributes": {"logText": "Thread 0 crashed"}}}),
            ("https://images.example/", b"PNGDATA"),
        ])
        out = self.dir / "out"
        saved = asc.fetch(self.config, limit=5, out_dir=out, opener=opener)
        self.assertEqual(len(saved), 2)
        shot_dir = next(p for p in saved if "_screenshot_" in p.name)
        crash_dir = next(p for p in saved if "_crash_" in p.name)
        md = (shot_dir / "feedback.md").read_text(encoding="utf-8")
        self.assertIn("要約が遅い", md)
        self.assertIn("ビルド: 7", md)
        self.assertIn("2分5秒", md)
        self.assertEqual((shot_dir / "screenshot-1.png").read_bytes(), b"PNGDATA")
        self.assertEqual((crash_dir / "crash.log").read_text(encoding="utf-8"), "Thread 0 crashed")
        image_request = next(r for r in opener.requests if r.full_url.startswith("https://images.example/"))
        self.assertIsNone(image_request.get_header("Authorization"))
        api_requests = [r for r in opener.requests if r.full_url.startswith(asc.API)]
        self.assertTrue(all(r.get_header("Authorization", "").startswith("Bearer ") for r in api_requests))

    def test_second_fetch_skips_existing(self):
        shot = {"id": "SHOT1", "attributes": {"createdDate": "2026-10-19T10:11:12Z"}}
        routes = [(f"{asc.API}/v1/apps/6824194188/betaFeedbackScreenshotSubmissions", {"data": [shot]}),
                  (f"{asc.API}/v1/apps/6824194188/betaFeedbackCrashSubmissions", {"data": []})]
        out = self.dir / "out"
        self.assertEqual(len(asc.fetch(self.config, 5, out, FakeOpener(routes))), 1)
        self.assertEqual(asc.fetch(self.config, 5, out, FakeOpener(routes)), [])

    def test_http_error_message_has_no_token(self):
        error = urllib.error.HTTPError(asc.API, 401, "Unauthorized", {},
                                       io.BytesIO(b'{"errors":[{"title":"NOT_AUTHORIZED","detail":"bad key"}]}'))
        opener = FakeOpener([(asc.API, error)])
        with self.assertRaises(asc.ApiError) as context:
            asc.api_get("/v1/apps/1", "SECRET.TOKEN.VALUE", opener=opener)
        self.assertEqual(context.exception.status, 401)
        self.assertNotIn("SECRET", str(context.exception))


if __name__ == "__main__":
    unittest.main()
