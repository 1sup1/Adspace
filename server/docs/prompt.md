# Adaptive Space agent prompts

The environment coordinator receives a short, time-ordered window of consented wearable samples. It must call `analyze_signal_window` once, use the returned levels and trends to choose a non-medical `recovery`, `focus`, or `calm` context, and return typed confidence, evidence, and one concise Korean reason. Because the product coordinates the current space, a sustained current trend takes precedence over a historical static score when they conflict. The agent also considers time of day and user safety, and does not invent normal/abnormal labels for numeric values.

It must not diagnose health, emotion, or stress; infer missing metrics; choose device values; or control devices. Deterministic server policy maps the selected context to bounded device values and owns space compatibility, approval, restore, and expiry.

The conversational concierge receives only the current context, confidence, final bounded profile, reason, and the last 12 chat turns. It explains the recommendation in concise Korean, never claims diagnosis or guaranteed outcomes, and has no device-control tools. Raw wearable samples and companion preference ranges are excluded from its request contract.

## Command routing and tool drafts

Short device commands first go through Needle as structured function-call proposals. A
proposal is never execution: server policy validates the active scope, argument bounds,
session state, and required confirmation before an existing executor can run it. An empty,
malformed, or low-confidence Needle result is a normal fallback to the GPT concierge.

The GPT fallback may return either a normal conversational answer, an already-approved
dynamic tool proposal, or a `ToolDraft`. A draft is declarative JSON, not source code. It
must name one currently connected `device_id` and one advertised `capability_id`; its
parameter schema must be a constraint-preserving subset of that capability's manifest.
Drafts cannot contain URLs, imports, shell commands, callback code, credentials, or an
executor implementation. The server independently validates this binding and rejects any
unknown device, capability, parameter, enum value, or widened numeric range.

Every draft remains inert until the user explicitly approves it. Approval persists the
validated schema in the local tool registry but does not execute the requested action.
The first execution requires a second, distinct user confirmation, after which Needle and
the GPT fallback may reuse the tool by stable tool ID. Every invocation is represented by
a short-lived, one-use server proposal that binds validated arguments, scope, device,
capability, and manifest revision; the confirmation request cannot replace those values.
Invocation still validates the binding against the original device capability and runs
only through the deterministic device adapter. Model output never selects arbitrary code
or bypasses either approval boundary.
