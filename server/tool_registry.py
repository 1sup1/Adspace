from __future__ import annotations

import json
import hashlib
import math
import os
import re
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from threading import RLock
from typing import Any, Literal
from uuid import uuid4

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


IDENTIFIER_PATTERN = r"^[a-z][a-z0-9_.-]{0,63}$"
TOOL_NAME_PATTERN = r"^[a-z][a-z0-9_]{1,63}$"
MANIFEST_REVISION_PATTERN = r"^[0-9a-f]{64}$"
_IDENTIFIER = re.compile(IDENTIFIER_PATTERN)
_SCALAR_TYPES = {"string", "integer", "number", "boolean"}
_PROPERTY_KEYS = {
    "type",
    "description",
    "enum",
    "const",
    "minimum",
    "maximum",
    "exclusiveMinimum",
    "exclusiveMaximum",
    "multipleOf",
    "minLength",
    "maxLength",
}
_FORBIDDEN_EXECUTABLE_KEYS = {
    "code",
    "script",
    "command",
    "shell",
    "url",
    "endpoint",
    "module",
    "import",
    "handler",
}

Scope = Literal["home", "hotel"]


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RegistryError(ValueError):
    code = "registry_error"


class RegistryNotFound(RegistryError):
    code = "not_found"


class RegistryConflict(RegistryError):
    code = "conflict"


class RegistryValidationError(RegistryError):
    code = "invalid_registry_value"


def _json_scalar(value: Any, expected_type: str) -> bool:
    if expected_type == "boolean":
        return isinstance(value, bool)
    if expected_type == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected_type == "number":
        return isinstance(value, int | float) and not isinstance(value, bool) and math.isfinite(value)
    return isinstance(value, str)


def normalize_parameters_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """Validate the deliberately small, non-executable JSON Schema subset we support."""
    if not isinstance(schema, dict):
        raise ValueError("parameters must be a JSON object")
    allowed_root = {"type", "properties", "required", "additionalProperties"}
    unknown_root = set(schema) - allowed_root
    if unknown_root:
        raise ValueError(f"unsupported parameters keywords: {sorted(unknown_root)}")
    if schema.get("type") != "object":
        raise ValueError("parameters.type must be object")

    raw_properties = schema.get("properties", {})
    if not isinstance(raw_properties, dict) or len(raw_properties) > 24:
        raise ValueError("parameters.properties must contain at most 24 fields")
    properties: dict[str, Any] = {}
    for name, raw_property in raw_properties.items():
        if not isinstance(name, str) or not _IDENTIFIER.fullmatch(name):
            raise ValueError(f"invalid parameter name: {name!r}")
        if not isinstance(raw_property, dict):
            raise ValueError(f"parameter {name} must be a JSON object")
        unknown = set(raw_property) - _PROPERTY_KEYS
        if unknown or set(raw_property) & _FORBIDDEN_EXECUTABLE_KEYS:
            raise ValueError(f"unsupported schema keywords for {name}: {sorted(unknown)}")
        property_type = raw_property.get("type")
        if property_type not in _SCALAR_TYPES:
            raise ValueError(f"unsupported type for {name}: {property_type!r}")
        normalized = dict(raw_property)
        if "description" in normalized:
            description = normalized["description"]
            if not isinstance(description, str) or not 1 <= len(description) <= 240:
                raise ValueError(f"invalid description for {name}")

        for key in ("minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum", "multipleOf"):
            if key in normalized:
                number = normalized[key]
                if (
                    property_type not in {"integer", "number"}
                    or not isinstance(number, int | float)
                    or isinstance(number, bool)
                    or not math.isfinite(number)
                ):
                    raise ValueError(f"invalid {key} for {name}")
        if "multipleOf" in normalized and normalized["multipleOf"] <= 0:
            raise ValueError(f"multipleOf must be positive for {name}")
        if "minimum" in normalized and "maximum" in normalized:
            if normalized["minimum"] > normalized["maximum"]:
                raise ValueError(f"minimum exceeds maximum for {name}")

        for key in ("minLength", "maxLength"):
            if key in normalized:
                value = normalized[key]
                if property_type != "string" or not isinstance(value, int) or isinstance(value, bool) or value < 0:
                    raise ValueError(f"invalid {key} for {name}")
        if "minLength" in normalized and "maxLength" in normalized:
            if normalized["minLength"] > normalized["maxLength"]:
                raise ValueError(f"minLength exceeds maxLength for {name}")

        for key in ("enum",):
            if key in normalized:
                choices = normalized[key]
                if not isinstance(choices, list) or not 1 <= len(choices) <= 32:
                    raise ValueError(f"invalid enum for {name}")
                if any(not _json_scalar(choice, property_type) for choice in choices):
                    raise ValueError(f"enum value has wrong type for {name}")
                if len({json.dumps(choice, sort_keys=True) for choice in choices}) != len(choices):
                    raise ValueError(f"enum contains duplicates for {name}")
        if "const" in normalized and not _json_scalar(normalized["const"], property_type):
            raise ValueError(f"const value has wrong type for {name}")
        properties[name] = normalized

    raw_required = schema.get("required", [])
    if not isinstance(raw_required, list) or any(not isinstance(item, str) for item in raw_required):
        raise ValueError("parameters.required must be a string array")
    if len(set(raw_required)) != len(raw_required) or set(raw_required) - set(properties):
        raise ValueError("parameters.required contains unknown or duplicate fields")
    if schema.get("additionalProperties", False) is not False:
        raise ValueError("additionalProperties must be false")
    return {
        "type": "object",
        "properties": properties,
        "required": raw_required,
        "additionalProperties": False,
    }


def validate_arguments(schema: dict[str, Any], arguments: dict[str, Any]) -> dict[str, Any]:
    normalized_schema = normalize_parameters_schema(schema)
    if not isinstance(arguments, dict):
        raise RegistryValidationError("arguments must be a JSON object")
    properties = normalized_schema["properties"]
    unknown = set(arguments) - set(properties)
    missing = set(normalized_schema["required"]) - set(arguments)
    if unknown:
        raise RegistryValidationError(f"unknown arguments: {sorted(unknown)}")
    if missing:
        raise RegistryValidationError(f"missing arguments: {sorted(missing)}")

    for name, value in arguments.items():
        constraint = properties[name]
        expected_type = constraint["type"]
        if not _json_scalar(value, expected_type):
            raise RegistryValidationError(f"argument {name} must be {expected_type}")
        if "enum" in constraint and value not in constraint["enum"]:
            raise RegistryValidationError(f"argument {name} is not an allowed value")
        if "const" in constraint and value != constraint["const"]:
            raise RegistryValidationError(f"argument {name} does not match const")
        if expected_type in {"integer", "number"}:
            if "minimum" in constraint and value < constraint["minimum"]:
                raise RegistryValidationError(f"argument {name} is below minimum")
            if "maximum" in constraint and value > constraint["maximum"]:
                raise RegistryValidationError(f"argument {name} exceeds maximum")
            if "exclusiveMinimum" in constraint and value <= constraint["exclusiveMinimum"]:
                raise RegistryValidationError(f"argument {name} is below exclusiveMinimum")
            if "exclusiveMaximum" in constraint and value >= constraint["exclusiveMaximum"]:
                raise RegistryValidationError(f"argument {name} exceeds exclusiveMaximum")
            if "multipleOf" in constraint:
                quotient = value / constraint["multipleOf"]
                if not math.isclose(quotient, round(quotient), abs_tol=1e-9):
                    raise RegistryValidationError(f"argument {name} is not a valid multiple")
        if expected_type == "string":
            if "minLength" in constraint and len(value) < constraint["minLength"]:
                raise RegistryValidationError(f"argument {name} is too short")
            if "maxLength" in constraint and len(value) > constraint["maxLength"]:
                raise RegistryValidationError(f"argument {name} is too long")
    return dict(arguments)


class DeviceCapability(StrictModel):
    capability_id: str = Field(pattern=IDENTIFIER_PATTERN)
    name: str = Field(min_length=1, max_length=80)
    description: str = Field(min_length=1, max_length=300)
    parameters: dict[str, Any]

    @field_validator("parameters")
    @classmethod
    def validate_parameters(cls, value: dict[str, Any]) -> dict[str, Any]:
        return normalize_parameters_schema(value)


class DeviceManifest(StrictModel):
    device_id: str = Field(pattern=IDENTIFIER_PATTERN)
    name: str = Field(min_length=1, max_length=80)
    capabilities: list[DeviceCapability] = Field(min_length=1, max_length=24)
    scopes: list[Scope] = Field(default_factory=lambda: ["home"], min_length=1, max_length=2)
    connected: bool = False
    adapter: Literal["simulator"] = "simulator"

    @field_validator("scopes")
    @classmethod
    def normalize_scopes(cls, value: list[Scope]) -> list[Scope]:
        if len(set(value)) != len(value):
            raise ValueError("device scopes must be unique")
        return sorted(value, key=("home", "hotel").index)

    @model_validator(mode="after")
    def unique_capabilities(self) -> DeviceManifest:
        ids = [capability.capability_id for capability in self.capabilities]
        if len(set(ids)) != len(ids):
            raise ValueError("capability_id values must be unique")
        return self

    def capability(self, capability_id: str) -> DeviceCapability | None:
        return next(
            (item for item in self.capabilities if item.capability_id == capability_id),
            None,
        )

    def revision(self) -> str:
        """Fingerprint the allowlisted manifest, excluding transient connection state."""
        payload = self.model_dump(mode="json", exclude={"connected"})
        return hashlib.sha256(
            json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()


class ToolDraftSuggestion(StrictModel):
    name: str = Field(pattern=TOOL_NAME_PATTERN)
    description: str = Field(min_length=8, max_length=240)
    device_id: str = Field(pattern=IDENTIFIER_PATTERN)
    capability_id: str = Field(pattern=IDENTIFIER_PATTERN)
    confirmation_text: str = Field(min_length=4, max_length=160)


class ToolDraft(ToolDraftSuggestion):
    draft_id: str = Field(default_factory=lambda: f"draft-{uuid4().hex[:12]}")
    parameters: dict[str, Any]
    scopes: list[Scope] = Field(min_length=1, max_length=1)
    manifest_revision: str = Field(pattern=MANIFEST_REVISION_PATTERN)
    status: Literal["pending", "approved", "rejected"] = "pending"
    created_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat())
    reviewed_at: str | None = None

    @field_validator("parameters")
    @classmethod
    def validate_parameters(cls, value: dict[str, Any]) -> dict[str, Any]:
        return normalize_parameters_schema(value)

    @field_validator("scopes")
    @classmethod
    def normalize_scopes(cls, value: list[Scope]) -> list[Scope]:
        if not value or len(set(value)) != len(value):
            raise ValueError("tool draft scopes must be non-empty and unique")
        return sorted(value, key=("home", "hotel").index)


class ApprovedTool(StrictModel):
    tool_id: str = Field(default_factory=lambda: f"tool-{uuid4().hex[:12]}")
    draft_id: str
    name: str = Field(pattern=TOOL_NAME_PATTERN)
    description: str = Field(min_length=8, max_length=240)
    device_id: str = Field(pattern=IDENTIFIER_PATTERN)
    capability_id: str = Field(pattern=IDENTIFIER_PATTERN)
    parameters: dict[str, Any]
    scopes: list[Scope] = Field(min_length=1, max_length=1)
    manifest_revision: str = Field(pattern=MANIFEST_REVISION_PATTERN)
    confirmation_text: str = Field(min_length=4, max_length=160)
    approved_at: str = Field(default_factory=lambda: datetime.now(UTC).isoformat())
    enabled: bool = True

    @field_validator("parameters")
    @classmethod
    def validate_parameters(cls, value: dict[str, Any]) -> dict[str, Any]:
        return normalize_parameters_schema(value)

    @field_validator("scopes")
    @classmethod
    def normalize_scopes(cls, value: list[Scope]) -> list[Scope]:
        if not value or len(set(value)) != len(value):
            raise ValueError("approved tool scopes must be non-empty and unique")
        return sorted(value, key=("home", "hotel").index)

    def needle_schema(self) -> dict[str, Any]:
        return {
            "name": self.name,
            "description": self.description,
            "parameters": self.parameters,
        }


class RegistryState(StrictModel):
    version: Literal[1] = 1
    devices: list[DeviceManifest] = Field(default_factory=list)
    drafts: list[ToolDraft] = Field(default_factory=list)
    tools: list[ApprovedTool] = Field(default_factory=list)
    device_state: dict[str, dict[str, dict[str, Any]]] = Field(default_factory=dict)


class ToolRegistry:
    def __init__(
        self,
        path: str | Path,
        *,
        reserved_tool_names: set[str] | None = None,
    ) -> None:
        self.path = Path(path)
        self.reserved_tool_names = set(reserved_tool_names or ())
        self.lock = RLock()
        self._state = self._load()

    def _load(self) -> RegistryState:
        if not self.path.exists():
            return RegistryState()
        try:
            payload = json.loads(self.path.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise ValueError("registry root must be an object")
            self._migrate_v1_bindings(payload)
            return RegistryState.model_validate(payload)
        except (OSError, ValueError) as error:
            raise RegistryValidationError(f"invalid registry file: {error}") from error

    @staticmethod
    def _migrate_v1_bindings(payload: dict[str, Any]) -> None:
        """Backfill security bindings added to the original version-1 registry shape."""
        raw_devices = payload.get("devices", [])
        if not isinstance(raw_devices, list):
            return
        devices: dict[str, DeviceManifest] = {}
        for raw_device in raw_devices:
            if not isinstance(raw_device, dict):
                continue
            try:
                device = DeviceManifest.model_validate(raw_device)
            except ValueError:
                continue
            raw_device.setdefault("scopes", device.scopes)
            devices[device.device_id] = device

        for collection_name in ("drafts", "tools"):
            raw_collection = payload.get(collection_name, [])
            if not isinstance(raw_collection, list):
                continue
            for raw_binding in raw_collection:
                if not isinstance(raw_binding, dict):
                    continue
                device = devices.get(raw_binding.get("device_id"))
                if device is None:
                    # A missing device remains loadable but fails every live revalidation.
                    raw_binding.setdefault("scopes", ["home"])
                    raw_binding.setdefault("manifest_revision", "0" * 64)
                    continue
                raw_scopes = raw_binding.get("scopes")
                if not isinstance(raw_scopes, list) or len(raw_scopes) != 1:
                    approved_scope = "home" if "home" in device.scopes else device.scopes[0]
                    raw_binding["scopes"] = [approved_scope]
                capability = device.capability(str(raw_binding.get("capability_id", "")))
                if capability is not None and capability.parameters == raw_binding.get("parameters"):
                    revision = device.revision()
                else:
                    revision = "0" * 64
                raw_binding.setdefault("manifest_revision", revision)

    def _persist_locked(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd, temporary_name = tempfile.mkstemp(
            prefix=f".{self.path.name}.",
            suffix=".tmp",
            dir=self.path.parent,
        )
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(self._state.model_dump_json(indent=2))
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary_name, self.path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)

    def list_devices(self, *, connected_only: bool = False) -> list[DeviceManifest]:
        with self.lock:
            devices = self._state.devices
            if connected_only:
                devices = [device for device in devices if device.connected]
            return [device.model_copy(deep=True) for device in devices]

    def register_device(self, manifest: DeviceManifest) -> DeviceManifest:
        with self.lock:
            if any(item.device_id == manifest.device_id for item in self._state.devices):
                raise RegistryConflict(f"device already exists: {manifest.device_id}")
            self._state.devices.append(manifest.model_copy(deep=True))
            self._persist_locked()
            return manifest.model_copy(deep=True)

    def connect_device(self, device_id: str, connected: bool = True) -> DeviceManifest:
        with self.lock:
            device = self._device_locked(device_id)
            index = self._state.devices.index(device)
            updated = device.model_copy(update={"connected": connected})
            self._state.devices[index] = updated
            self._persist_locked()
            return updated.model_copy(deep=True)

    def create_draft(
        self,
        suggestion: ToolDraftSuggestion,
        *,
        scope: Scope = "home",
    ) -> ToolDraft:
        with self.lock:
            device = self._device_locked(suggestion.device_id)
            if not device.connected:
                raise RegistryValidationError("tool drafts require a connected device")
            if scope not in device.scopes:
                raise RegistryValidationError("device is not allowed in this scope")
            capability = device.capability(suggestion.capability_id)
            if capability is None:
                raise RegistryValidationError(
                    f"unknown capability {suggestion.capability_id!r} for {device.device_id!r}"
                )
            if any(
                tool.enabled
                and tool.device_id == suggestion.device_id
                and tool.capability_id == suggestion.capability_id
                and scope in tool.scopes
                for tool in self._state.tools
            ):
                raise RegistryConflict(
                    "an approved tool already owns this device capability binding"
                )
            existing_draft = next(
                (
                    draft
                    for draft in self._state.drafts
                    if draft.status == "pending"
                    and draft.device_id == suggestion.device_id
                    and draft.capability_id == suggestion.capability_id
                    and scope in draft.scopes
                ),
                None,
            )
            if existing_draft is not None:
                if (
                    existing_draft.parameters != capability.parameters
                    or not set(existing_draft.scopes).issubset(device.scopes)
                    or existing_draft.manifest_revision != device.revision()
                ):
                    raise RegistryValidationError(
                        "pending tool draft no longer matches its device manifest"
                    )
                return existing_draft.model_copy(deep=True)
            used_names = self.reserved_tool_names | {
                tool.name for tool in self._state.tools if tool.enabled
            }
            used_names |= {
                draft.name for draft in self._state.drafts if draft.status == "pending"
            }
            tool_name = suggestion.name
            if tool_name in used_names:
                same_binding_names = {
                    item.name
                    for item in [*self._state.tools, *self._state.drafts]
                    if item.device_id == suggestion.device_id
                    and item.capability_id == suggestion.capability_id
                    and (
                        not isinstance(item, ToolDraft)
                        or item.status == "pending"
                    )
                }
                if tool_name not in same_binding_names:
                    raise RegistryConflict(f"tool name already exists: {tool_name}")
                scope_suffix = f"_{scope}"
                tool_name = f"{tool_name[: 64 - len(scope_suffix)]}{scope_suffix}"
                if tool_name in used_names:
                    raise RegistryConflict(f"tool name already exists: {tool_name}")
            draft = ToolDraft(
                name=tool_name,
                description=(
                    f"{device.name}의 {capability.name} 기능을 실행합니다."
                )[:240],
                device_id=suggestion.device_id,
                capability_id=suggestion.capability_id,
                confirmation_text=(
                    f"{device.name}의 {capability.name} 기능을 실행할까요?"
                )[:160],
                parameters=capability.parameters,
                scopes=[scope],
                manifest_revision=device.revision(),
            )
            self._state.drafts.append(draft)
            self._persist_locked()
            return draft.model_copy(deep=True)

    def list_drafts(self) -> list[ToolDraft]:
        with self.lock:
            return [draft.model_copy(deep=True) for draft in self._state.drafts]

    def draft_by_id(self, draft_id: str) -> ToolDraft | None:
        with self.lock:
            draft = next(
                (item for item in self._state.drafts if item.draft_id == draft_id),
                None,
            )
            return draft.model_copy(deep=True) if draft is not None else None

    def approve_draft(self, draft_id: str) -> ApprovedTool:
        with self.lock:
            draft = self._draft_locked(draft_id)
            if draft.status != "pending":
                raise RegistryConflict(f"draft is already {draft.status}")
            device = self._device_locked(draft.device_id)
            if not device.connected:
                raise RegistryValidationError("device is not connected")
            capability = device.capability(draft.capability_id)
            if (
                capability is None
                or capability.parameters != draft.parameters
                or not set(draft.scopes).issubset(device.scopes)
                or device.revision() != draft.manifest_revision
            ):
                raise RegistryValidationError("device capability changed after draft creation")
            if any(tool.enabled and tool.name == draft.name for tool in self._state.tools):
                raise RegistryConflict(f"tool name already exists: {draft.name}")
            if any(
                tool.enabled
                and tool.device_id == draft.device_id
                and tool.capability_id == draft.capability_id
                and bool(set(tool.scopes) & set(draft.scopes))
                for tool in self._state.tools
            ):
                raise RegistryConflict(
                    "an approved tool already owns this device capability binding"
                )
            reviewed_at = datetime.now(UTC).isoformat()
            updated = draft.model_copy(update={"status": "approved", "reviewed_at": reviewed_at})
            self._replace_draft_locked(updated)
            tool = ApprovedTool(
                draft_id=draft.draft_id,
                name=draft.name,
                description=draft.description,
                device_id=draft.device_id,
                capability_id=draft.capability_id,
                parameters=draft.parameters,
                scopes=draft.scopes,
                manifest_revision=draft.manifest_revision,
                confirmation_text=draft.confirmation_text,
                approved_at=reviewed_at,
            )
            self._state.tools.append(tool)
            self._persist_locked()
            return tool.model_copy(deep=True)

    def reject_draft(self, draft_id: str) -> ToolDraft:
        with self.lock:
            draft = self._draft_locked(draft_id)
            if draft.status != "pending":
                raise RegistryConflict(f"draft is already {draft.status}")
            updated = draft.model_copy(
                update={"status": "rejected", "reviewed_at": datetime.now(UTC).isoformat()}
            )
            self._replace_draft_locked(updated)
            self._persist_locked()
            return updated.model_copy(deep=True)

    def list_tools(self) -> list[ApprovedTool]:
        with self.lock:
            return [tool.model_copy(deep=True) for tool in self._state.tools if tool.enabled]

    def needle_schemas(self) -> list[dict[str, Any]]:
        return [tool.needle_schema() for tool in self.list_tools()]

    def tool_named(self, name: str) -> ApprovedTool | None:
        with self.lock:
            tool = next(
                (item for item in self._state.tools if item.enabled and item.name == name),
                None,
            )
            return tool.model_copy(deep=True) if tool is not None else None

    def tool_by_id(self, tool_id: str) -> ApprovedTool | None:
        with self.lock:
            tool = next(
                (item for item in self._state.tools if item.enabled and item.tool_id == tool_id),
                None,
            )
            return tool.model_copy(deep=True) if tool is not None else None

    def tool_for_binding(
        self,
        device_id: str,
        capability_id: str,
        *,
        scope: Scope,
    ) -> ApprovedTool | None:
        with self.lock:
            tool = next(
                (
                    item
                    for item in self._state.tools
                    if item.enabled
                    and item.device_id == device_id
                    and item.capability_id == capability_id
                    and scope in item.scopes
                ),
                None,
            )
            return tool.model_copy(deep=True) if tool is not None else None

    def eligible_tools(
        self,
        *,
        scope: Scope,
        device_ids: set[str] | None = None,
    ) -> list[ApprovedTool]:
        """Return only tools whose current manifest still matches the approved binding."""
        with self.lock:
            eligible: list[ApprovedTool] = []
            for tool in self._state.tools:
                if not tool.enabled or scope not in tool.scopes:
                    continue
                if device_ids is not None and tool.device_id not in device_ids:
                    continue
                device = next(
                    (item for item in self._state.devices if item.device_id == tool.device_id),
                    None,
                )
                if device is None or not device.connected or scope not in device.scopes:
                    continue
                capability = device.capability(tool.capability_id)
                if (
                    capability is None
                    or capability.parameters != tool.parameters
                    or not set(tool.scopes).issubset(device.scopes)
                    or device.revision() != tool.manifest_revision
                ):
                    continue
                eligible.append(tool.model_copy(deep=True))
            return eligible

    def validate_tool_proposal(
        self,
        tool_id: str,
        arguments: dict[str, Any],
        *,
        scope: Scope,
    ) -> tuple[ApprovedTool, dict[str, Any]]:
        """Revalidate connection, scope, manifest revision, schema, and arguments."""
        with self.lock:
            tool = next(
                (item for item in self._state.tools if item.enabled and item.tool_id == tool_id),
                None,
            )
            if tool is None:
                raise RegistryNotFound(f"approved tool not found: {tool_id}")
            self._validate_tool_binding_locked(tool, scope=scope)
            return tool.model_copy(deep=True), validate_arguments(tool.parameters, arguments)

    def execute(
        self,
        tool_id: str,
        arguments: dict[str, Any],
        *,
        scope: Scope = "home",
        expected_device_id: str | None = None,
        expected_capability_id: str | None = None,
        expected_manifest_revision: str | None = None,
    ) -> dict[str, Any]:
        with self.lock:
            tool = next(
                (item for item in self._state.tools if item.enabled and item.tool_id == tool_id),
                None,
            )
            if tool is None:
                raise RegistryNotFound(f"approved tool not found: {tool_id}")
            if expected_device_id is not None and tool.device_id != expected_device_id:
                raise RegistryValidationError("proposal device binding does not match approved tool")
            if expected_capability_id is not None and tool.capability_id != expected_capability_id:
                raise RegistryValidationError("proposal capability binding does not match approved tool")
            if (
                expected_manifest_revision is not None
                and tool.manifest_revision != expected_manifest_revision
            ):
                raise RegistryValidationError("proposal manifest revision is stale")
            self._validate_tool_binding_locked(tool, scope=scope)
            validated = validate_arguments(tool.parameters, arguments)
            device_state = self._state.device_state.setdefault(tool.device_id, {})
            device_state[tool.capability_id] = validated
            self._persist_locked()
            return {
                "status": "simulated",
                "tool_id": tool.tool_id,
                "device_id": tool.device_id,
                "capability_id": tool.capability_id,
                "applied": validated,
            }

    def _validate_tool_binding_locked(self, tool: ApprovedTool, *, scope: Scope) -> None:
        if scope not in tool.scopes:
            raise RegistryValidationError("approved tool is not allowed in this scope")
        device = self._device_locked(tool.device_id)
        if not device.connected:
            raise RegistryValidationError("device is not connected")
        if scope not in device.scopes:
            raise RegistryValidationError("device is not allowed in this scope")
        capability = device.capability(tool.capability_id)
        if (
            capability is None
            or capability.parameters != tool.parameters
            or not set(tool.scopes).issubset(device.scopes)
            or device.revision() != tool.manifest_revision
        ):
            raise RegistryValidationError("approved tool no longer matches its device manifest")

    def device_state(self, device_id: str) -> dict[str, dict[str, Any]]:
        with self.lock:
            self._device_locked(device_id)
            return json.loads(json.dumps(self._state.device_state.get(device_id, {})))

    def _device_locked(self, device_id: str) -> DeviceManifest:
        device = next((item for item in self._state.devices if item.device_id == device_id), None)
        if device is None:
            raise RegistryNotFound(f"device not found: {device_id}")
        return device

    def _draft_locked(self, draft_id: str) -> ToolDraft:
        draft = next((item for item in self._state.drafts if item.draft_id == draft_id), None)
        if draft is None:
            raise RegistryNotFound(f"draft not found: {draft_id}")
        return draft

    def _replace_draft_locked(self, draft: ToolDraft) -> None:
        for index, current in enumerate(self._state.drafts):
            if current.draft_id == draft.draft_id:
                self._state.drafts[index] = draft
                return
        raise RegistryNotFound(f"draft not found: {draft.draft_id}")
