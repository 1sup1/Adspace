from __future__ import annotations

import hashlib
import importlib
import json
from threading import Lock
from typing import Any, Callable, Literal

from pydantic import BaseModel, ConfigDict, Field

from tool_registry import ApprovedTool, RegistryValidationError, validate_arguments


BUILTIN_TOOL_SCHEMAS: list[dict[str, Any]] = [
    {
        "name": "apply_recommendation",
        "description": "현재 추천된 공간 환경을 적용한다.",
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {
                    "type": "string",
                    "enum": ["home", "hotel"],
                    "description": "환경을 적용할 공간",
                }
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "adjust_environment",
        "description": "현재 공간의 조명 밝기, 온도 또는 사운드를 상대적으로 조절한다.",
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {
                    "type": "string",
                    "enum": ["home"],
                    "description": "조절할 공간",
                },
                "brightness_delta": {
                    "type": "integer",
                    "minimum": -30,
                    "maximum": 30,
                    "description": "현재 밝기에서 바꿀 퍼센트포인트",
                },
                "temperature_delta_c": {
                    "type": "number",
                    "minimum": -3,
                    "maximum": 3,
                    "description": "현재 온도에서 바꿀 섭씨 온도",
                },
                "sound_preset": {
                    "type": "string",
                    "enum": ["calm", "focus", "silence"],
                    "description": "적용할 사운드 프리셋",
                },
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "stop_environment",
        "description": "현재 적용 중인 공간 환경 제어를 멈춘다.",
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {"type": "string", "enum": ["home", "hotel"]}
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "restore_environment",
        "description": "공간 환경을 제어 전 기본값으로 복원한다.",
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {"type": "string", "enum": ["home", "hotel"]}
            },
            "required": [],
            "additionalProperties": False,
        },
    },
    {
        "name": "checkout_space",
        "description": "호텔 공간을 체크아웃하고 적용 전 환경으로 복원한다.",
        "parameters": {
            "type": "object",
            "properties": {
                "scope": {"type": "string", "enum": ["hotel"]}
            },
            "required": [],
            "additionalProperties": False,
        },
    },
]
BUILTIN_TOOL_NAMES = {schema["name"] for schema in BUILTIN_TOOL_SCHEMAS}


class _StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class NeedleCall(_StrictModel):
    name: str
    arguments: dict[str, Any]


class NeedleRouteResult(_StrictModel):
    matched: bool
    available: bool
    reason: Literal[
        "matched",
        "empty_call",
        "low_confidence",
        "invalid_call",
        "engine_unavailable",
    ]
    confidence: float | None = Field(default=None, ge=0, le=1)
    call: NeedleCall | None = None


EngineFactory = Callable[[list[dict[str, Any]]], Any]
ToolProvider = Callable[[], list[ApprovedTool]]


class NeedleRouter:
    """Serializes Needle's stateful reset/complete API and never executes a model call."""

    def __init__(
        self,
        tool_provider: ToolProvider,
        *,
        engine_factory: EngineFactory | None = None,
        confidence_threshold: float = 0.80,
        max_new_tokens: int = 128,
    ) -> None:
        if not 0 <= confidence_threshold <= 1:
            raise ValueError("confidence_threshold must be between 0 and 1")
        if max_new_tokens < 128:
            raise ValueError("max_new_tokens must be at least 128")
        self.tool_provider = tool_provider
        self.engine_factory = engine_factory
        self.confidence_threshold = confidence_threshold
        self.max_new_tokens = max_new_tokens
        self._lock = Lock()
        self._engine: Any | None = None
        self._tool_fingerprint: str | None = None
        self._schemas_by_name: dict[str, dict[str, Any]] = {}

    def route(self, text: str, *, scope: str | None = None) -> NeedleRouteResult:
        return self.route_filtered(text, scope=scope, allowed_tool_ids=None)

    def route_filtered(
        self,
        text: str,
        *,
        scope: str | None = None,
        allowed_tool_ids: set[str] | None,
    ) -> NeedleRouteResult:
        with self._lock:
            try:
                tools = self._all_tools(allowed_tool_ids=allowed_tool_ids)
                fingerprint = hashlib.sha256(
                    json.dumps(tools, ensure_ascii=False, sort_keys=True).encode()
                ).hexdigest()
                if self._engine is None or fingerprint != self._tool_fingerprint:
                    self._engine = self._make_engine(tools)
                    self._tool_fingerprint = fingerprint
                    self._schemas_by_name = {tool["name"]: tool for tool in tools}

                query = text if scope is None else f"{text}\nspace scope: {scope}"
                self._engine.reset()
                response = self._engine.complete(
                    query,
                    max_new_tokens=self.max_new_tokens,
                )
                return self._validate_response(response, scope=scope)
            except Exception as error:
                # The optional engine can fail to import, download, decode Unicode, or initialize.
                # All of those are a safe escalation to GPT, never an action.
                print(f"Needle fallback: {type(error).__name__}")
                self._engine = None
                self._tool_fingerprint = None
                self._schemas_by_name = {}
                return NeedleRouteResult(
                    matched=False,
                    available=False,
                    reason="engine_unavailable",
                )

    def _all_tools(self, *, allowed_tool_ids: set[str] | None) -> list[dict[str, Any]]:
        approved_tools = self.tool_provider()
        return [
            *BUILTIN_TOOL_SCHEMAS,
            *(
                tool.needle_schema()
                for tool in approved_tools
                if tool.enabled
                and (allowed_tool_ids is None or tool.tool_id in allowed_tool_ids)
            ),
        ]

    def _make_engine(self, tools: list[dict[str, Any]]) -> Any:
        if self.engine_factory is not None:
            return self.engine_factory(tools)
        needle = importlib.import_module("needle")
        return needle.Needle(
            tools=tools,
            system="locale: ko-KR; device: phone; assistant: Adaptive Space",
        )

    def _validate_response(
        self,
        response: Any,
        *,
        scope: str | None,
    ) -> NeedleRouteResult:
        if not isinstance(response, dict):
            return NeedleRouteResult(matched=False, available=True, reason="invalid_call")
        if (
            response.get("type") != "call"
            or response.get("success") is False
            or response.get("error") is not None
        ):
            return NeedleRouteResult(matched=False, available=True, reason="invalid_call")
        raw_confidence = response.get("confidence")
        confidence = (
            float(raw_confidence)
            if isinstance(raw_confidence, int | float) and not isinstance(raw_confidence, bool)
            else None
        )
        if confidence is None or not 0 <= confidence <= 1:
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="low_confidence",
                confidence=None,
            )
        if confidence < self.confidence_threshold:
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="low_confidence",
                confidence=confidence,
            )
        calls = response.get("function_calls")
        if not isinstance(calls, list) or not calls:
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="empty_call",
                confidence=confidence,
            )
        # Product actions require one confirmation at a time; multi-call model output is rejected.
        if len(calls) != 1 or not isinstance(calls[0], dict):
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="invalid_call",
                confidence=confidence,
            )
        name = calls[0].get("name")
        arguments = calls[0].get("arguments")
        schema = self._schemas_by_name.get(name) if isinstance(name, str) else None
        if schema is None or not isinstance(arguments, dict):
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="invalid_call",
                confidence=confidence,
            )
        merged_arguments = dict(arguments)
        if scope is not None and name in BUILTIN_TOOL_NAMES:
            inferred_scope = merged_arguments.get("scope")
            if inferred_scope is not None and inferred_scope != scope:
                return NeedleRouteResult(
                    matched=False,
                    available=True,
                    reason="invalid_call",
                    confidence=confidence,
                )
            merged_arguments["scope"] = scope
        if name == "checkout_space" and merged_arguments.get("scope", "hotel") != "hotel":
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="invalid_call",
                confidence=confidence,
            )
        if name == "adjust_environment" and not (
            set(merged_arguments) & {"brightness_delta", "temperature_delta_c", "sound_preset"}
        ):
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="invalid_call",
                confidence=confidence,
            )
        try:
            validated = validate_arguments(schema["parameters"], merged_arguments)
        except RegistryValidationError:
            return NeedleRouteResult(
                matched=False,
                available=True,
                reason="invalid_call",
                confidence=confidence,
            )
        return NeedleRouteResult(
            matched=True,
            available=True,
            reason="matched",
            confidence=confidence,
            call=NeedleCall(name=name, arguments=validated),
        )
