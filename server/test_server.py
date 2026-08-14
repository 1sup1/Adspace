from __future__ import annotations

import unittest
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock, patch

from pydantic import ValidationError

from agent import (
    AgentDecision,
    RecommendationRequest,
    WearableSnapshot,
    classify_context,
    recommend,
    safe_profile,
    summarize_signal_window,
)
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

    def test_signal_window_reports_only_consented_trends(self) -> None:
        first = request(heart_rate_bpm=72, hrv_ms=36).snapshot
        latest = request(heart_rate_bpm=78, hrv_ms=31).snapshot
        summary = summarize_signal_window(
            [first, latest], ["heart_rate_bpm", "hrv_ms"]
        )
        self.assertEqual(summary.sample_count, 2)
        self.assertEqual(summary.heart_rate_delta_bpm, 6)
        self.assertEqual(summary.hrv_delta_ms, -5)
        self.assertIsNone(summary.latest_sleep_score)

    def test_agent_window_removes_unconsented_raw_values(self) -> None:
        value = request(sleep_score=10, heart_rate_bpm=120)
        value.consented_fields = ["activity_steps"]
        sanitized = value.consented_signal_window()
        self.assertIsNone(sanitized[0].sleep_score)
        self.assertIsNone(sanitized[0].heart_rate_bpm)
        self.assertEqual(sanitized[0].activity_steps, 3200)

    def test_agent_output_cannot_contain_device_values(self) -> None:
        with self.assertRaises(ValidationError):
            AgentDecision.model_validate(
                {
                    "context": "recovery",
                    "confidence": 0.8,
                    "reason": "최근 동의된 신호 흐름을 바탕으로 회복 환경을 제안합니다.",
                    "evidence": ["최근 신호 4개"],
                    "brightness_percent": 100,
                }
            )


class AgentWorkflowTests(unittest.IsolatedAsyncioTestCase):
    async def test_agent_context_selects_bounded_policy_profile(self) -> None:
        value = request(sleep_score=84, heart_rate_bpm=64, hrv_ms=58)
        value.recent_snapshots = [
            WearableSnapshot.model_validate(
                {
                    **value.snapshot.model_dump(),
                    "id": f"demo-{index}",
                    "heart_rate_bpm": heart_rate,
                }
            )
            for index, heart_rate in enumerate([76, 80, 85, 88], start=1)
        ]
        decision = AgentDecision(
            context="calm",
            confidence=0.82,
            reason="최근 심박 흐름이 높아져 자극을 낮춘 환경을 제안합니다.",
            evidence=["심박 상승 추세"],
        )

        class Result:
            def final_output_as(self, *_: object, **__: object) -> AgentDecision:
                return decision

        with patch("agent.Runner.run", new=AsyncMock(return_value=Result())):
            response = await recommend(value)

        self.assertEqual(response.context, "calm")
        self.assertEqual(response.profile.lighting.brightness_percent, 52)
        self.assertEqual(response.observed_sample_count, 4)
        self.assertEqual(response.generated_by, "agents_sdk")


if __name__ == "__main__":
    unittest.main()
