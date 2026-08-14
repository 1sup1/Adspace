from __future__ import annotations

import json
import os
from typing import Literal
from uuid import uuid4

from agents import Agent, ModelSettings, RunConfig, Runner
from pydantic import BaseModel, ConfigDict, Field


Context = Literal["recovery", "focus", "calm"]
Metric = Literal["sleep_score", "activity_steps", "heart_rate_bpm", "hrv_ms"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class WearableSnapshot(StrictModel):
    id: str
    source: Literal["demo"]
    captured_at: str
    sleep_score: int | None = Field(default=None, ge=0, le=100)
    activity_steps: int | None = Field(default=None, ge=0)
    heart_rate_bpm: int | None = Field(default=None, ge=30, le=220)
    hrv_ms: int | None = Field(default=None, ge=0)
    time_of_day: Literal["morning", "afternoon", "evening"]


class Adjustment(StrictModel):
    brightness_delta: int = Field(default=0, ge=-50, le=50)
    temperature_delta_c: float = Field(default=0, ge=-3, le=3)
    sound_preset: Literal["calm", "focus", "silence"] | None = None


class RecommendationRequest(StrictModel):
    snapshot: WearableSnapshot
    consented_fields: list[Metric]
    adjustment: Adjustment = Adjustment()

    def consented_metrics(self) -> dict[str, int]:
        return {
            name: value
            for name in self.consented_fields
            if (value := getattr(self.snapshot, name)) is not None
        }


class LightingProfile(StrictModel):
    brightness_percent: int = Field(ge=10, le=100)
    color_temperature_k: int = Field(ge=2200, le=6500)


class EnvironmentProfile(StrictModel):
    lighting: LightingProfile
    temperature_c: float = Field(ge=18, le=27)
    sound_preset: Literal["calm", "focus", "silence"]


class RecommendationResponse(StrictModel):
    profile_id: str
    context: Context
    confidence: float = Field(ge=0, le=1)
    profile: EnvironmentProfile
    reason: str
    requires_confirmation: bool
    input_source: Literal["demo"]
    generated_by: Literal["agents_sdk", "deterministic_fallback"]


class AgentBriefing(StrictModel):
    reason: str = Field(min_length=10, max_length=180)


BRIEFING_AGENT = Agent(
    name="Adaptive Space briefing agent",
    model=os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
    instructions=(
        "당신은 웰니스 공간 추천 설명 에이전트입니다. 서버가 이미 확정한 context와 "
        "동의된 더미 요약값만 근거로, 한국어 한 문장 추천 이유를 작성하세요. "
        "질환·감정·스트레스를 진단하거나 단정하지 말고, 입력되지 않은 값을 추측하지 마세요. "
        "기기 실행값은 결정하거나 변경하지 마세요."
    ),
    model_settings=ModelSettings(
        reasoning={"effort": "none"},
        verbosity="low",
        store=False,
    ),
    output_type=AgentBriefing,
)


BASE_PROFILES: dict[Context, EnvironmentProfile] = {
    "recovery": EnvironmentProfile(
        lighting=LightingProfile(brightness_percent=35, color_temperature_k=2700),
        temperature_c=23,
        sound_preset="calm",
    ),
    "focus": EnvironmentProfile(
        lighting=LightingProfile(brightness_percent=75, color_temperature_k=4500),
        temperature_c=21,
        sound_preset="focus",
    ),
    "calm": EnvironmentProfile(
        lighting=LightingProfile(brightness_percent=45, color_temperature_k=3000),
        temperature_c=22,
        sound_preset="silence",
    ),
}

FALLBACK_REASONS: dict[Context, str] = {
    "recovery": "동의한 수면 요약값과 시간대를 바탕으로 편안한 회복 환경을 제안합니다.",
    "focus": "동의한 활동 요약값과 시간대를 바탕으로 선명한 집중 환경을 제안합니다.",
    "calm": "동의한 심박·HRV 요약값을 바탕으로 자극을 낮춘 안정 환경을 제안합니다.",
}


def classify_context(request: RecommendationRequest) -> Context:
    metrics = request.consented_metrics()
    if (sleep := metrics.get("sleep_score")) is not None and sleep < 65:
        return "recovery"
    if (heart_rate := metrics.get("heart_rate_bpm")) is not None and heart_rate >= 82:
        return "calm"
    if (hrv := metrics.get("hrv_ms")) is not None and hrv <= 28:
        return "calm"
    return "focus"


def safe_profile(context: Context, adjustment: Adjustment) -> EnvironmentProfile:
    base = BASE_PROFILES[context]
    brightness = max(10, min(100, base.lighting.brightness_percent + adjustment.brightness_delta))
    temperature = max(18, min(27, base.temperature_c + adjustment.temperature_delta_c))
    return EnvironmentProfile(
        lighting=LightingProfile(
            brightness_percent=brightness,
            color_temperature_k=base.lighting.color_temperature_k,
        ),
        temperature_c=round(temperature, 1),
        sound_preset=adjustment.sound_preset or base.sound_preset,
    )


async def recommend(request: RecommendationRequest) -> RecommendationResponse:
    metrics = request.consented_metrics()
    context = classify_context(request)
    profile = safe_profile(context, request.adjustment)
    confidence = min(0.86, 0.46 + len(metrics) * 0.10)
    generated_by: Literal["agents_sdk", "deterministic_fallback"] = "agents_sdk"

    prompt = json.dumps(
        {
            "fixed_context": context,
            "consented_demo_metrics": metrics,
            "time_of_day": request.snapshot.time_of_day,
        },
        ensure_ascii=False,
    )
    try:
        result = await Runner.run(
            BRIEFING_AGENT,
            prompt,
            max_turns=1,
            run_config=RunConfig(
                workflow_name="Adaptive Space recommendation",
                trace_include_sensitive_data=False,
            ),
        )
        reason = result.final_output.reason
    except Exception as error:
        # ponytail: offline fallback keeps the demo usable; surface full telemetry when production begins.
        print(f"Agents SDK fallback: {type(error).__name__}")
        reason = FALLBACK_REASONS[context]
        generated_by = "deterministic_fallback"

    return RecommendationResponse(
        profile_id=f"profile-{uuid4().hex[:8]}",
        context=context,
        confidence=confidence,
        profile=profile,
        reason=reason,
        requires_confirmation=len(metrics) < 2 or confidence < 0.65,
        input_source="demo",
        generated_by=generated_by,
    )
