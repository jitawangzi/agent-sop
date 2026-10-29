# Antigravity finish fixture provenance

This is a sanitized reconstruction, not a captured stdin payload or a successful
live-model receipt. The native envelope follows the CLI-distributed
`agy-customizations/docs/hooks.md` PreToolUse contract: camelCase common metadata,
`toolCall.name`, `toolCall.args`, and `stepIdx`. The installed CLI binary exposes
`CORTEX_STEP_TYPE_FINISH`, `FinishToolConverter.ToolCallToCortexStep`,
`FinishToolConfig.result_json_schema_string` and `CortexStepFinish.output/output_string`.
Its `hooks_pb` descriptors also enumerate `HookArgsCommon` (including optional
execution/agent/parent/root context metadata), `PreToolHookArgs` and
`HookToolCall`. The fixture includes those metadata fields with inert values;
paths in metadata are never used as read or write authority.

The observed public Studio run `094ddbf0-6866-4212-97d2-6a6b363e5dbd` first review
and same-context retry log both show `tool_info.name=finish`, object `parameters`,
and state `ERROR` with `AI_SOP_GUARD_TOOL_UNKNOWN` from the pre-tool hook.
Both init records identify `gemini-4-argon-high` and a JSON schema; both result
records say `SUCCESS` but omit `structured_output`. Only public init/result and
tool state/metadata were inspected. No private analysis was used.

The fixture preserves the observed argument keys and nesting while replacing
all project paths, identifiers, evidence and prose with inert generic values.
There is no database metadata. The provider name/model is protocol evidence,
not a model selection rule. Tests do not call a model or the installed project.
