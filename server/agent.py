from __future__ import annotations

import json
import os
from typing import Literal
from uuid import uuid4

from agents import Agent, ModelSettings, RunConfig, Runner, function_tool
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
    recent_snapshots: list[WearableSnapshot] = Field(default_factory=list, max_length=12)
    consented_fields: list[Metric]
    adjustment: Adjustment = Adjustment()

    def consented_metrics(self) -> dict[str, int]:
        return {
            name: value
            for name in self.consented_fields
            if (value := getattr(self.snapshot, name)) is not None
        }

    def signal_window(self) -> list[WearableSnapshot]:
        return self.recent_snapshots or [self.snapshot]

    def consented_signal_window(self) -> list[WearableSnapshot]:
        consent = set(self.consented_fields)
        hidden = {
            metric: None
            for metric in ("sleep_score", "activity_steps", "heart_rate_bpm", "hrv_ms")
            if metric not in consent
        }
        return [sample.model_copy(update=hidden) for sample in self.signal_window()]


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
    observed_sample_count: int = Field(ge=1, le=12)
    evidence: list[str] = Field(default_factory=list, max_length=3)


class SignalSummary(StrictModel):
    sample_count: int = Field(ge=1, le=12)
    latest_sleep_score: int | None = None
    activity_steps_delta: int | None = None
    average_heart_rate_bpm: float | None = None
    heart_rate_delta_bpm: int | None = None
    average_hrv_ms: float | None = None
    hrv_delta_ms: int | None = None
    time_of_day: Literal["morning", "afternoon", "evening"]


class AgentDecision(StrictModel):
    context: Context
    confidence: float = Field(ge=0, le=1)
    reason: str = Field(min_length=10, max_length=180)
    evidence: list[str] = Field(min_length=1, max_length=3)


def summarize_signal_window(
    samples: list[WearableSnapshot], consented_fields: list[Metric]
) -> SignalSummary:
    consent = set(consented_fields)

    def values(metric: Metric) -> list[int]:
        if metric not in consent:
            return []
        return [value for sample in samples if (value := getattr(sample, metric)) is not None]

    sleep = values("sleep_score")
    activity = values("activity_steps")
    heart_rate = values("heart_rate_bpm")
    hrv = values("hrv_ms")
    return SignalSummary(
        sample_count=len(samples),
        latest_sleep_score=sleep[-1] if sleep else None,
        activity_steps_delta=activity[-1] - activity[0] if len(activity) > 1 else None,
        average_heart_rate_bpm=round(sum(heart_rate) / len(heart_rate), 1) if heart_rate else None,
        heart_rate_delta_bpm=heart_rate[-1] - heart_rate[0] if len(heart_rate) > 1 else None,
        average_hrv_ms=round(sum(hrv) / len(hrv), 1) if hrv else None,
        hrv_delta_ms=hrv[-1] - hrv[0] if len(hrv) > 1 else None,
        time_of_day=samples[-1].time_of_day,
    )


@function_tool
def analyze_signal_window(
    samples: list[WearableSnapshot], consented_fields: list[Metric]
) -> SignalSummary:
    """동의된 최근 생체 신호 창을 환경 조율용 추세로 요약합니다.

    Args:
        samples: 시간순으로 정렬된 최근 웨어러블 샘플입니다.
        consented_fields: 사용자가 분석에 동의한 측정 항목입니다.
    """
    return summarize_signal_window(samples, consented_fields)


ENVIRONMENT_AGENT = Agent(
    name="Adaptive Space environment coordinator",
    model=os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
    instructions=(
        "당신은 실시간 웨어러블 신호를 환경 맥락으로 변환하는 웰니스 공간 조율 에이전트입니다. "
        "반드시 analyze_signal_window 도구를 한 번 호출해 동의된 최근 신호의 수준과 변화 추세를 확인하세요. "
        "도구 결과만 근거로 recovery, focus, calm 중 하나와 신뢰도를 결정하고, 근거를 짧게 남기세요. "
        "질환·감정·스트레스를 진단하거나 단정하지 말고, 입력되지 않은 값을 추측하지 마세요. "
        "조명·온도·사운드 실행값은 결정하거나 기기를 직접 제어하지 마세요."
    ),
    tools=[analyze_signal_window],
    model_settings=ModelSettings(
        tool_choice="analyze_signal_window",
        parallel_tool_calls=False,
        reasoning={"effort": "none"},
        verbosity="low",
        store=False,
    ),
    output_type=AgentDecision,
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


def fallback_decision(request: RecommendationRequest) -> AgentDecision:
    context = classify_context(request)
    summary = summarize_signal_window(request.signal_window(), request.consented_fields)
    evidence = [f"최근 신호 {summary.sample_count}개"]
    if summary.latest_sleep_score is not None:
        evidence.append(f"수면 점수 {summary.latest_sleep_score}")
    elif summary.average_heart_rate_bpm is not None:
        evidence.append(f"평균 심박 {summary.average_heart_rate_bpm:g}")
    return AgentDecision(
        context=context,
        confidence=min(0.86, 0.46 + len(request.consented_metrics()) * 0.10),
        reason=FALLBACK_REASONS[context],
        evidence=evidence[:3],
    )


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
    decision = fallback_decision(request)
    generated_by: Literal["agents_sdk", "deterministic_fallback"] = "agents_sdk"

    prompt = json.dumps(
        {
            "samples": [
                sample.model_dump(mode="json") for sample in request.consented_signal_window()
            ],
            "consented_fields": request.consented_fields,
        },
        ensure_ascii=False,
    )
    try:
        result = await Runner.run(
            ENVIRONMENT_AGENT,
            prompt,
            max_turns=3,
            run_config=RunConfig(
                workflow_name="Adaptive Space live environment coordination",
                trace_include_sensitive_data=False,
            ),
        )
        decision = result.final_output_as(AgentDecision, raise_if_incorrect_type=True)
    except Exception as error:
        # ponytail: offline fallback keeps the demo usable; surface full telemetry when production begins.
        print(f"Agents SDK fallback: {type(error).__name__}")
        generated_by = "deterministic_fallback"

    profile = safe_profile(decision.context, request.adjustment)
    return RecommendationResponse(
        profile_id=f"profile-{uuid4().hex[:8]}",
        context=decision.context,
        confidence=decision.confidence,
        profile=profile,
        reason=decision.reason,
        requires_confirmation=len(metrics) < 2 or decision.confidence < 0.65,
        input_source="demo",
        generated_by=generated_by,
        observed_sample_count=len(request.signal_window()),
        evidence=decision.evidence,
    )
