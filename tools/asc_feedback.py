#!/usr/bin/env python3
"""Fetch TestFlight beta feedback (screenshots + comments, crashes) via the App Store Connect API.

Saves each submission under .feedback/<date>_<kind>_<id>/ (git-ignored):
  feedback.md      comment, device, OS, build, battery, connection, ...
  screenshot-N.*   downloaded images (signed URLs; no auth header is sent to them)
  crash.log        crash log text (crash submissions only)

Credentials never live in the repo:
  ASC_KEY_ID              App Store Connect API key ID (role Developer is enough)
  ASC_ISSUER_ID           Issuer ID from Users and Access > Integrations
  ASC_PRIVATE_KEY_PATH    optional; default ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
  ASC_APP_ID              optional; default 6824194188 (Pocket Agent)

Usage:
  python tools/asc_feedback.py            # fetch new submissions (newest 20 of each kind)
  python tools/asc_feedback.py --limit 50
  python tools/asc_feedback.py --check    # only verify credentials (lists nothing)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"
DEFAULT_APP_ID = "6824194188"
OUT_DIR = Path(__file__).resolve().parent.parent / ".feedback"
TOKEN_LIFETIME_SECONDS = 15 * 60  # Apple rejects tokens living longer than 20 minutes


class ConfigError(Exception):
    pass


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


def load_config(env: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(os.environ if env is None else env)
    key_id = env.get("ASC_KEY_ID", "").strip()
    issuer = env.get("ASC_ISSUER_ID", "").strip()
    if not key_id or not issuer:
        raise ConfigError("ASC_KEY_ID と ASC_ISSUER_ID を環境変数に設定してください。")
    default_path = Path.home() / ".appstoreconnect" / "private_keys" / f"AuthKey_{key_id}.p8"
    key_path = Path(env.get("ASC_PRIVATE_KEY_PATH", "").strip() or default_path)
    if not key_path.is_file():
        raise ConfigError(f"秘密鍵ファイルが見つかりません: {key_path}")
    return {
        "key_id": key_id,
        "issuer": issuer,
        "key_path": str(key_path),
        "app_id": env.get("ASC_APP_ID", "").strip() or DEFAULT_APP_ID,
    }


def make_token(config: dict[str, str], now: float | None = None) -> str:
    import jwt  # PyJWT (with cryptography for ES256)

    issued = int(now if now is not None else time.time())
    payload = {
        "iss": config["issuer"],
        "iat": issued,
        "exp": issued + TOKEN_LIFETIME_SECONDS,
        "aud": "appstoreconnect-v1",
    }
    headers = {"kid": config["key_id"], "typ": "JWT"}
    private_key = Path(config["key_path"]).read_text(encoding="utf-8")
    return jwt.encode(payload, private_key, algorithm="ES256", headers=headers)


def api_get(path: str, token: str, params: dict[str, str] | None = None, opener=urllib.request.urlopen) -> dict:
    url = f"{API}{path}"
    if params:
        url += "?" + urllib.parse.urlencode(params, safe="[],")
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with opener(request, timeout=30) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as error:
        raise ApiError(error.code, _apple_error_text(error)) from None


def _apple_error_text(error: urllib.error.HTTPError) -> str:
    # Apple's error bodies carry only code/title/detail; never the token.
    try:
        body = json.loads(error.read().decode("utf-8"))
        first = (body.get("errors") or [{}])[0]
        return f"{first.get('title', '')} {first.get('detail', '')}".strip() or error.reason
    except Exception:
        return str(error.reason)


def download(url: str, destination: Path, opener=urllib.request.urlopen) -> None:
    # Signed URL: deliberately no Authorization header (do not leak the JWT to another host).
    with opener(urllib.request.Request(url), timeout=60) as response:
        destination.write_bytes(response.read())


def build_versions(document: dict) -> dict[str, str]:
    versions = {}
    for item in document.get("included", []) or []:
        if item.get("type") == "builds":
            versions[item["id"]] = (item.get("attributes") or {}).get("version", "?")
    return versions


def folder_name(kind: str, item: dict) -> str:
    created = ((item.get("attributes") or {}).get("createdDate") or "unknown")[:19]
    stamp = created.replace(":", "").replace("-", "").replace("T", "-")
    return f"{stamp}_{kind}_{item['id'][:12]}"


def render_markdown(kind: str, item: dict, build_version: str | None) -> str:
    attrs = item.get("attributes") or {}
    lines = [
        f"# TestFlight {('フィードバック' if kind == 'screenshot' else 'クラッシュ')} {item['id']}",
        "",
        f"- 日時: {attrs.get('createdDate', '?')}",
        f"- ビルド: {build_version or '?'}",
        f"- 端末: {attrs.get('deviceModel', '?')} / {attrs.get('osVersion', '?')} / {attrs.get('locale', '?')}",
        f"- 電池: {attrs.get('batteryPercentage', '?')}% / 回線: {attrs.get('connectionType', '?')}",
        f"- 起動からの時間: {_ms_to_text(attrs.get('appUptimeInMilliseconds'))}",
        f"- 空き容量: {_bytes_to_gb(attrs.get('diskBytesAvailable'))} / {_bytes_to_gb(attrs.get('diskBytesTotal'))}",
        "",
        "## コメント",
        "",
        (attrs.get("comment") or "（なし）"),
        "",
    ]
    return "\n".join(lines)


def _ms_to_text(value) -> str:
    if not isinstance(value, int):
        return "?"
    seconds = value // 1000
    return f"{seconds // 60}分{seconds % 60}秒"


def _bytes_to_gb(value) -> str:
    if not isinstance(value, int):
        return "?"
    return f"{value / 1e9:.1f} GB"


def save_submission(kind: str, item: dict, versions: dict[str, str], token: str, out_dir: Path,
                    opener=urllib.request.urlopen) -> Path | None:
    target = out_dir / folder_name(kind, item)
    if target.exists():
        return None
    target.mkdir(parents=True)
    build_id = (((item.get("relationships") or {}).get("build") or {}).get("data") or {}).get("id")
    (target / "feedback.md").write_text(render_markdown(kind, item, versions.get(build_id)), encoding="utf-8")
    for index, shot in enumerate((item.get("attributes") or {}).get("screenshots") or [], start=1):
        url = shot.get("url")
        if not url:
            continue
        suffix = Path(urllib.parse.urlparse(url).path).suffix or ".jpg"
        try:
            download(url, target / f"screenshot-{index}{suffix}", opener=opener)
        except Exception as error:  # an expired URL should not stop the run
            (target / f"screenshot-{index}.error.txt").write_text(str(error), encoding="utf-8")
    if kind == "crash":
        try:
            log = api_get(f"/v1/betaFeedbackCrashSubmissions/{item['id']}/crashLog", token, opener=opener)
            text = ((log.get("data") or {}).get("attributes") or {}).get("logText") or ""
            (target / "crash.log").write_text(text, encoding="utf-8")
        except ApiError as error:
            (target / "crash.error.txt").write_text(str(error), encoding="utf-8")
    return target


def fetch(config: dict[str, str], limit: int, out_dir: Path = OUT_DIR, opener=urllib.request.urlopen) -> list[Path]:
    token = make_token(config)
    out_dir.mkdir(parents=True, exist_ok=True)
    saved: list[Path] = []
    for kind, path in (
        ("screenshot", f"/v1/apps/{config['app_id']}/betaFeedbackScreenshotSubmissions"),
        ("crash", f"/v1/apps/{config['app_id']}/betaFeedbackCrashSubmissions"),
    ):
        document = api_get(path, token, {"sort": "-createdDate", "limit": str(limit), "include": "build"},
                           opener=opener)
        versions = build_versions(document)
        for item in document.get("data", []) or []:
            target = save_submission(kind, item, versions, token, out_dir, opener=opener)
            if target is not None:
                saved.append(target)
    return saved


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", type=int, default=20)
    parser.add_argument("--check", action="store_true", help="credentials only")
    args = parser.parse_args(argv)
    try:
        config = load_config()
        if args.check:
            token = make_token(config)
            app = api_get(f"/v1/apps/{config['app_id']}", token, {"fields[apps]": "name,bundleId"})
            attrs = (app.get("data") or {}).get("attributes") or {}
            print(f"OK: {attrs.get('name')} ({attrs.get('bundleId')})")
            return 0
        saved = fetch(config, args.limit)
    except ConfigError as error:
        print(f"設定エラー: {error}", file=sys.stderr)
        return 2
    except ApiError as error:
        print(f"App Store Connect API エラー: {error}", file=sys.stderr)
        return 1
    if not saved:
        print("新しいフィードバックはありません。")
    for path in saved:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
