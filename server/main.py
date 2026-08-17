from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import secrets
from datetime import UTC, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from typing import Any, Awaitable, Callable, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from agent import (
    ChatContext,
    ChatRequest,
    ChatTurn,
    CommandArgument,
    CommandFallbackDecision,
    EnvironmentProfile,
    RecommendationRequest,
    chat,
    recommend,
    route_command_fallback,
)
from needle_router import BUILTIN_TOOL_NAMES, BUILTIN_TOOL_SCHEMAS, NeedleRouter
from tool_registry import (
    ApprovedTool,
    DeviceManifest,
    RegistryConflict,
    RegistryError,
    RegistryNotFound,
    RegistryValidationError,
    Scope,
    ToolDraft,
    ToolRegistry,
    validate_arguments,
)


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


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CommandRouteRequest(StrictModel):
    text: str = Field(min_length=1, max_length=1000)
    scope: Literal["home", "hotel"] | None = None
    session_id: str | None = Field(default=None, min_length=1, max_length=100)
    device_ids: list[str] = Field(default_factory=list, max_length=20)
    messages: list[ChatTurn] = Field(default_factory=list, max_length=12)
    context: ChatContext | None = None

    @model_validator(mode="after")
    def unique_device_ids(self) -> CommandRouteRequest:
        if len(set(self.device_ids)) != len(self.device_ids):
            raise ValueError("device_ids must be unique")
        return self


class CommandProposal(StrictModel):
    proposal_id: str = Field(pattern=r"^[0-9a-f]{32}$")
    action: str
    tool_name: str
    arguments: dict[str, Any]
    requires_confirmation: Literal[True] = True
    source: Literal["needle", "gpt"]
    confidence: float | None = Field(default=None, ge=0, le=1)
    tool_kind: Literal["builtin", "dynamic"]
    tool_id: str | None = None
    device_id: str
    capability_id: str
    scope: Scope
    session_id: str | None = None
    expires_at: str
    confirmation_text: str | None = None


class CommandRouteResponse(StrictModel):
    kind: Literal["builtin_proposal", "dynamic_proposal", "tool_draft", "chat"]
    routed_by: Literal["needle", "gpt"]
    proposal: CommandProposal | None = None
    draft: ToolDraft | None = None
    message: str | None = None
    fallback_reason: str | None = None

    @model_validator(mode="after")
    def validate_payload(self) -> CommandRouteResponse:
        if self.kind in {"builtin_proposal", "dynamic_proposal"} and self.proposal is None:
            raise ValueError("proposal response requires proposal")
        if self.kind == "tool_draft" and (self.draft is None or self.proposal is None):
            raise ValueError("tool_draft response requires draft and ephemeral proposal")
        if self.kind == "chat" and not self.message:
            raise ValueError("chat response requires message")
        return self


class ConnectDeviceRequest(StrictModel):
    connected: bool = True


class DynamicToolProposalRequest(StrictModel):
    arguments: dict[str, Any]
    scope: Scope | None = None


class BuiltinToolProposalRequest(StrictModel):
    arguments: dict[str, Any]
    scope: Scope | None = None
    session_id: str | None = Field(default=None, min_length=1, max_length=100)


class ProposalReferenceRequest(StrictModel):
    proposal_id: str = Field(pattern=r"^[0-9a-f]{32}$")


class ToolApprovalResponse(StrictModel):
    tool: ApprovedTool
    execution_proposal: CommandProposal


class ProposalRecord(StrictModel):
    proposal: CommandProposal
    state: Literal["pending", "confirmed", "rejected", "expired"] = "pending"
    draft_id: str | None = None
    manifest_revision: str | None = None
    session_id: str | None = None

    @model_validator(mode="after")
    def validate_session_binding(self) -> ProposalRecord:
        if self.proposal.session_id != self.session_id:
            raise ValueError("proposal session binding mismatch")
        return self


class ProposalExpired(RegistryError):
    code = "proposal_expired"


FallbackRunner = Callable[..., Awaitable[CommandFallbackDecision]]
ProposalClock = Callable[[], datetime]
PROPOSAL_TTL_SECONDS = 120
SESSION_BUILTIN_ACTIONS = {
    "apply_recommendation": "apply",
    "stop_environment": "stop",
    "restore_environment": "restore",
    "checkout_space": "checkout",
}


def decode_command_arguments(
    schema: dict[str, Any],
    arguments: list[CommandArgument],
) -> dict[str, Any]:
    properties = schema.get("properties", {})
    decoded: dict[str, Any] = {}
    for argument in arguments:
        if argument.name in decoded:
            raise RegistryValidationError(f"duplicate argument: {argument.name}")
        constraint = properties.get(argument.name)
        if not isinstance(constraint, dict):
            raise RegistryValidationError(f"unknown argument: {argument.name}")
        try:
            decoded[argument.name] = argument.value_for(constraint.get("type", ""))
        except ValueError as error:
            raise RegistryValidationError(str(error)) from error
    return validate_arguments(schema, decoded)


class CommandService:
    def __init__(
        self,
        registry: ToolRegistry,
        router: NeedleRouter,
        *,
        fallback_runner: FallbackRunner = route_command_fallback,
        proposal_clock: ProposalClock = lambda: datetime.now(UTC),
        proposal_ttl_seconds: int = PROPOSAL_TTL_SECONDS,
        max_proposals: int = 2048,
    ) -> None:
        if proposal_ttl_seconds <= 0:
            raise ValueError("proposal_ttl_seconds must be positive")
        if max_proposals <= 0:
            raise ValueError("max_proposals must be positive")
        self.registry = registry
        self.router = router
        self.fallback_runner = fallback_runner
        self.proposal_clock = proposal_clock
        self.proposal_ttl_seconds = proposal_ttl_seconds
        self.max_proposals = max_proposals
        self._proposal_lock = Lock()
        self._proposals: dict[str, ProposalRecord] = {}

    async def route(self, request: CommandRouteRequest) -> CommandRouteResponse:
        scope: Scope = request.scope or "home"
        devices = [
            device
            for device in self.registry.list_devices(connected_only=True)
            if scope in device.scopes
        ]
        if request.device_ids:
            requested_ids = set(request.device_ids)
            allowed_ids = {device.device_id for device in devices}
            unavailable_ids = requested_ids - allowed_ids
            if unavailable_ids:
                raise RegistryValidationError(
                    "unknown, disconnected, or out-of-scope devices: "
                    f"{sorted(unavailable_ids)}"
                )
            devices = [device for device in devices if device.device_id in requested_ids]
        allowed_device_ids = {device.device_id for device in devices}
        approved_tools = self.registry.eligible_tools(
            scope=scope,
            device_ids=allowed_device_ids,
        )
        tools_by_name = {tool.name: tool for tool in approved_tools}

        route_filtered = getattr(self.router, "route_filtered", None)
        if callable(route_filtered):
            needle_result = route_filtered(
                request.text,
                scope=scope,
                allowed_tool_ids={tool.tool_id for tool in approved_tools},
            )
        else:
            # Test doubles may only implement the legacy shape. Dynamic hits are still
            # checked against the eligible allowlist below before a proposal is issued.
            needle_result = self.router.route(request.text, scope=scope)
        if needle_result.matched and needle_result.call is not None:
            call = needle_result.call
            if call.name in BUILTIN_TOOL_NAMES:
                return CommandRouteResponse(
                    kind="builtin_proposal",
                    routed_by="needle",
                    proposal=self._new_builtin_proposal(
                        tool_name=call.name,
                        raw_arguments=call.arguments,
                        scope=scope,
                        session_id=request.session_id,
                        source="needle",
                        confidence=needle_result.confidence,
                    ),
                )
            approved_tool = tools_by_name.get(call.name)
            if approved_tool is not None:
                return CommandRouteResponse(
                    kind="dynamic_proposal",
                    routed_by="needle",
                    proposal=self._new_dynamic_proposal(
                        tool=approved_tool,
                        raw_arguments=call.arguments,
                        scope=scope,
                        source="needle",
                        confidence=needle_result.confidence,
                    ),
                )

        decision = await self.fallback_runner(
            request.text,
            connected_devices=[device.model_dump(mode="json") for device in devices],
            approved_tools=[tool.model_dump(mode="json") for tool in approved_tools],
            builtin_tools=BUILTIN_TOOL_SCHEMAS,
            scope=scope,
            chat_context=request.context.model_dump(mode="json") if request.context else None,
            recent_messages=[message.model_dump(mode="json") for message in request.messages],
        )
        if decision.kind == "chat":
            return CommandRouteResponse(
                kind="chat",
                routed_by="gpt",
                message=decision.message,
                fallback_reason=needle_result.reason,
            )
        if decision.kind in {"builtin_tool", "existing_tool"} and (
            decision.tool_name in BUILTIN_TOOL_NAMES
        ):
            schema = next(
                (
                    item
                    for item in BUILTIN_TOOL_SCHEMAS
                    if item["name"] == decision.tool_name
                ),
                None,
            )
            if schema is None:
                raise RegistryValidationError("GPT selected an unknown built-in tool")
            arguments = decode_command_arguments(schema["parameters"], decision.arguments)
            return CommandRouteResponse(
                kind="builtin_proposal",
                routed_by="gpt",
                proposal=self._new_builtin_proposal(
                    tool_name=decision.tool_name or "",
                    raw_arguments=arguments,
                    scope=scope,
                    session_id=request.session_id,
                    source="gpt",
                ),
                fallback_reason=needle_result.reason,
            )
        if decision.kind == "existing_tool":
            tool = tools_by_name.get(decision.tool_name or "")
            if tool is None:
                raise RegistryValidationError("GPT selected an unapproved or unavailable tool")
            arguments = decode_command_arguments(tool.parameters, decision.arguments)
            return CommandRouteResponse(
                kind="dynamic_proposal",
                routed_by="gpt",
                proposal=self._new_dynamic_proposal(
                    tool=tool,
                    raw_arguments=arguments,
                    scope=scope,
                    source="gpt",
                ),
                fallback_reason=needle_result.reason,
            )

        suggestion = decision.draft_suggestion()
        if suggestion.device_id not in allowed_device_ids:
            raise RegistryValidationError("GPT selected an unknown or disconnected device")
        device = next(item for item in devices if item.device_id == suggestion.device_id)
        capability = device.capability(suggestion.capability_id)
        if capability is None:
            raise RegistryValidationError("GPT selected an unknown device capability")
        arguments = decode_command_arguments(capability.parameters, decision.arguments)
        existing_tool = self.registry.tool_for_binding(
            suggestion.device_id,
            suggestion.capability_id,
            scope=scope,
        )
        if existing_tool is not None:
            eligible_tool = next(
                (tool for tool in approved_tools if tool.tool_id == existing_tool.tool_id),
                None,
            )
            if eligible_tool is None:
                raise RegistryValidationError(
                    "an approved tool exists for this binding but is currently unavailable"
                )
            return CommandRouteResponse(
                kind="dynamic_proposal",
                routed_by="gpt",
                proposal=self._new_dynamic_proposal(
                    tool=eligible_tool,
                    raw_arguments=arguments,
                    scope=scope,
                    source="gpt",
                ),
                message=decision.message,
                fallback_reason=needle_result.reason,
            )
        draft = self.registry.create_draft(suggestion, scope=scope)
        proposal = self._store_proposal(
            action="execute_dynamic_tool",
            tool_name=draft.name,
            arguments=arguments,
            source="gpt",
            confidence=None,
            tool_kind="dynamic",
            tool_id=None,
            device_id=draft.device_id,
            capability_id=draft.capability_id,
            scope=scope,
            confirmation_text=draft.confirmation_text,
            draft_id=draft.draft_id,
            manifest_revision=draft.manifest_revision,
        )
        return CommandRouteResponse(
            kind="tool_draft",
            routed_by="gpt",
            proposal=proposal,
            draft=draft,
            message=decision.message,
            fallback_reason=needle_result.reason,
        )

    def propose_dynamic_tool(
        self,
        tool_id: str,
        request: DynamicToolProposalRequest,
    ) -> CommandProposal:
        scope: Scope = request.scope or "home"
        tool, arguments = self.registry.validate_tool_proposal(
            tool_id,
            request.arguments,
            scope=scope,
        )
        return self._new_dynamic_proposal(
            tool=tool,
            raw_arguments=arguments,
            scope=scope,
            source="needle",
        )

    def propose_builtin_tool(
        self,
        tool_name: str,
        request: BuiltinToolProposalRequest,
    ) -> CommandProposal:
        return self._new_builtin_proposal(
            tool_name=tool_name,
            raw_arguments=request.arguments,
            scope=request.scope or "home",
            session_id=request.session_id,
            source="needle",
        )

    def confirm_proposal(self, proposal_id: str) -> dict[str, Any]:
        with self._proposal_lock:
            record = self._pending_proposal_locked(proposal_id)
            proposal = record.proposal
            if proposal.scope == "hotel" and record.session_id is not None:
                raise RegistryConflict(
                    "session-bound hotel proposal must use the session command endpoint"
                )
            if proposal.tool_kind == "dynamic" and proposal.tool_id is None:
                raise RegistryConflict("tool draft must be approved before execution confirmation")
            record.state = "confirmed"
            captured = record.model_copy(deep=True)

        proposal = captured.proposal
        if proposal.tool_kind == "builtin":
            # Stored arguments, never a confirmation request body, are returned to AppModel.
            return {
                "status": "confirmed",
                "proposal_id": proposal.proposal_id,
                "tool_kind": "builtin",
                "action": proposal.action,
                "arguments": proposal.arguments,
                "scope": proposal.scope,
            }

        result = self.registry.execute(
            proposal.tool_id or "",
            proposal.arguments,
            scope=proposal.scope,
            expected_device_id=proposal.device_id,
            expected_capability_id=proposal.capability_id,
            expected_manifest_revision=captured.manifest_revision,
        )
        return {
            "status": "executed",
            "proposal_id": proposal.proposal_id,
            "tool_kind": "dynamic",
            "action": proposal.action,
            "arguments": proposal.arguments,
            "scope": proposal.scope,
            "result": result,
        }

    def confirm_session_command(
        self,
        session_id: str,
        proposal_id: str,
        session_store: SessionStore,
    ) -> tuple[int, dict]:
        with self._proposal_lock:
            record = self._pending_proposal_locked(proposal_id)
            proposal = record.proposal
            mapped_action = SESSION_BUILTIN_ACTIONS.get(proposal.tool_name)
            if (
                record.session_id != session_id
                or proposal.session_id != session_id
                or proposal.scope != "hotel"
                or proposal.tool_kind != "builtin"
                or proposal.action != proposal.tool_name
                or mapped_action is None
                or proposal.arguments.get("scope") != "hotel"
            ):
                raise RegistryValidationError(
                    "proposal is not bound to this hotel session command"
                )
            schema = next(
                (
                    item
                    for item in BUILTIN_TOOL_SCHEMAS
                    if item["name"] == proposal.tool_name
                ),
                None,
            )
            if schema is None:
                raise RegistryValidationError("proposal references an unknown built-in tool")
            validate_arguments(schema["parameters"], proposal.arguments)
            record.state = "confirmed"

        # Execution uses only the action captured by the server-side proposal record.
        return session_store.command(session_id, mapped_action)

    def approve_tool_draft(
        self,
        draft_id: str,
        proposal_id: str,
    ) -> ToolApprovalResponse:
        draft = self.registry.draft_by_id(draft_id)
        if draft is None:
            raise RegistryNotFound(f"draft not found: {draft_id}")
        with self._proposal_lock:
            record = self._pending_proposal_locked(proposal_id)
            proposal = record.proposal
            if (
                record.draft_id != draft_id
                or proposal.tool_kind != "dynamic"
                or proposal.tool_id is not None
                or proposal.tool_name != draft.name
                or proposal.device_id != draft.device_id
                or proposal.capability_id != draft.capability_id
                or proposal.scope not in draft.scopes
                or record.manifest_revision != draft.manifest_revision
            ):
                raise RegistryValidationError("proposal is not bound to this tool draft")
            validate_arguments(draft.parameters, proposal.arguments)
            record.state = "confirmed"
            captured = record.model_copy(deep=True)

        tool = self.registry.approve_draft(draft_id)
        execution_proposal = self._new_dynamic_proposal(
            tool=tool,
            raw_arguments=captured.proposal.arguments,
            scope=captured.proposal.scope,
            source=captured.proposal.source,
            confidence=captured.proposal.confidence,
        )
        return ToolApprovalResponse(tool=tool, execution_proposal=execution_proposal)

    def reject_tool_draft(self, draft_id: str, proposal_id: str) -> ToolDraft:
        draft = self.registry.draft_by_id(draft_id)
        if draft is None:
            raise RegistryNotFound(f"draft not found: {draft_id}")
        with self._proposal_lock:
            record = self._pending_proposal_locked(proposal_id)
            proposal = record.proposal
            if (
                record.draft_id != draft_id
                or proposal.tool_id is not None
                or proposal.device_id != draft.device_id
                or proposal.capability_id != draft.capability_id
                or record.manifest_revision != draft.manifest_revision
            ):
                raise RegistryValidationError("proposal is not bound to this tool draft")
            record.state = "rejected"
        return self.registry.reject_draft(draft_id)

    def _new_builtin_proposal(
        self,
        *,
        tool_name: str,
        raw_arguments: dict[str, Any],
        scope: Scope,
        session_id: str | None,
        source: Literal["needle", "gpt"],
        confidence: float | None = None,
    ) -> CommandProposal:
        schema = next(
            (item for item in BUILTIN_TOOL_SCHEMAS if item["name"] == tool_name),
            None,
        )
        if schema is None:
            raise RegistryValidationError("unknown built-in tool")
        if session_id is not None and scope != "hotel":
            raise RegistryValidationError("session_id is valid only for hotel scope")
        arguments = dict(raw_arguments)
        inferred_scope = arguments.get("scope")
        if inferred_scope is not None and inferred_scope != scope:
            raise RegistryValidationError("built-in tool selected the wrong space scope")
        arguments["scope"] = scope
        if tool_name == "checkout_space" and scope != "hotel":
            raise RegistryValidationError("checkout is available only for hotel scope")
        if tool_name == "adjust_environment" and scope != "home":
            raise RegistryValidationError("adjust_environment is available only for home scope")
        if tool_name == "adjust_environment" and not (
            set(arguments) & {"brightness_delta", "temperature_delta_c", "sound_preset"}
        ):
            raise RegistryValidationError("adjust_environment requires an adjustment")
        arguments = validate_arguments(schema["parameters"], arguments)
        return self._store_proposal(
            action=tool_name,
            tool_name=tool_name,
            arguments=arguments,
            source=source,
            confidence=confidence,
            tool_kind="builtin",
            tool_id=None,
            device_id="app-model",
            capability_id=tool_name,
            scope=scope,
            session_id=session_id,
            confirmation_text=f"{tool_name} 명령을 실행할까요?",
        )

    def _new_dynamic_proposal(
        self,
        *,
        tool: ApprovedTool,
        raw_arguments: dict[str, Any],
        scope: Scope,
        source: Literal["needle", "gpt"],
        confidence: float | None = None,
    ) -> CommandProposal:
        current_tool, arguments = self.registry.validate_tool_proposal(
            tool.tool_id,
            raw_arguments,
            scope=scope,
        )
        if current_tool != tool:
            raise RegistryValidationError("approved tool changed while creating proposal")
        return self._store_proposal(
            action="execute_dynamic_tool",
            tool_name=tool.name,
            arguments=arguments,
            source=source,
            confidence=confidence,
            tool_kind="dynamic",
            tool_id=tool.tool_id,
            device_id=tool.device_id,
            capability_id=tool.capability_id,
            scope=scope,
            confirmation_text=tool.confirmation_text,
            manifest_revision=tool.manifest_revision,
        )

    def _store_proposal(
        self,
        *,
        action: str,
        tool_name: str,
        arguments: dict[str, Any],
        source: Literal["needle", "gpt"],
        confidence: float | None,
        tool_kind: Literal["builtin", "dynamic"],
        tool_id: str | None,
        device_id: str,
        capability_id: str,
        scope: Scope,
        confirmation_text: str | None,
        session_id: str | None = None,
        draft_id: str | None = None,
        manifest_revision: str | None = None,
    ) -> CommandProposal:
        now = self._now()
        expires_at = (now + timedelta(seconds=self.proposal_ttl_seconds)).isoformat()
        with self._proposal_lock:
            expired_ids = [
                existing_id
                for existing_id, record in self._proposals.items()
                if now >= datetime.fromisoformat(record.proposal.expires_at)
            ]
            for expired_id in expired_ids:
                del self._proposals[expired_id]
            if len(self._proposals) >= self.max_proposals:
                terminal_records = sorted(
                    (
                        (existing_id, record)
                        for existing_id, record in self._proposals.items()
                        if record.state != "pending"
                    ),
                    key=lambda item: datetime.fromisoformat(
                        item[1].proposal.expires_at
                    ),
                )
                for terminal_id, _ in terminal_records:
                    del self._proposals[terminal_id]
                    if len(self._proposals) < self.max_proposals:
                        break
            if len(self._proposals) >= self.max_proposals:
                raise RegistryConflict("too many pending command proposals")
            proposal_id = secrets.token_hex(16)
            while proposal_id in self._proposals:
                proposal_id = secrets.token_hex(16)
            proposal = CommandProposal(
                proposal_id=proposal_id,
                action=action,
                tool_name=tool_name,
                arguments=arguments,
                source=source,
                confidence=confidence,
                tool_kind=tool_kind,
                tool_id=tool_id,
                device_id=device_id,
                capability_id=capability_id,
                scope=scope,
                session_id=session_id,
                expires_at=expires_at,
                confirmation_text=confirmation_text,
            )
            self._proposals[proposal_id] = ProposalRecord(
                proposal=proposal.model_copy(deep=True),
                draft_id=draft_id,
                manifest_revision=manifest_revision,
                session_id=session_id,
            )
        return proposal.model_copy(deep=True)

    def _pending_proposal_locked(self, proposal_id: str) -> ProposalRecord:
        record = self._proposals.get(proposal_id)
        if record is None:
            raise RegistryNotFound(f"command proposal not found: {proposal_id}")
        expires_at = datetime.fromisoformat(record.proposal.expires_at)
        if self._now() >= expires_at:
            record.state = "expired"
            raise ProposalExpired(f"command proposal expired: {proposal_id}")
        if record.state != "pending":
            raise RegistryConflict(f"command proposal is already {record.state}")
        return record

    def _now(self) -> datetime:
        value = self.proposal_clock()
        if value.tzinfo is None:
            raise ValueError("proposal clock must return a timezone-aware datetime")
        return value.astimezone(UTC)


REGISTRY_PATH = Path(
    os.getenv(
        "ADSPACE_TOOL_REGISTRY_PATH",
        str(Path(__file__).resolve().parent / "data" / "tool_registry.json"),
    )
)
REGISTRY = ToolRegistry(REGISTRY_PATH, reserved_tool_names=BUILTIN_TOOL_NAMES)
NEEDLE_ROUTER = NeedleRouter(REGISTRY.list_tools)
COMMAND_SERVICE = CommandService(REGISTRY, NEEDLE_ROUTER)


class Handler(BaseHTTPRequestHandler):
    session_store = STORE
    registry = REGISTRY
    command_service = COMMAND_SERVICE

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
        payload = json.loads(self.rfile.read(length) or b"{}")
        if not isinstance(payload, dict):
            raise ValueError("request body must be a JSON object")
        return payload

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_json(200, {"status": "ok", "model": os.getenv("OPENAI_MODEL", "gpt-5.6-luna")})
        elif self.path == "/v1/spaces/hotel-demo-room":
            self.send_json(200, SPACE)
        elif self.path == "/v1/devices":
            self.send_json(
                200,
                {
                    "devices": [
                        device.model_dump(mode="json") for device in self.registry.list_devices()
                    ]
                },
            )
        elif self.path == "/v1/tools":
            self.send_json(
                200,
                {
                    "tools": [
                        tool.model_dump(mode="json") for tool in self.registry.list_tools()
                    ]
                },
            )
        elif self.path == "/v1/tool-drafts":
            self.send_json(
                200,
                {
                    "drafts": [
                        draft.model_dump(mode="json") for draft in self.registry.list_drafts()
                    ]
                },
            )
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

            if self.path == "/v1/chat":
                request = ChatRequest.model_validate(body)
                try:
                    response = asyncio.run(chat(request))
                except Exception as error:
                    print(f"Agents SDK chat unavailable: {type(error).__name__}")
                    self.send_json(503, {"error": "agent_unavailable"})
                    return
                self.send_json(200, response.model_dump(mode="json"))
                return

            if self.path == "/v1/commands/route":
                request = CommandRouteRequest.model_validate(body)
                try:
                    response = asyncio.run(self.command_service.route(request))
                except RegistryError:
                    raise
                except Exception as error:
                    print(f"Agents SDK command fallback unavailable: {type(error).__name__}")
                    self.send_json(503, {"error": "agent_unavailable"})
                    return
                self.send_json(200, response.model_dump(mode="json"))
                return

            if self.path == "/v1/devices":
                manifest = DeviceManifest.model_validate(body)
                if manifest.connected:
                    self.send_json(422, {"error": "device_must_be_connected_explicitly"})
                    return
                device = self.registry.register_device(manifest)
                self.send_json(201, device.model_dump(mode="json"))
                return

            match = re.fullmatch(r"/v1/devices/([^/]+)/connect", self.path)
            if match:
                request = ConnectDeviceRequest.model_validate(body)
                device = self.registry.connect_device(match.group(1), request.connected)
                self.send_json(200, device.model_dump(mode="json"))
                return

            match = re.fullmatch(r"/v1/tool-drafts/([^/]+)/(approve|reject)", self.path)
            if match:
                request = ProposalReferenceRequest.model_validate(body)
                draft_id, action = match.groups()
                if action == "approve":
                    response = self.command_service.approve_tool_draft(
                        draft_id,
                        request.proposal_id,
                    )
                    self.send_json(201, response.model_dump(mode="json"))
                else:
                    draft = self.command_service.reject_tool_draft(
                        draft_id,
                        request.proposal_id,
                    )
                    self.send_json(200, draft.model_dump(mode="json"))
                return

            match = re.fullmatch(r"/v1/builtin-tools/([^/]+)/proposals", self.path)
            if match:
                request = BuiltinToolProposalRequest.model_validate(body)
                proposal = self.command_service.propose_builtin_tool(
                    match.group(1),
                    request,
                )
                self.send_json(201, proposal.model_dump(mode="json"))
                return

            match = re.fullmatch(r"/v1/tools/([^/]+)/proposals", self.path)
            if match:
                request = DynamicToolProposalRequest.model_validate(body)
                proposal = self.command_service.propose_dynamic_tool(
                    match.group(1),
                    request,
                )
                self.send_json(201, proposal.model_dump(mode="json"))
                return

            match = re.fullmatch(r"/v1/command-proposals/([0-9a-f]{32})/confirm", self.path)
            if match:
                if body:
                    raise ValueError("proposal confirmation body must be empty")
                response = self.command_service.confirm_proposal(match.group(1))
                self.send_json(200, response)
                return

            if self.path == "/v1/spaces/hotel-demo-room/sessions":
                allowed = {"profile", "ttl_seconds"}
                if set(body) - allowed or "profile" not in body:
                    self.send_json(422, {"error": "invalid_or_private_fields"})
                    return
                profile = EnvironmentProfile.model_validate(body["profile"])
                ttl = max(60, min(3600, int(body.get("ttl_seconds", 900))))
                self.send_json(201, self.session_store.create(profile, ttl))
                return

            match = re.fullmatch(r"/v1/sessions/([^/]+)/commands", self.path)
            if match:
                request = ProposalReferenceRequest.model_validate(body)
                status, response = self.command_service.confirm_session_command(
                    match.group(1),
                    request.proposal_id,
                    self.session_store,
                )
                self.send_json(status, response)
                return
            self.send_json(404, {"error": "not_found"})
        except RegistryNotFound as error:
            self.send_json(404, {"error": error.code, "detail": str(error)})
        except ProposalExpired as error:
            self.send_json(410, {"error": error.code, "detail": str(error)})
        except RegistryConflict as error:
            self.send_json(409, {"error": error.code, "detail": str(error)})
        except RegistryValidationError as error:
            self.send_json(422, {"error": error.code, "detail": str(error)})
        except (ValidationError, ValueError, json.JSONDecodeError) as error:
            self.send_json(422, {"error": "invalid_request", "detail": str(error)})


def make_handler(
    *,
    session_store: SessionStore,
    registry: ToolRegistry,
    command_service: CommandService,
) -> type[Handler]:
    """Create an isolated handler for tests or alternate local registry paths."""

    class ConfiguredHandler(Handler):
        pass

    ConfiguredHandler.session_store = session_store
    ConfiguredHandler.registry = registry
    ConfiguredHandler.command_service = command_service
    return ConfiguredHandler


def sample_request() -> RecommendationRequest:
    recent_snapshots = [
        {
            "id": f"demo-conflict-{index}",
            "source": "demo",
            "captured_at": f"2026-08-15T00:00:0{index}Z",
            "sleep_score": 74,
            "activity_steps": steps,
            "heart_rate_bpm": heart_rate,
            "hrv_ms": hrv,
            "time_of_day": "afternoon",
        }
        for index, (steps, heart_rate, hrv) in enumerate(
            [(4110, 58, 55), (4120, 65, 48), (4130, 72, 39), (4140, 80, 30)],
            start=1,
        )
    ]
    return RecommendationRequest.model_validate(
        {
            "snapshot": recent_snapshots[-1],
            "recent_snapshots": recent_snapshots,
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
