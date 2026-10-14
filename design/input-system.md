# Input system design

Status: developer implementation available; the broader extensibility design below includes future work. Replace direct GLFW polling in `src/main.zig` with a device-independent mapper controlled through the existing event system. Gameplay and UI receive semantic action events; they never inspect physical keys.

**Initial scope:** only a `developer` input mode, preserving the controls and menu behavior currently implemented in `src/main.zig`. Other modes, actions and bindings below illustrate future extensibility; they are not required initial mappings.

## Modes and mappings

- Use the existing `InputMode` definition in `src/core/events/engineEvents.zig`, adding `developer` as the sole initially used mode. Future examples include `gameplay` (playing), `UI` (menu), `console`, `fighting`, `driving`. Keep one definition; adding modes/actions requires compilation, changing bindings does not.
- Future modes may use one base mode and a stack of modal overlays (`UI`, `console`). Only the top overlay receives input while open; popping it restores the base mode. Fighting may inherit gameplay defaults; explicit overrides, including unbinding, take precedence. Initially, the existing block menu remains a state within developer mode, with the same input suppression and cursor behavior as today.
- Define `ActionId` independently of devices: e.g. `move`, `look`, `open_menu`, `back`, `primary`, `secondary`, `toggle_removal`, `accelerate`. Each action declares its value kind (`button`, `axis1`, `axis2`) and destination queue.
- Each mode owns an editable `ActionId → []Binding` map. A binding contains a tagged source (key, mouse button, mouse delta/wheel; later gamepad button/axis), optional modifiers, scale/inversion and dead zone. Key pairs compose axes; several bindings allow keyboard and controller alternatives.
- Buttons combine with OR; digital axis contributions sum and clamp; 2D movement is length-limited to 1. For competing analog devices use greatest magnitude with stable device-ID tie-breaking. Mouse look is displacement; stick look is a rate integrated with `dt` before combining.

Initial developer layout (current controls). Both states below belong to the same `developer` mode.

| Mode / state | Bindings |
| --- | --- |
| Developer — menu closed | W/S → forward/back; A/D → strafe; Space/Left Shift → up/down; mouse movement → look; LMB → remove targeted block/voxel; RMB → place selected block; V → toggle block/voxel removal; Tab → open block menu; Esc → quit |
| Developer — menu open | Mouse → pointer; LMB → select/deselect block or activate Empty hand/Prev/Next; RMB → deselect; Tab/Esc → close menu. Movement, look and world editing are suppressed. |
| Developer — either state | F2 → save screenshot; F3 → toggle FPS display |

The following additional modes and bindings are future examples only.

| Future mode | Illustrative bindings |
| --- | --- |
| Gameplay | WASD → move; Space/Shift → vertical move; mouse delta → look; LMB/RMB → remove/place; V → toggle removal; Tab → open menu; Esc → quit |
| UI | LMB → activate at pointer; RMB → deselect; Tab/Esc → back |
| Fighting | Gameplay defaults, overriding LMB/RMB → attack/block |
| Driving | W/S → accelerate/brake; A/D → steer; Esc → open menu |

Future shared bindings can be explicitly copied into multiple modes; their modal behavior must be defined per mode.

## Event contract

Use the existing `input` queue (`consumer = .input`) for commands. Extend its current `change_mode` event; do not create a second event bus.

| Direction | Events and payloads |
| --- | --- |
| Into input | `change_mode { mode }`, `push_overlay { mode }`, `pop_overlay`, `set_enabled { enabled }` |
| Into input | `replace_bindings { request_id, mode, action, bindings }`, `reset_bindings { request_id, mode }`, `apply_profile { request_id, profile }` |
| Into input | `begin_rebind { request_id, mode, action, slot }`, `cancel_rebind { request_id }`, `query_bindings { request_id, mode }` |
| Out to action owner | `action { frame, sequence, context_generation, mode, action, phase, value }`; phase = `started`, `changed`, `ended`, `cancelled` |
| Out to UI | `command_result { request_id, status, revision }`, `bindings_snapshot`, `rebind_candidate { request_id, binding, conflicts }` |

Payloads use tagged values and owned storage: bounded inline binding arrays initially; larger profiles/snapshots use immutable owned handles with explicit release. Never enqueue borrowed settings/UI slices. Commands validate first and apply atomically; rejected commands preserve the active map. Acknowledgment means applied, not merely enqueued.

The existing queues have **one consumer each**, not broadcast. Declare action events on queues owned by UI, entity, or the engine event loop as appropriate; explicitly duplicate only when two owners need a notification. Continuous movement/look is delivered through events too: consumers retain the latest axis state, while mouse delta is consumed once per frame. Button edges are emitted once; held-action repeat/cooldowns belong to gameplay or UI.

## Update order and transitions

1. On the GLFW/main thread, drain input commands at the start of the input pass; apply mode/profile changes and cursor policy.
2. Poll GLFW and collect ordered button edges, Unicode text, pointer position, wheel and relative motion. Preserve press/release pairs occurring within one frame; do not infer all edges from a single held-state poll. Future gamepad polling feeds the same normalized device representation.
3. Resolve active mappings, aggregate sources, and enqueue action transitions/values. Text and absolute pointer events go to the active UI/console owner separately from remappable gameplay actions.
4. At frame start call `EventSystem.beginFrame`, then process input commands and poll/map devices. Input uses `submitCurrent` so actions enter the current frame immediately. Dispatch current queues to their owners (currently temporary main-thread adapters merge by input sequence), and call `clearCurrent` to retire the frame while preserving next/debt buffers. Other producers use deferred `submit`; commands submitted during action handling apply next frame. Do not mix this schedule with the older auto-advancing processing APIs.

On mode change, disabling, rebinding, focus loss or disconnect, cancel affected active actions and emit zero axis values before replacement input. Increment the context generation on routing/map changes. Suppress held controls until released (analog controls until neutral) before activating new bindings; reset mouse-delta baseline when cursor capture changes. Modal overlays release the cursor; gameplay captures it. This prevents menu clicks becoming world edits and held keys producing stuck actions. Focus cleanup must also run while minimized.

Preserve ordered button transitions and commands using the existing debt-queue policy; inspect submission results/errors because debt storage is finite. Coalesce continuous values before enqueueing (sum deltas, retain latest absolute values). The initial implementation returns an error and stops the application on exhausted raw/current capacity, rather than dropping or delaying edges. A bounded cancellation/reset recovery path can be added later. Never silently lose an end/cancel event.

## Runtime rebinding and persistence

Settings enter exclusive capture through `begin_rebind`; wait for currently held controls to release, ignore key repeat, and return the next eligible source as a candidate. Axis capture later requires a threshold to ignore controller drift. Settings resolves same-mode conflicts (replace, explicitly share, or cancel), then sends `replace_bindings`; capture produces no gameplay actions. Ensure settings always offers a pointer-accessible cancel/reset control.

Persist versioned JSON overrides using stable mode/action/source names, not enum ordinals or GLFW integers. An explicit empty binding list means unbound; missing entries inherit defaults. Settings loads/saves profiles and submits `apply_profile`; input owns the live copy. Validate names, kinds and ranges, report invalid entries, keep defaults for them, and save atomically. Persist only acknowledged revisions. Controller support later adds a device adapter, standardized controls, hot-plug cancellation and settings labels without changing gameplay action consumers.

## Implementation boundary and validation

Proposed `src/core/input/`: `types.zig`, `bindings.zig`, `inputSystem.zig`, `glfwBackend.zig`; event declarations remain in `engineEvents.zig`. Keep GLFW access on the main thread; other systems control input exclusively through queued commands.

Initially migrate current movement, camera, menu, editing, screenshot and FPS controls into `developer`, retaining existing bindings, menu behavior, edit cooldowns and release guards. Verify FIFO command application/acknowledgment, atomic rebind, multi-binding release, same-frame taps, focus cancellation, menu isolation, queue exhaustion recovery and profile round trips with a fake backend. Test additional mode isolation, overlay restoration and controller disconnects when those extensions are introduced. Additional modes, overlay commands, a controller backend and a settings UI are future work.

## Implemented developer subset

`types.zig`, `inputSystem.zig`, `routing.zig` and `glfwBackend.zig` implement queued mode/enabled/menu control, atomic runtime replacement/reset/profile commands, binding queries, exclusive rebind capture, and named JSON load/atomic-save helpers. `developer` is only a binding mode. Actions route directly to typed events in `entity` (movement/look), `world` (editing), `UI` (menu/pointer and binding responses), `render` (screenshot/FPS), and `core` (existing shutdown event). Entity/world payloads use explicit nonexistent test IDs (`u64`/`u32` maximum respectively); no real target is resolved. Temporary main-thread adapters preserve current developer behavior and cross-queue input ordering until subsystem consumers are connected. Only developer mode is accepted; legacy enum values remain for compatibility. Pointer/look are dedicated motion actions; button actions accept up to four keyboard/mouse sources. F2/F3 are edge-triggered.

Future work: other modes and overlays, analog/controller adapters, modifiers, text/wheel actions, configurable motion processing, and a settings UI. The initial mapper preserves the existing movement speed instead of introducing normalized movement axes. Invalid profiles are rejected atomically. See [README](../README.md#developer-input-and-frame-queues) for the actual frame schedule, runtime commands and profile format.

Runtime output: per-frame queue dumps and input-command logging are disabled. FPS reporting is enabled by default, updates approximately once per second, and is toggled by F3. `printCurrent` remains available for explicit debugging.
