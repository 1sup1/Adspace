from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from typing import Any


SERVER_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_ROOT))

from agent import CommandFallbackDecision  # noqa: E402
from main import CommandRouteRequest, CommandService  # noqa: E402
from needle_router import NeedleCall, NeedleRouteResult, NeedleRouter  # noqa: E402
from tool_registry import DeviceManifest, ToolRegistry  # noqa: E402


CASES_PATH = Path(__file__).with_name("cases.jsonl")
RESULTS_PATH = Path(__file__).with_name("results") / "latest.json"

BUILTIN_ARGUMENTS: dict[str, dict[str, Any]] = {
    "apply_home": {"scope": "home"},
    "apply_hotel": {"scope": "hotel"},
    "stop_home": {"scope": "home"},
    "restore_hotel": {"scope": "hotel"},
    "checkout": {"scope": "hotel"},
    "brightness_down": {"scope": "home", "brightness_delta": -10},
}

DEVICE_FIXTURES: dict[str, dict[str, Any]] = {
    "air-purifier": {
        "manifest": {
            "device_id": "air-purifier",
            "name": "Bedroom Air Purifier",
            "connected": True,
            "adapter": "simulator",
            "capabilities": [
                {
                    "capability_id": "set_mode",
                    "name": "운전 모드 설정",
                    "description": "공기청정기 운전 모드를 설정합니다.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "mode": {
                                "type": "string",
                                "enum": ["sleep", "auto", "boost"],
                            }
                        },
                        "required": ["mode"],
                        "additionalProperties": False,
                    },
                }
            ],
        },
        "name": "set_air_purifier_mode",
        "description": "연결된 침실 공기청정기의 운전 모드를 설정합니다.",
        "capability_id": "set_mode",
        "confirmation_text": "공기청정기를 수면 모드로 바꿀까요?",
        "arguments": {"mode": "sleep"},
    },
    "fan": {
        "manifest": {
            "device_id": "fan",
            "name": "Bedroom Fan",
            "connected": True,
            "adapter": "simulator",
            "capabilities": [
                {
                    "capability_id": "set_power",
                    "name": "전원 설정",
                    "description": "선풍기 전원을 켜거나 끕니다.",
                    "parameters": {
                        "type": "object",
                        "properties": {"enabled": {"type": "boolean"}},
                        "required": ["enabled"],
                        "additionalProperties": False,
                    },
                }
            ],
        },
        "name": "set_fan_power",
        "description": "연결된 침실 선풍기의 전원을 안전하게 설정합니다.",
        "capability_id": "set_power",
        "confirmation_text": "선풍기 전원을 끌까요?",
        "arguments": {"enabled": False},
    },
}


def load_cases() -> list[dict[str, Any]]:
    return [
        json.loads(line)
        for line in CASES_PATH.read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]


class DeterministicNeedleRouter:
    def __init__(self, case: dict[str, Any]) -> None:
        self.case = case

    def route(self, _text: str, *, scope: str | None = None) -> NeedleRouteResult:
        tool_name = self.case.get("expected_tool")
        if tool_name:
            return NeedleRouteResult(
                matched=True,
                available=True,
                reason="matched",
                confidence=0.93,
                call=NeedleCall(
                    name=tool_name,
                    arguments=BUILTIN_ARGUMENTS[self.case["id"]],
                ),
            )
        return NeedleRouteResult(
            matched=False,
            available=True,
            reason="empty_call",
            confidence=0.91,
        )


class RecordingRouter:
    def __init__(self, router: Any) -> None:
        self.router = router
        self.results: list[NeedleRouteResult] = []

    def route(self, text: str, *, scope: str | None = None) -> NeedleRouteResult:
        result = self.router.route(text, scope=scope)
        self.results.append(result)
        return result


class DeterministicFallback:
    def __init__(self, case: dict[str, Any]) -> None:
        self.case = case

    async def __call__(self, _text: str, **context: Any) -> CommandFallbackDecision:
        expected_tool = self.case.get("expected_tool")
        if expected_tool:
            return self._decision(
                kind="builtin_tool",
                tool_name=expected_tool,
                arguments=encode_arguments(BUILTIN_ARGUMENTS[self.case["id"]]),
            )

        fixture_name = self.case.get("device_fixture")
        if fixture_name:
            fixture = DEVICE_FIXTURES[fixture_name]
            approved_tools = context.get("approved_tools", [])
            if approved_tools:
                return self._decision(
                    kind="existing_tool",
                    tool_name=approved_tools[0]["name"],
                    arguments=encode_arguments(fixture["arguments"]),
                )
            return self._decision(
                kind="tool_draft",
                message="새 기기 기능을 재사용 가능한 도구로 만들려면 승인이 필요합니다.",
                arguments=encode_arguments(fixture["arguments"]),
                name=fixture["name"],
                description=fixture["description"],
                device_id=fixture_name,
                capability_id=fixture["capability_id"],
                confirmation_text=fixture["confirmation_text"],
            )

        return self._decision(
            kind="chat",
            message="이 요청은 기기 명령이 아니므로 기존 대화로 이어갑니다.",
        )

    @staticmethod
    def _decision(**updates: Any) -> CommandFallbackDecision:
        values = {
            "kind": "chat",
            "message": None,
            "tool_name": None,
            "arguments": [],
            "name": None,
            "description": None,
            "device_id": None,
            "capability_id": None,
            "confirmation_text": None,
            **updates,
        }
        return CommandFallbackDecision.model_validate(values)


def encode_arguments(values: dict[str, Any]) -> list[dict[str, Any]]:
    arguments: list[dict[str, Any]] = []
    for name, value in values.items():
        item = {
            "name": name,
            "string_value": None,
            "integer_value": None,
            "number_value": None,
            "boolean_value": None,
        }
        if isinstance(value, bool):
            item["boolean_value"] = value
        elif isinstance(value, int):
            item["integer_value"] = value
        elif isinstance(value, float):
            item["number_value"] = value
        elif isinstance(value, str):
            item["string_value"] = value
        else:
            raise TypeError(f"unsupported eval argument value: {value!r}")
        arguments.append(item)
    return arguments


async def evaluate_case(
    case: dict[str, Any],
    *,
    live_needle: bool,
) -> dict[str, Any]:
    with TemporaryDirectory(prefix="adspace-eval-") as temporary_directory:
        registry = ToolRegistry(Path(temporary_directory) / "registry.json")
        if fixture_name := case.get("device_fixture"):
            registry.register_device(
                DeviceManifest.model_validate(DEVICE_FIXTURES[fixture_name]["manifest"])
            )

        base_router: Any
        if live_needle:
            base_router = NeedleRouter(registry.list_tools)
        else:
            base_router = DeterministicNeedleRouter(case)
        router = RecordingRouter(base_router)
        service = CommandService(
            registry,
            router,
            fallback_runner=DeterministicFallback(case),
        )
        request = CommandRouteRequest(
            text=case["text"],
            scope=case.get("scope"),
        )

        first = await service.route(request)
        final = first
        approved_tool_id: str | None = None
        execution_status: str | None = None
        if fixture_name := case.get("device_fixture"):
            if first.kind != "tool_draft" or first.draft is None or first.proposal is None:
                return result_payload(
                    case,
                    router,
                    first,
                    passed=False,
                    detail="new connected capability did not produce an approvable draft",
                )
            approval = service.approve_tool_draft(
                first.draft.draft_id,
                first.proposal.proposal_id,
            )
            approved_tool_id = approval.tool.tool_id
            execution = service.confirm_proposal(
                approval.execution_proposal.proposal_id,
            )
            execution_status = execution["result"]["status"]
            final = await service.route(request)

        actual_tool = final.proposal.action if final.proposal else None
        passed = final.kind == case["expected_kind"]
        if expected_tool := case.get("expected_tool"):
            passed = passed and actual_tool == expected_tool
        if case.get("device_fixture"):
            passed = (
                passed
                and final.proposal is not None
                and final.proposal.tool_id == approved_tool_id
                and execution_status == "simulated"
            )

        return result_payload(
            case,
            router,
            final,
            passed=passed,
            detail=None if passed else "final route did not match the expected contract",
            initial_kind=first.kind,
            approved_tool_id=approved_tool_id,
            execution_status=execution_status,
        )


def result_payload(
    case: dict[str, Any],
    router: RecordingRouter,
    response: Any,
    *,
    passed: bool,
    detail: str | None,
    initial_kind: str | None = None,
    approved_tool_id: str | None = None,
    execution_status: str | None = None,
) -> dict[str, Any]:
    return {
        "id": case["id"],
        "passed": passed,
        "expected_kind": case["expected_kind"],
        "initial_kind": initial_kind or response.kind,
        "final_kind": response.kind,
        "routed_by": response.routed_by,
        "tool": response.proposal.action if response.proposal else None,
        "approved_tool_id": approved_tool_id,
        "execution_status": execution_status,
        "needle": [
            {
                "matched": item.matched,
                "reason": item.reason,
                "confidence": item.confidence,
            }
            for item in router.results
        ],
        "detail": detail,
    }


async def main() -> int:
    live_needle = os.getenv("ADSPACE_EVAL_LIVE_NEEDLE") == "1"
    results = [
        await evaluate_case(case, live_needle=live_needle)
        for case in load_cases()
    ]
    passed = sum(item["passed"] for item in results)
    payload = {
        "mode": "live_needle" if live_needle else "deterministic",
        "passed": passed,
        "total": len(results),
        "results": results,
    }
    RESULTS_PATH.parent.mkdir(parents=True, exist_ok=True)
    RESULTS_PATH.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"command evals: {passed}/{len(results)} passed ({payload['mode']})")
    for item in results:
        if not item["passed"]:
            print(f"FAIL {item['id']}: {item['detail']}")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
