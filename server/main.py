from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from typing import Literal
from uuid import uuid4

from pydantic import ValidationError

from agent import EnvironmentProfile, RecommendationRequest, recommend


SPACE = {
    "space_id": "hotel-demo-room",
    "lighting": {
        "supported": True,
        "brightness_range": [20, 100],
        "color_temperature_supported": False,
    },
    "temperature": {"supported": True, "range_c": [20, 24]},
    "sound": {"supported": False},
    "defaults": {"brightness_percent": 70, "temperature_c": 22},
}


class SessionStore:
    def __init__(self) -> None:
        self.sessions: dict[str, dict] = {}
        self.lock = Lock()

    def create(self, profile: EnvironmentProfile, ttl_seconds: int) -> dict:
        session_id = f"session-{uuid4().hex[:8]}"
        brightness = max(20, min(100, profile.lighting.brightness_percent))
        temperature = max(20, min(24, profile.temperature_c))
        record = {
            "session_id": session_id,
            "space_id": SPACE["space_id"],
            "status": "pending_approval",
            "execution": {
                "lighting": {"brightness_percent": brightness},
                "temperature_c": temperature,
            },
            "excluded": ["lighting.color_temperature_k", "sound_preset"],
            "expires_at": (datetime.now(UTC) + timedelta(seconds=ttl_seconds)).isoformat(),
            "shared_biometric_count": 0,
            "profile_copy_deleted": False,
        }
        with self.lock:
            self.sessions[session_id] = record
        return record.copy()

    def command(self, session_id: str, action: str) -> tuple[int, dict]:
        with self.lock:
            record = self.sessions.get(session_id)
            if record is None:
                return 404, {"error": "session_not_found"}
            expired = datetime.now(UTC) >= datetime.fromisoformat(record["expires_at"])
            if expired or record["status"] == "expired":
                record.update(status="expired", execution=None, profile_copy_deleted=True)
                return 410, {"error": "session_expired", **record}

            if action == "apply":
                record["status"] = "active"
                results = {"lighting": "applied", "temperature": "applied", "sound": "skipped"}
            elif action == "stop":
                record["status"] = "stopped"
                results = {"lighting": "stopped", "temperature": "stopped", "sound": "skipped"}
            elif action == "restore":
                record["status"] = "restored"
                results = {"lighting": "restored", "temperature": "restored", "sound": "skipped"}
            elif action == "checkout":
                record.update(status="expired", execution=None, profile_copy_deleted=True)
                results = {"lighting": "restored", "temperature": "restored", "sound": "skipped"}
            else:
                return 422, {"error": "invalid_action"}
            return 200, {**record, "results": results}


STORE = SessionStore()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        print(f"{self.command} {self.path} - {format % args}")

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def read_json(self) -> dict:
        length = int(self.headers.get("Content-Length", "0"))
        return json.loads(self.rfile.read(length) or b"{}")

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "model": os.getenv("OPENAI_MODEL", "gpt-5.6-luna")})
        elif self.path == "/v1/spaces/hotel-demo-room":
            self.send_json(200, SPACE)
        else:
            self.send_json(404, {"error": "not_found"})

    def do_POST(self) -> None:
        try:
            body = self.read_json()
            if self.path == "/v1/recommendations":
                request = RecommendationRequest.model_validate(body)
                response = asyncio.run(recommend(request))
                self.send_json(200, response.model_dump(mode="json"))
                return

            if self.path == "/v1/spaces/hotel-demo-room/sessions":
                allowed = {"profile", "ttl_seconds"}
                if set(body) - allowed or "profile" not in body:
                    self.send_json(422, {"error": "invalid_or_private_fields"})
                    return
                profile = EnvironmentProfile.model_validate(body["profile"])
                ttl = max(60, min(3600, int(body.get("ttl_seconds", 900))))
                self.send_json(201, STORE.create(profile, ttl))
                return

            match = re.fullmatch(r"/v1/sessions/([^/]+)/commands", self.path)
            if match:
                action: Literal["apply", "stop", "restore", "checkout"] | str = body.get("action", "")
                status, response = STORE.command(match.group(1), action)
                self.send_json(status, response)
                return
            self.send_json(404, {"error": "not_found"})
        except (ValidationError, ValueError, json.JSONDecodeError) as error:
            self.send_json(422, {"error": "invalid_request", "detail": str(error)})


def sample_request() -> RecommendationRequest:
    return RecommendationRequest.model_validate(
        {
            "snapshot": {
                "id": "demo-recovery-001",
                "source": "demo",
                "captured_at": "2026-08-14T10:00:00Z",
                "sleep_score": 52,
                "activity_steps": 3200,
                "heart_rate_bpm": 78,
                "hrv_ms": 31,
                "time_of_day": "evening",
            },
            "consented_fields": ["sleep_score", "activity_steps", "heart_rate_bpm", "hrv_ms"],
            "adjustment": {"brightness_delta": 0, "temperature_delta_c": 0},
        }
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--smoke", action="store_true")
    args = parser.parse_args()
    if args.smoke:
        result = asyncio.run(recommend(sample_request()))
        print(result.model_dump_json(indent=2))
        return
    port = int(os.getenv("PORT", "8000"))
    print(f"Adaptive Space server listening on http://127.0.0.1:{port}")
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
