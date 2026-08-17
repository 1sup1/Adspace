from __future__ import annotations

import json
import unittest
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime, timedelta
from http.client import HTTPConnection
from http.server import ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Lock, Thread
from time import sleep
from unittest.mock import AsyncMock, patch

from pydantic import ValidationError

from agent import (
    AgentDecision,
    ChatRequest,
    CommandFallbackDecision,
    RecommendationRequest,
    WearableSnapshot,
    chat,
    classify_context,
    recommend,
    route_command_fallback,
    safe_profile,
    summarize_signal_window,
)
from main import (
    BuiltinToolProposalRequest,
    CommandRouteRequest,
    CommandService,
    DynamicToolProposalRequest,
    ProposalExpired,
    SessionStore,
    make_handler,
)
from needle_router import NeedleRouteResult, NeedleRouter
from tool_registry import (
    DeviceManifest,
    RegistryConflict,
    RegistryNotFound,
    RegistryValidationError,
    ToolDraft,
    ToolDraftSuggestion,
    ToolRegistry,
)


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


def lamp_manifest(
    *,
    connected: bool = True,
    scopes: list[str] | None = None,
) -> DeviceManifest:
    return DeviceManifest.model_validate(
        {
            "device_id": "desk-lamp",
            "name": "Desk Lamp",
            "connected": connected,
            "scopes": scopes or ["home"],
            "adapter": "simulator",
            "capabilities": [
                {
                    "capability_id": "set_brightness",
                    "name": "밝기 설정",
                    "description": "책상 조명의 밝기를 설정합니다.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "brightness_percent": {
                                "type": "integer",
                                "minimum": 0,
                                "maximum": 100,
                            }
                        },
                        "required": ["brightness_percent"],
                        "additionalProperties": False,
                    },
                }
            ],
        }
    )


def hotel_fan_manifest(*, connected: bool = True) -> DeviceManifest:
    return DeviceManifest.model_validate(
        {
            "device_id": "hotel-fan",
            "name": "Hotel Fan",
            "connected": connected,
            "scopes": ["hotel"],
            "adapter": "simulator",
            "capabilities": [
                {
                    "capability_id": "set_speed",
                    "name": "풍속 설정",
                    "description": "호텔 선풍기의 풍속을 설정합니다.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "speed": {
                                "type": "string",
                                "enum": ["low", "high"],
                            }
                        },
                        "required": ["speed"],
                        "additionalProperties": False,
                    },
                }
            ],
        }
    )


def suggestion(**overrides: object) -> ToolDraftSuggestion:
    return ToolDraftSuggestion.model_validate(
        {
            "name": "set_desk_lamp_brightness",
            "description": "연결된 책상 조명의 밝기를 안전 범위 안에서 설정합니다.",
            "device_id": "desk-lamp",
            "capability_id": "set_brightness",
            "confirmation_text": "책상 조명 밝기를 변경할까요?",
            **overrides,
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


class ToolRegistryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.registry_path = Path(self.temporary_directory.name) / "registry.json"
        self.registry = ToolRegistry(
            self.registry_path,
            reserved_tool_names={"apply_recommendation"},
        )
        self.registry.register_device(lamp_manifest())

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_unknown_capability_is_rejected(self) -> None:
        with self.assertRaises(RegistryValidationError):
            self.registry.create_draft(suggestion(capability_id="open_portal"))

    def test_models_reject_arbitrary_code_fields(self) -> None:
        payload = suggestion().model_dump()
        payload["code"] = "import os; os.system('unsafe')"
        with self.assertRaises(ValidationError):
            ToolDraftSuggestion.model_validate(payload)

        draft_payload = {
            **suggestion().model_dump(),
            "parameters": lamp_manifest().capabilities[0].parameters,
            "code": "def execute(): pass",
        }
        with self.assertRaises(ValidationError):
            ToolDraft.model_validate(draft_payload)

    def test_approval_persists_and_execution_is_manifest_bounded(self) -> None:
        draft = self.registry.create_draft(suggestion())
        self.assertEqual(draft.status, "pending")
        with self.assertRaises(RegistryNotFound):
            self.registry.execute(draft.draft_id, {"brightness_percent": 30})

        tool = self.registry.approve_draft(draft.draft_id)
        self.assertEqual(tool.scopes, ["home"])
        self.assertEqual(len(tool.manifest_revision), 64)
        with self.assertRaises(RegistryValidationError):
            self.registry.execute(tool.tool_id, {"brightness_percent": 101})
        result = self.registry.execute(tool.tool_id, {"brightness_percent": 30})
        self.assertEqual(result["status"], "simulated")
        self.assertEqual(result["applied"], {"brightness_percent": 30})

        reloaded = ToolRegistry(self.registry_path)
        self.assertEqual(reloaded.tool_named(tool.name).tool_id, tool.tool_id)
        self.assertEqual(
            reloaded.device_state("desk-lamp"),
            {"set_brightness": {"brightness_percent": 30}},
        )
        self.assertEqual(list(self.registry_path.parent.glob("*.tmp")), [])

    def test_approved_binding_cannot_create_a_duplicate_tool_draft(self) -> None:
        draft = self.registry.create_draft(suggestion())
        self.registry.approve_draft(draft.draft_id)
        with self.assertRaises(RegistryConflict):
            self.registry.create_draft(
                suggestion(name="change_desk_lamp_brightness")
            )

    def test_multi_scope_device_requires_independent_scope_approvals(self) -> None:
        with TemporaryDirectory() as directory:
            registry = ToolRegistry(Path(directory) / "registry.json")
            registry.register_device(lamp_manifest(scopes=["home", "hotel"]))

            home_draft = registry.create_draft(suggestion(), scope="home")
            self.assertEqual(home_draft.scopes, ["home"])
            home_tool = registry.approve_draft(home_draft.draft_id)
            self.assertEqual(home_tool.scopes, ["home"])
            self.assertEqual(
                [tool.tool_id for tool in registry.eligible_tools(scope="home")],
                [home_tool.tool_id],
            )
            self.assertEqual(registry.eligible_tools(scope="hotel"), [])
            with self.assertRaises(RegistryValidationError):
                registry.execute(
                    home_tool.tool_id,
                    {"brightness_percent": 30},
                    scope="hotel",
                )

            hotel_draft = registry.create_draft(suggestion(), scope="hotel")
            self.assertEqual(hotel_draft.scopes, ["hotel"])
            self.assertEqual(hotel_draft.name, "set_desk_lamp_brightness_hotel")
            hotel_tool = registry.approve_draft(hotel_draft.draft_id)
            self.assertEqual(hotel_tool.scopes, ["hotel"])
            self.assertEqual(
                registry.tool_for_binding(
                    "desk-lamp",
                    "set_brightness",
                    scope="home",
                ).tool_id,
                home_tool.tool_id,
            )
            self.assertEqual(
                registry.tool_for_binding(
                    "desk-lamp",
                    "set_brightness",
                    scope="hotel",
                ).tool_id,
                hotel_tool.tool_id,
            )
            self.assertEqual(
                [tool.tool_id for tool in registry.eligible_tools(scope="hotel")],
                [hotel_tool.tool_id],
            )

    def test_version_one_registry_without_binding_fields_is_migrated(self) -> None:
        draft = self.registry.create_draft(suggestion())
        tool = self.registry.approve_draft(draft.draft_id)
        payload = json.loads(self.registry_path.read_text(encoding="utf-8"))
        for device in payload["devices"]:
            device.pop("scopes")
        for binding in [*payload["drafts"], *payload["tools"]]:
            binding.pop("scopes")
            binding.pop("manifest_revision")
        self.registry_path.write_text(json.dumps(payload), encoding="utf-8")

        migrated = ToolRegistry(self.registry_path)
        migrated_tool = migrated.tool_by_id(tool.tool_id)
        self.assertIsNotNone(migrated_tool)
        self.assertEqual(migrated_tool.scopes, ["home"])
        self.assertEqual(
            migrated_tool.manifest_revision,
            migrated.list_devices()[0].revision(),
        )

    def test_manifest_revision_and_scope_are_revalidated_before_execution(self) -> None:
        tool = self.registry.approve_draft(
            self.registry.create_draft(suggestion()).draft_id
        )
        with self.assertRaises(RegistryValidationError):
            self.registry.execute(
                tool.tool_id,
                {"brightness_percent": 30},
                scope="hotel",
            )

        payload = json.loads(self.registry_path.read_text(encoding="utf-8"))
        payload["devices"][0]["capabilities"][0]["description"] = "변경된 기기 명세"
        self.registry_path.write_text(json.dumps(payload), encoding="utf-8")
        reloaded = ToolRegistry(self.registry_path)
        self.assertEqual(reloaded.eligible_tools(scope="home"), [])
        with self.assertRaises(RegistryValidationError):
            reloaded.execute(
                tool.tool_id,
                {"brightness_percent": 30},
                scope="home",
            )

    def test_repeated_gpt_draft_for_same_capability_is_idempotent(self) -> None:
        first = self.registry.create_draft(suggestion())
        second = self.registry.create_draft(
            suggestion(
                name="change_desk_lamp_brightness",
                description="같은 조명 기능에 대한 반복된 안전 도구 요청입니다.",
            )
        )
        self.assertEqual(second.draft_id, first.draft_id)
        self.assertEqual(len(self.registry.list_drafts()), 1)

    def test_reusable_tool_copy_is_canonicalized_from_device_manifest(self) -> None:
        draft = self.registry.create_draft(
            suggestion(
                description="책상 조명을 이번에는 35퍼센트로 설정합니다.",
                confirmation_text="책상 조명을 35퍼센트로 바꿀까요?",
            )
        )

        self.assertEqual(
            draft.description,
            "Desk Lamp의 밝기 설정 기능을 실행합니다.",
        )
        self.assertEqual(
            draft.confirmation_text,
            "Desk Lamp의 밝기 설정 기능을 실행할까요?",
        )
        self.assertNotIn("35", draft.confirmation_text)


class NeedleRouterTests(unittest.TestCase):
    def test_complete_is_serialized_reset_and_confidence_gated(self) -> None:
        class Engine:
            def __init__(self) -> None:
                self.guard = Lock()
                self.active = 0
                self.max_active = 0
                self.reset_count = 0
                self.tokens: list[int] = []

            def reset(self) -> None:
                self.reset_count += 1

            def complete(self, _text: str, *, max_new_tokens: int) -> dict:
                with self.guard:
                    self.active += 1
                    self.max_active = max(self.max_active, self.active)
                sleep(0.01)
                with self.guard:
                    self.active -= 1
                    self.tokens.append(max_new_tokens)
                return {
                    "type": "call",
                    "confidence": 0.91,
                    "function_calls": [{"name": "stop_environment", "arguments": {}}],
                }

            def run(self, *_args: object, **_kwargs: object) -> None:
                raise AssertionError("Needle run() must never be used")

        engine = Engine()
        router = NeedleRouter(lambda: [], engine_factory=lambda _tools: engine)
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(lambda _: router.route("지금 멈춰"), range(6)))
        self.assertTrue(all(result.matched for result in results))
        self.assertEqual(engine.max_active, 1)
        self.assertEqual(engine.reset_count, 6)
        self.assertEqual(engine.tokens, [128] * 6)

    def test_low_confidence_or_unicode_engine_error_is_a_miss(self) -> None:
        class LowConfidenceEngine:
            def reset(self) -> None:
                pass

            def complete(self, *_args: object, **_kwargs: object) -> dict:
                return {
                    "type": "call",
                    "confidence": 0.0204,
                    "function_calls": [
                        {"name": "apply_recommendation", "arguments": {"scope": "hotel"}}
                    ],
                }

        router = NeedleRouter(lambda: [], engine_factory=lambda _tools: LowConfidenceEngine())
        result = router.route("집 추천 환경을 적용해줘", scope="home")
        self.assertFalse(result.matched)
        self.assertEqual(result.reason, "low_confidence")

        class BrokenEngine(LowConfidenceEngine):
            def complete(self, *_args: object, **_kwargs: object) -> dict:
                raise UnicodeDecodeError("utf-8", b"x", 0, 1, "bad output")

        broken = NeedleRouter(lambda: [], engine_factory=lambda _tools: BrokenEngine())
        self.assertEqual(broken.route("조명을 켜줘").reason, "engine_unavailable")

    def test_call_envelope_must_be_successful_and_error_free(self) -> None:
        class Engine:
            def __init__(self, response: dict) -> None:
                self.response = response

            def reset(self) -> None:
                pass

            def complete(self, *_args: object, **_kwargs: object) -> dict:
                return self.response

        valid_call = {
            "type": "call",
            "confidence": 0.95,
            "function_calls": [{"name": "stop_environment", "arguments": {}}],
        }
        invalid_envelopes = [
            {**valid_call, "type": "chat"},
            {**valid_call, "success": False},
            {**valid_call, "error": "decoder failure"},
        ]
        for response in invalid_envelopes:
            with self.subTest(response=response):
                router = NeedleRouter(
                    lambda: [],
                    engine_factory=lambda _tools, response=response: Engine(response),
                )
                result = router.route("멈춰")
                self.assertFalse(result.matched)
                self.assertEqual(result.reason, "invalid_call")

    def test_approved_registry_schema_rebuilds_needles_toolset(self) -> None:
        with TemporaryDirectory() as directory:
            registry = ToolRegistry(Path(directory) / "registry.json")
            registry.register_device(lamp_manifest())
            observed_toolsets: list[list[dict]] = []

            class Engine:
                def __init__(self, tools: list[dict]) -> None:
                    self.tools = tools

                def reset(self) -> None:
                    pass

                def complete(self, *_args: object, **_kwargs: object) -> dict:
                    dynamic = next(
                        (
                            item
                            for item in self.tools
                            if item["name"] == "set_desk_lamp_brightness"
                        ),
                        None,
                    )
                    return {
                        "type": "call",
                        "confidence": 0.93,
                        "function_calls": []
                        if dynamic is None
                        else [
                            {
                                "name": dynamic["name"],
                                "arguments": {"brightness_percent": 35},
                            }
                        ],
                    }

            def factory(tools: list[dict]) -> Engine:
                observed_toolsets.append(tools)
                return Engine(tools)

            router = NeedleRouter(registry.list_tools, engine_factory=factory)
            self.assertFalse(router.route("책상 조명 35퍼센트").matched)
            registry.approve_draft(registry.create_draft(suggestion()).draft_id)
            result = router.route("책상 조명 35퍼센트")
            self.assertTrue(result.matched)
            self.assertEqual(result.call.name, "set_desk_lamp_brightness")
            self.assertEqual(len(observed_toolsets), 2)
            self.assertEqual(len(observed_toolsets[-1]), len(observed_toolsets[0]) + 1)


class _MissRouter:
    def __init__(self, reason: str = "low_confidence") -> None:
        self.reason = reason

    def route(self, _text: str, *, scope: str | None = None) -> NeedleRouteResult:
        return NeedleRouteResult(
            matched=False,
            available=True,
            reason=self.reason,
            confidence=0.2,
        )


class CommandRoutingTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.registry = ToolRegistry(Path(self.temporary_directory.name) / "registry.json")
        self.registry.register_device(lamp_manifest())

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    async def test_needle_miss_to_gpt_builtin_proposal(self) -> None:
        decision = CommandFallbackDecision(
            kind="builtin_tool",
            message=None,
            tool_name="apply_recommendation",
            arguments=[
                {
                    "name": "scope",
                    "string_value": "home",
                    "integer_value": None,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        fallback = AsyncMock(return_value=decision)
        now = datetime(2026, 8, 17, 12, 0, tzinfo=UTC)
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=fallback,
            proposal_clock=lambda: now,
        )
        response = await service.route(
            CommandRouteRequest(text="집 추천 환경을 적용해줘", scope="home")
        )
        self.assertEqual(response.kind, "builtin_proposal")
        self.assertEqual(response.routed_by, "gpt")
        self.assertEqual(response.proposal.action, "apply_recommendation")
        self.assertTrue(response.proposal.requires_confirmation)
        self.assertRegex(response.proposal.proposal_id, r"^[0-9a-f]{32}$")
        self.assertEqual(response.proposal.tool_name, "apply_recommendation")
        self.assertEqual(response.proposal.device_id, "app-model")
        self.assertEqual(response.proposal.capability_id, "apply_recommendation")
        self.assertEqual(response.proposal.scope, "home")
        self.assertEqual(
            datetime.fromisoformat(response.proposal.expires_at) - now,
            timedelta(seconds=120),
        )

        confirmed = service.confirm_proposal(response.proposal.proposal_id)
        self.assertEqual(confirmed["action"], "apply_recommendation")
        self.assertEqual(confirmed["arguments"], {"scope": "home"})
        with self.assertRaises(RegistryConflict):
            service.confirm_proposal(response.proposal.proposal_id)

    async def test_builtin_name_is_safely_normalized_if_gpt_labels_it_existing(self) -> None:
        decision = CommandFallbackDecision(
            kind="existing_tool",
            message=None,
            tool_name="restore_environment",
            arguments=[
                {
                    "name": "scope",
                    "string_value": "home",
                    "integer_value": None,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(
            CommandRouteRequest(text="집 환경을 원래대로 돌려줘", scope="home")
        )
        self.assertEqual(response.kind, "builtin_proposal")
        self.assertEqual(response.proposal.action, "restore_environment")

    async def test_command_route_binds_builtin_to_hotel_session(self) -> None:
        decision = CommandFallbackDecision(
            kind="builtin_tool",
            message=None,
            tool_name="stop_environment",
            arguments=[
                {
                    "name": "scope",
                    "string_value": "hotel",
                    "integer_value": None,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(
            CommandRouteRequest(
                text="호텔 환경을 멈춰줘",
                scope="hotel",
                session_id="session-deadbeef",
            )
        )
        self.assertEqual(response.proposal.scope, "hotel")
        self.assertEqual(response.proposal.session_id, "session-deadbeef")
        with self.assertRaises(RegistryConflict):
            service.confirm_proposal(response.proposal.proposal_id)

    async def test_proposal_expiry_is_fail_closed_and_one_way(self) -> None:
        clock = [datetime(2026, 8, 17, 12, 0, tzinfo=UTC)]
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(),
            proposal_clock=lambda: clock[0],
        )
        proposal = service.propose_builtin_tool(
            "stop_environment",
            BuiltinToolProposalRequest(arguments={}, scope="home"),
        )
        clock[0] += timedelta(seconds=121)
        with self.assertRaises(ProposalExpired):
            service.confirm_proposal(proposal.proposal_id)
        with self.assertRaises(ProposalExpired):
            service.confirm_proposal(proposal.proposal_id)

    async def test_adjust_environment_is_home_only(self) -> None:
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(),
        )
        with self.assertRaises(RegistryValidationError):
            service.propose_builtin_tool(
                "adjust_environment",
                BuiltinToolProposalRequest(
                    arguments={"brightness_delta": 5},
                    scope="hotel",
                    session_id="session-deadbeef",
                ),
            )

    async def test_needle_miss_to_gpt_draft_requires_approval(self) -> None:
        decision = CommandFallbackDecision(
            kind="tool_draft",
            message="이 기능은 새 도구 승인이 필요합니다.",
            tool_name=None,
            arguments=[
                {
                    "name": "brightness_percent",
                    "string_value": None,
                    "integer_value": 35,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name="set_desk_lamp_brightness",
            description="연결된 책상 조명의 밝기를 안전 범위 안에서 설정합니다.",
            device_id="desk-lamp",
            capability_id="set_brightness",
            confirmation_text="책상 조명 밝기를 변경할까요?",
        )
        service = CommandService(
            self.registry,
            _MissRouter("empty_call"),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(CommandRouteRequest(text="책상 조명 밝기 바꿔줘"))
        self.assertEqual(response.kind, "tool_draft")
        self.assertEqual(response.draft.status, "pending")
        self.assertEqual(response.draft.scopes, ["home"])
        self.assertEqual(
            response.draft.parameters,
            lamp_manifest().capabilities[0].parameters,
        )
        self.assertEqual(response.proposal.arguments, {"brightness_percent": 35})
        self.assertIsNone(response.proposal.tool_id)
        self.assertEqual(self.registry.list_tools(), [])

        approval = service.approve_tool_draft(
            response.draft.draft_id,
            response.proposal.proposal_id,
        )
        self.assertEqual(approval.tool.draft_id, response.draft.draft_id)
        self.assertNotEqual(
            approval.execution_proposal.proposal_id,
            response.proposal.proposal_id,
        )
        self.assertEqual(self.registry.device_state("desk-lamp"), {})
        with self.assertRaises(RegistryConflict):
            service.confirm_proposal(response.proposal.proposal_id)

        executed = service.confirm_proposal(approval.execution_proposal.proposal_id)
        self.assertEqual(executed["status"], "executed")
        self.assertEqual(
            executed["result"]["applied"],
            {"brightness_percent": 35},
        )
        with self.assertRaises(RegistryConflict):
            service.confirm_proposal(approval.execution_proposal.proposal_id)

    async def test_approved_tool_is_reused_by_gpt_after_needle_miss(self) -> None:
        tool = self.registry.approve_draft(self.registry.create_draft(suggestion()).draft_id)
        decision = CommandFallbackDecision(
            kind="existing_tool",
            message=None,
            tool_name=tool.name,
            arguments=[
                {
                    "name": "brightness_percent",
                    "string_value": None,
                    "integer_value": 35,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(CommandRouteRequest(text="책상 조명 35퍼센트"))
        self.assertEqual(response.kind, "dynamic_proposal")
        self.assertEqual(response.proposal.tool_id, tool.tool_id)
        self.assertEqual(response.proposal.arguments, {"brightness_percent": 35})
        self.assertEqual(len(self.registry.list_drafts()), 1)

    async def test_dynamic_confirmation_failure_still_consumes_proposal(self) -> None:
        tool = self.registry.approve_draft(self.registry.create_draft(suggestion()).draft_id)
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(),
        )
        proposal = service.propose_dynamic_tool(
            tool.tool_id,
            DynamicToolProposalRequest(
                arguments={"brightness_percent": 40},
                scope="home",
            ),
        )
        self.registry.connect_device("desk-lamp", False)
        with self.assertRaises(RegistryValidationError):
            service.confirm_proposal(proposal.proposal_id)
        self.registry.connect_device("desk-lamp", True)
        with self.assertRaises(RegistryConflict):
            service.confirm_proposal(proposal.proposal_id)
        self.assertEqual(self.registry.device_state("desk-lamp"), {})

    async def test_gpt_duplicate_draft_is_normalized_to_existing_tool(self) -> None:
        tool = self.registry.approve_draft(self.registry.create_draft(suggestion()).draft_id)
        decision = CommandFallbackDecision(
            kind="tool_draft",
            message="기존 승인 도구를 재사용합니다.",
            tool_name=None,
            arguments=[
                {
                    "name": "brightness_percent",
                    "string_value": None,
                    "integer_value": 45,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name="another_name_for_same_binding",
            description="같은 연결 기능을 새 이름으로 다시 제안합니다.",
            device_id="desk-lamp",
            capability_id="set_brightness",
            confirmation_text="다시 만들까요?",
        )
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(CommandRouteRequest(text="책상 조명 45퍼센트"))
        self.assertEqual(response.kind, "dynamic_proposal")
        self.assertEqual(response.proposal.tool_id, tool.tool_id)
        self.assertEqual(len(self.registry.list_drafts()), 1)

    async def test_command_route_creates_a_separate_draft_for_each_scope(self) -> None:
        with TemporaryDirectory() as directory:
            registry = ToolRegistry(Path(directory) / "registry.json")
            registry.register_device(lamp_manifest(scopes=["home", "hotel"]))
            decision = CommandFallbackDecision(
                kind="tool_draft",
                message="이 기능은 scope별 승인이 필요합니다.",
                tool_name=None,
                arguments=[
                    {
                        "name": "brightness_percent",
                        "string_value": None,
                        "integer_value": 45,
                        "number_value": None,
                        "boolean_value": None,
                    }
                ],
                name="set_desk_lamp_brightness",
                description="연결된 책상 조명의 밝기를 안전 범위 안에서 설정합니다.",
                device_id="desk-lamp",
                capability_id="set_brightness",
                confirmation_text="책상 조명 밝기를 바꿀까요?",
            )
            service = CommandService(
                registry,
                _MissRouter(),
                fallback_runner=AsyncMock(return_value=decision),
            )

            home = await service.route(
                CommandRouteRequest(text="집 책상 조명 45퍼센트", scope="home")
            )
            service.approve_tool_draft(home.draft.draft_id, home.proposal.proposal_id)
            hotel = await service.route(
                CommandRouteRequest(text="호텔 책상 조명 45퍼센트", scope="hotel")
            )

            self.assertEqual(home.draft.scopes, ["home"])
            self.assertEqual(hotel.kind, "tool_draft")
            self.assertEqual(hotel.draft.scopes, ["hotel"])
            self.assertEqual(hotel.draft.name, "set_desk_lamp_brightness_hotel")

    async def test_draft_approval_reclaims_terminal_record_at_proposal_cap(self) -> None:
        decision = CommandFallbackDecision(
            kind="tool_draft",
            message="새 도구 승인이 필요합니다.",
            tool_name=None,
            arguments=[
                {
                    "name": "brightness_percent",
                    "string_value": None,
                    "integer_value": 35,
                    "number_value": None,
                    "boolean_value": None,
                }
            ],
            name="set_desk_lamp_brightness",
            description="연결된 책상 조명의 밝기를 안전 범위 안에서 설정합니다.",
            device_id="desk-lamp",
            capability_id="set_brightness",
            confirmation_text="책상 조명 밝기를 변경할까요?",
        )
        service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(return_value=decision),
            max_proposals=1,
        )
        routed = await service.route(CommandRouteRequest(text="책상 조명 35퍼센트"))
        approval = service.approve_tool_draft(
            routed.draft.draft_id,
            routed.proposal.proposal_id,
        )
        self.assertNotEqual(
            approval.execution_proposal.proposal_id,
            routed.proposal.proposal_id,
        )
        executed = service.confirm_proposal(approval.execution_proposal.proposal_id)
        self.assertEqual(executed["status"], "executed")

    async def test_normal_chat_does_not_create_a_tool(self) -> None:
        decision = CommandFallbackDecision(
            kind="chat",
            message="현재 추천은 자극을 낮춘 환경입니다.",
            tool_name=None,
            arguments=[],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        service = CommandService(
            self.registry,
            _MissRouter("empty_call"),
            fallback_runner=AsyncMock(return_value=decision),
        )
        response = await service.route(CommandRouteRequest(text="왜 이 환경이야?"))
        self.assertEqual(response.kind, "chat")
        self.assertEqual(response.message, decision.message)
        self.assertEqual(self.registry.list_drafts(), [])

    async def test_scope_and_device_filters_apply_before_needle_and_gpt(self) -> None:
        self.registry.register_device(hotel_fan_manifest())
        home_tool = self.registry.approve_draft(
            self.registry.create_draft(suggestion()).draft_id
        )
        hotel_tool = self.registry.approve_draft(
            self.registry.create_draft(
                suggestion(
                    name="set_hotel_fan_speed",
                    device_id="hotel-fan",
                    capability_id="set_speed",
                ),
                scope="hotel",
            ).draft_id
        )

        class CapturingRouter(_MissRouter):
            allowed_ids: list[set[str]] = []

            def route_filtered(
                self,
                _text: str,
                *,
                scope: str | None,
                allowed_tool_ids: set[str],
            ) -> NeedleRouteResult:
                self.allowed_ids.append(allowed_tool_ids)
                return self.route(_text, scope=scope)

        decision = CommandFallbackDecision(
            kind="chat",
            message="대화로 이어갑니다.",
            tool_name=None,
            arguments=[],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )
        fallback = AsyncMock(return_value=decision)
        router = CapturingRouter()
        service = CommandService(self.registry, router, fallback_runner=fallback)

        await service.route(CommandRouteRequest(text="무엇을 할 수 있어?", scope="home"))
        self.assertEqual(router.allowed_ids[-1], {home_tool.tool_id})
        self.assertEqual(
            [item["device_id"] for item in fallback.await_args.kwargs["connected_devices"]],
            ["desk-lamp"],
        )
        self.assertEqual(
            [item["tool_id"] for item in fallback.await_args.kwargs["approved_tools"]],
            [home_tool.tool_id],
        )

        await service.route(CommandRouteRequest(text="무엇을 할 수 있어?", scope="hotel"))
        self.assertEqual(router.allowed_ids[-1], {hotel_tool.tool_id})
        self.assertEqual(
            [item["device_id"] for item in fallback.await_args.kwargs["connected_devices"]],
            ["hotel-fan"],
        )
        with self.assertRaises(RegistryValidationError):
            await service.route(
                CommandRouteRequest(
                    text="집에서 호텔 선풍기 켜줘",
                    scope="home",
                    device_ids=["hotel-fan"],
                )
            )


class CommandHTTPContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = TemporaryDirectory()
        self.registry = ToolRegistry(Path(self.temporary_directory.name) / "registry.json")
        self.registry.register_device(lamp_manifest())
        self.clock = [datetime(2026, 8, 17, 12, 0, tzinfo=UTC)]
        self.service = CommandService(
            self.registry,
            _MissRouter(),
            fallback_runner=AsyncMock(),
            proposal_clock=lambda: self.clock[0],
        )
        self.session_store = SessionStore()
        handler = make_handler(
            session_store=self.session_store,
            registry=self.registry,
            command_service=self.service,
        )
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary_directory.cleanup()

    def post(self, path: str, payload: dict) -> tuple[int, dict]:
        connection = HTTPConnection("127.0.0.1", self.server.server_port, timeout=2)
        try:
            connection.request(
                "POST",
                path,
                body=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_local_builtin_token_confirmation_and_direct_execute_removal(self) -> None:
        status, proposal = self.post(
            "/v1/builtin-tools/stop_environment/proposals",
            {"arguments": {}, "scope": "home"},
        )
        self.assertEqual(status, 201)
        self.assertRegex(proposal["proposal_id"], r"^[0-9a-f]{32}$")
        self.assertEqual(proposal["tool_name"], "stop_environment")
        self.assertEqual(
            self.post(
                "/v1/sessions/session-deadbeef/commands",
                {"proposal_id": proposal["proposal_id"]},
            )[0],
            422,
        )

        status, confirmed = self.post(
            f"/v1/command-proposals/{proposal['proposal_id']}/confirm",
            {},
        )
        self.assertEqual(status, 200)
        self.assertEqual(confirmed["arguments"], {"scope": "home"})
        self.assertEqual(
            self.post(
                f"/v1/command-proposals/{proposal['proposal_id']}/confirm",
                {},
            )[0],
            409,
        )

        tool = self.registry.approve_draft(
            self.registry.create_draft(suggestion()).draft_id
        )
        self.assertEqual(
            self.post(
                f"/v1/tools/{tool.tool_id}/execute",
                {"arguments": {"brightness_percent": 30}},
            )[0],
            404,
        )

    def test_dynamic_local_proposal_expires_with_410(self) -> None:
        tool = self.registry.approve_draft(
            self.registry.create_draft(suggestion()).draft_id
        )
        status, proposal = self.post(
            f"/v1/tools/{tool.tool_id}/proposals",
            {"arguments": {"brightness_percent": 30}, "scope": "home"},
        )
        self.assertEqual(status, 201)
        self.clock[0] += timedelta(seconds=121)
        status, response = self.post(
            f"/v1/command-proposals/{proposal['proposal_id']}/confirm",
            {},
        )
        self.assertEqual(status, 410)
        self.assertEqual(response["error"], "proposal_expired")
        self.assertEqual(self.registry.device_state("desk-lamp"), {})

    def test_hotel_session_command_requires_its_bound_one_shot_proposal(self) -> None:
        session = self.session_store.create(
            safe_profile("focus", request().adjustment),
            900,
        )
        session_id = session["session_id"]

        status, direct = self.post(
            f"/v1/sessions/{session_id}/commands",
            {"action": "apply"},
        )
        self.assertEqual(status, 422)
        self.assertEqual(direct["error"], "invalid_request")
        self.assertEqual(self.session_store.sessions[session_id]["status"], "pending_approval")

        status, proposal = self.post(
            "/v1/builtin-tools/apply_recommendation/proposals",
            {"arguments": {}, "scope": "hotel", "session_id": session_id},
        )
        self.assertEqual(status, 201)
        self.assertEqual(proposal["session_id"], session_id)

        self.assertEqual(
            self.post(
                f"/v1/sessions/{session_id}/commands",
                {"proposal_id": proposal["proposal_id"], "action": "checkout"},
            )[0],
            422,
        )

        self.assertEqual(
            self.post(
                f"/v1/command-proposals/{proposal['proposal_id']}/confirm",
                {},
            )[0],
            409,
        )
        self.assertEqual(
            self.post(
                "/v1/sessions/session-deadbeef/commands",
                {"proposal_id": proposal["proposal_id"]},
            )[0],
            422,
        )

        status, applied = self.post(
            f"/v1/sessions/{session_id}/commands",
            {"proposal_id": proposal["proposal_id"]},
        )
        self.assertEqual(status, 200)
        self.assertEqual(applied["status"], "active")
        self.assertEqual(
            self.post(
                f"/v1/sessions/{session_id}/commands",
                {"proposal_id": proposal["proposal_id"]},
            )[0],
            409,
        )


class AgentWorkflowTests(unittest.IsolatedAsyncioTestCase):
    async def test_command_fallback_retries_transient_structured_output_failure(self) -> None:
        decision = CommandFallbackDecision(
            kind="chat",
            message="기존 대화로 이어갑니다.",
            tool_name=None,
            arguments=[],
            name=None,
            description=None,
            device_id=None,
            capability_id=None,
            confirmation_text=None,
        )

        class Result:
            def final_output_as(self, *_: object, **__: object) -> CommandFallbackDecision:
                return decision

        runner = AsyncMock(side_effect=[ValueError("malformed output"), Result()])
        with patch("agent.Runner.run", new=runner):
            response = await route_command_fallback(
                "왜 이런 환경이야?",
                connected_devices=[],
                approved_tools=[],
                builtin_tools=[],
            )

        self.assertEqual(response, decision)
        self.assertEqual(runner.await_count, 2)

    async def test_chat_uses_only_supplied_context_and_returns_agent_message(self) -> None:
        value = ChatRequest.model_validate(
            {
                "messages": [{"role": "user", "content": "왜 이 환경인가요?"}],
                "context": {
                    "context": "recovery",
                    "confidence": 0.82,
                    "profile": safe_profile("recovery", request().adjustment).model_dump(),
                    "reason": "편안한 환경을 제안합니다.",
                },
            }
        )

        class Result:
            final_output = "현재 추천은 자극을 낮춘 환경입니다. 적용 전 값을 확인해 주세요."

        with patch("agent.Runner.run", new=AsyncMock(return_value=Result())) as runner:
            response = await chat(value)

        self.assertIn("현재 추천", response.message)
        prompt = runner.await_args.args[1]
        self.assertNotIn("sleep_score", prompt)
        self.assertNotIn("heart_rate_bpm", prompt)

    async def test_agent_context_selects_bounded_policy_profile(self) -> None:
        value = request(
            sleep_score=74,
            activity_steps=4140,
            heart_rate_bpm=80,
            hrv_ms=30,
            time_of_day="afternoon",
        )
        value.recent_snapshots = [
            WearableSnapshot.model_validate(
                {
                    **value.snapshot.model_dump(),
                    "id": f"demo-{index}",
                    "heart_rate_bpm": heart_rate,
                    "hrv_ms": hrv,
                }
            )
            for index, (heart_rate, hrv) in enumerate(
                [(58, 55), (65, 48), (72, 39), (80, 30)], start=1
            )
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
        self.assertEqual(response.comparison.rule_based.context, "focus")
        self.assertEqual(response.comparison.agent.context, "calm")
        self.assertTrue(response.comparison.conflict_detected)
        self.assertEqual(response.comparison.selected, "agent")


if __name__ == "__main__":
    unittest.main()
