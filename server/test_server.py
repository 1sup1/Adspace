from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta

from agent import RecommendationRequest, classify_context, safe_profile
from main import SessionStore


def request(**overrides: object) -> RecommendationRequest:
    snapshot = {
        "id": "demo",
        "source": "demo",
        "captured_at": "2026-08-14T10:00:00Z",
        "sleep_score": 52,
        "activity_steps": 3200,
        "heart_rate_bpm": 78,
        "hrv_ms": 31,
        "time_of_day": "evening",
        **overrides,
    }
    return RecommendationRequest.model_validate(
        {
            "snapshot": snapshot,
            "consented_fields": ["sleep_score", "activity_steps", "heart_rate_bpm", "hrv_ms"],
            "adjustment": {"brightness_delta": 7},
        }
    )


class PolicyTests(unittest.TestCase):
    def test_scenarios_are_distinct_and_adjustment_is_applied(self) -> None:
        recovery = request()
        focus = request(sleep_score=84, heart_rate_bpm=64, hrv_ms=58, time_of_day="morning")
        calm = request(sleep_score=74, heart_rate_bpm=88, hrv_ms=25)
        self.assertEqual(classify_context(recovery), "recovery")
        self.assertEqual(classify_context(focus), "focus")
        self.assertEqual(classify_context(calm), "calm")
        self.assertEqual(safe_profile("recovery", recovery.adjustment).lighting.brightness_percent, 42)

    def test_unconsented_metric_cannot_change_context(self) -> None:
        value = request(sleep_score=10)
        value.consented_fields = ["activity_steps", "heart_rate_bpm"]
        self.assertEqual(classify_context(value), "focus")

    def test_space_session_excludes_private_and_unsupported_values(self) -> None:
        profile = safe_profile("recovery", request().adjustment)
        store = SessionStore()
        session = store.create(profile, 900)
        self.assertEqual(session["shared_biometric_count"], 0)
        self.assertNotIn("sound_preset", session["execution"])
        self.assertIn("lighting.color_temperature_k", session["excluded"])

        status, checked_out = store.command(session["session_id"], "checkout")
        self.assertEqual(status, 200)
        self.assertIsNone(checked_out["execution"])
        self.assertTrue(checked_out["profile_copy_deleted"])
        self.assertEqual(store.command(session["session_id"], "apply")[0], 410)

    def test_expired_session_is_rejected(self) -> None:
        store = SessionStore()
        session = store.create(safe_profile("focus", request().adjustment), 900)
        store.sessions[session["session_id"]]["expires_at"] = (
            datetime.now(UTC) - timedelta(seconds=1)
        ).isoformat()
        self.assertEqual(store.command(session["session_id"], "apply")[0], 410)


if __name__ == "__main__":
    unittest.main()
