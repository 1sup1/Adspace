from __future__ import annotations

import json
import os
from typing import Any, Literal
from uuid import uuid4

from agents import Agent, ModelSettings, RunConfig, Runner, function_tool
from pydantic import BaseModel, ConfigDict, Field, model_validator

from tool_registry import ToolDraftSuggestion


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


class AgentDecision(StrictModel):
    context: Context
    confidence: float = Field(ge=0, le=1)
    reason: str = Field(min_length=10, max_length=180)
    evidence: list[str] = Field(min_length=1, max_length=3)


class DecisionComparison(StrictModel):
    rule_based: AgentDecision
    agent: AgentDecision
    signal_evidence: list[str] = Field(min_length=1, max_length=3)
    conflict_detected: bool
    selected: Literal["agent", "rules_fallback"]


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
    comparison: DecisionComparison


class ChatTurn(StrictModel):
    role: Literal["user", "assistant"]
    content: str = Field(min_length=1, max_length=1000)


class ChatContext(StrictModel):
    context: Context
    confidence: float = Field(ge=0, le=1)
    profile: EnvironmentProfile
    reason: str = Field(max_length=500)


class ChatRequest(StrictModel):
    messages: list[ChatTurn] = Field(min_length=1, max_length=12)
    context: ChatContext | None = None


class ChatResponse(StrictModel):
    message: str = Field(min_length=1, max_length=1200)


class CommandArgument(StrictModel):
    name: str = Field(pattern=r"^[a-z][a-z0-9_.-]{0,63}$")
    string_value: str | None
    integer_value: int | None
    number_value: float | None
    boolean_value: bool | None

    @model_validator(mode="after")
    def exactly_one_value(self) -> CommandArgument:
        values = (
            self.string_value,
            self.integer_value,
            self.number_value,
            self.boolean_value,
        )
        if sum(value is not None for value in values) != 1:
            raise ValueError("command arguments require exactly one typed value")
        return self

    def value_for(self, expected_type: str) -> Any:
        values = {
            "string": self.string_value,
            "integer": self.integer_value,
            "number": self.number_value,
            "boolean": self.boolean_value,
        }
        value = values.get(expected_type)
        if value is None:
            raise ValueError(f"argument {self.name} must use {expected_type}_value")
        return value


class CommandFallbackDecision(StrictModel):
    kind: Literal["chat", "builtin_tool", "existing_tool", "tool_draft"]
    message: str | None
    tool_name: str | None
    arguments: list[CommandArgument]
    name: str | None
    description: str | None
    device_id: str | None
    capability_id: str | None
    confirmation_text: str | None

    @model_validator(mode="after")
    def validate_kind_fields(self) -> CommandFallbackDecision:
        draft_values = (
            self.name,
            self.description,
            self.device_id,
            self.capability_id,
            self.confirmation_text,
        )
        if self.kind == "chat":
            if not self.message or any(value is not None for value in draft_values):
                raise ValueError("chat decisions require only message")
            if self.tool_name is not None or self.arguments:
                raise ValueError("chat decisions cannot select a tool")
        elif self.kind in {"builtin_tool", "existing_tool"}:
            if not self.tool_name:
                raise ValueError("tool decisions require tool_name")
            if any(value is not None for value in draft_values):
                raise ValueError("existing_tool decisions cannot define a new tool")
        else:
            if any(value is None for value in draft_values):
                raise ValueError("tool_draft decisions require every declarative draft field")
            if self.tool_name is not None:
                raise ValueError("tool_draft decisions cannot select an existing tool name")
        return self

    def draft_suggestion(self) -> ToolDraftSuggestion:
        if self.kind != "tool_draft":
            raise ValueError("decision does not contain a tool draft")
        return ToolDraftSuggestion.model_validate(
            {
                "name": self.name,
                "description": self.description,
                "device_id": self.device_id,
                "capability_id": self.capability_id,
                "confirmation_text": self.confirmation_text,
            }
        )


class SignalSummary(StrictModel):
    sample_count: int = Field(ge=1, le=12)
    latest_sleep_score: int | None = None
    activity_steps_delta: int | None = None
    average_heart_rate_bpm: float | None = None
    heart_rate_delta_bpm: int | None = None
    average_hrv_ms: float | None = None
    hrv_delta_ms: int | None = None
    time_of_day: Literal["morning", "afternoon", "evening"]


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
        "신호가 상충하면 지금 공간을 조율하는 목적에 맞춰 과거의 정적 점수보다 현재의 지속적인 변화 추세를 우선하고, "
        "시간대와 사용자 안전을 함께 비교하세요. 값에 정상·비정상 같은 임의의 등급을 붙이지 마세요. "
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


CHAT_AGENT = Agent(
    name="Adaptive Space concierge",
    model=os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
    instructions=(
        "당신은 Adaptive Space 앱 안의 간결한 한국어 공간 조율 도우미입니다. "
        "제공된 현재 추천 맥락과 환경값을 설명하고 사용자의 공간 선호 질문에 답하세요. "
        "질환·감정·스트레스를 진단하거나 회복·집중 효과를 보장하지 마세요. "
        "입력에 없는 생체정보를 추측하지 말고, 기기를 제어했다고 말하지 마세요. "
        "설정 변경 요청에는 앱의 적용 또는 조절 UI를 사용하라고 안내하세요. "
        "답변은 마크다운 없이 두세 문장 이내로 유지하세요."
    ),
    model_settings=ModelSettings(
        reasoning={"effort": "none"},
        verbosity="low",
        store=False,
    ),
)


COMMAND_FALLBACK_AGENT = Agent(
    name="Adaptive Space safe command fallback",
    model=os.getenv("OPENAI_MODEL", "gpt-5.6-luna"),
    instructions=(
        "당신은 Adaptive Space의 안전한 명령 분류기이자 간결한 한국어 도우미입니다. "
        "입력에는 내장 도구, 연결된 기기의 선언형 capability manifest와 이미 승인된 도구만 제공됩니다. "
        "요청이 내장 도구로 해결되면 builtin_tool을, 승인된 도구로 해결되면 existing_tool을 선택하고 "
        "builtin_tools 목록의 name은 절대로 existing_tool로 분류하지 마세요. "
        "정확한 tool_name과 arguments를 반환하세요. 각 argument는 스키마 type과 같은 typed value 필드 하나만 "
        "채우고 나머지 value 필드는 null로 두세요. 요청이 연결된 기기의 capability로 해결되지만 승인된 도구가 없을 때만 "
        "tool_draft를 반환하고, 제공된 device_id와 capability_id를 정확히 복사하세요. "
        "tool_draft의 arguments에는 사용자 요청에서 확인되는 실행 인자를 capability 스키마에 맞춰 넣으세요. "
        "새 도구 이름은 소문자 snake_case로 작성하세요. 스키마, 코드, 스크립트, 명령줄, URL, 모듈, "
        "네트워크 엔드포인트 또는 실행 로직을 만들거나 출력하지 마세요. 실행했다고 말하지도 마세요. "
        "기능이 manifest에 없거나 일반적인 질문이면 chat으로 답하세요. 건강 상태를 진단하거나 효과를 보장하지 말고, "
        "chat 메시지는 마크다운 없이 두세 문장 이내로 유지하세요."
    ),
    model_settings=ModelSettings(
        reasoning={"effort": "none"},
        verbosity="low",
        store=False,
    ),
    output_type=CommandFallbackDecision,
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
    evidence: list[str] = []
    if summary.latest_sleep_score is not None:
        evidence.append(f"수면 점수 {summary.latest_sleep_score}")
    if summary.heart_rate_delta_bpm is not None:
        evidence.append(f"심박 변화 {summary.heart_rate_delta_bpm:+d}")
    if summary.hrv_delta_ms is not None:
        evidence.append(f"HRV 변화 {summary.hrv_delta_ms:+d}")
    if not evidence:
        evidence.append(f"최근 신호 {summary.sample_count}개")
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


def comparison_evidence(summary: SignalSummary) -> list[str]:
    evidence: list[str] = []
    if summary.latest_sleep_score is not None:
        evidence.append(f"수면 {summary.latest_sleep_score}")
    if summary.heart_rate_delta_bpm is not None:
        evidence.append(f"심박 {summary.heart_rate_delta_bpm:+d}")
    if summary.hrv_delta_ms is not None:
        evidence.append(f"HRV {summary.hrv_delta_ms:+d}")
    return evidence or [f"신호 {summary.sample_count}개"]


async def recommend(request: RecommendationRequest) -> RecommendationResponse:
    metrics = request.consented_metrics()
    rule_decision = fallback_decision(request)
    decision = rule_decision
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
    summary = summarize_signal_window(request.signal_window(), request.consented_fields)
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
        comparison=DecisionComparison(
            rule_based=rule_decision,
            agent=decision,
            signal_evidence=comparison_evidence(summary),
            conflict_detected=rule_decision.context != decision.context,
            selected="agent" if generated_by == "agents_sdk" else "rules_fallback",
        ),
    )


async def chat(request: ChatRequest) -> ChatResponse:
    result = await Runner.run(
        CHAT_AGENT,
        json.dumps(request.model_dump(mode="json"), ensure_ascii=False),
        max_turns=1,
        run_config=RunConfig(
            workflow_name="Adaptive Space conversation",
            trace_include_sensitive_data=False,
        ),
    )
    message = str(result.final_output).strip()
    return ChatResponse(message=message)


async def route_command_fallback(
    text: str,
    *,
    connected_devices: list[dict[str, Any]],
    approved_tools: list[dict[str, Any]],
    builtin_tools: list[dict[str, Any]],
    scope: str | None = None,
    chat_context: dict[str, Any] | None = None,
    recent_messages: list[dict[str, str]] | None = None,
) -> CommandFallbackDecision:
    """Classify a Needle miss without giving GPT executable capabilities."""
    prompt = json.dumps(
        {
            "request": text,
            "scope": scope,
            "builtin_tools": builtin_tools,
            "connected_devices": connected_devices,
            "approved_tools": approved_tools,
            "current_recommendation": chat_context,
            "recent_messages": recent_messages or [],
        },
        ensure_ascii=False,
    )
    last_error: Exception | None = None
    for attempt in range(2):
        try:
            result = await Runner.run(
                COMMAND_FALLBACK_AGENT,
                prompt,
                max_turns=1,
                run_config=RunConfig(
                    workflow_name="Adaptive Space safe command fallback",
                    trace_include_sensitive_data=False,
                ),
            )
            return result.final_output_as(
                CommandFallbackDecision,
                raise_if_incorrect_type=True,
            )
        except Exception as error:
            last_error = error
            if attempt == 0:
                # Classification has no side effects, so one immediate retry is safe when a
                # provider returns transiently malformed structured output.
                print(f"Command fallback retry: {type(error).__name__}")
                continue
            raise
    raise RuntimeError("command fallback failed without an exception") from last_error
