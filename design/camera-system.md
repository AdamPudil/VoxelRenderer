# Camera system design

Status: proposal. Support multiple placed cameras and switch the screen between them; initially render one view.

## Implementation progress

The standalone camera foundation and lifecycle queue are implemented in
`src/core/camera/`. The remaining sections describe the full planned system.

- `CameraSystem` owns generational handles, validated transforms/FOV and copied
  resolved snapshots. Shared data and command payloads live in `types.zig`.
- The `camera` queue belongs to the camera consumer and accepts `create`,
  `destroy`, `set_transform` and `set_fov`. The main loop processes it before
  retiring current queues, including frames with a zero-size framebuffer.
- Every command carries `request_id` and `reply_to`. Supported reply queues are
  `core`, `UI`, `entity`, `world` and `render`; each registers `camera_result`.
  Results are deferred until the requester's next pass. Creation returns its
  allocated handle only after application; rejected creation returns no handle.
- `create` wraps camera properties in `info`; `set_transform` wraps position and
  rotation in `transform`. Property updates default to `acknowledge = false`,
  but always report failures. Creation and destruction always report results.
- Current statuses are `applied`, `invalid_handle`, `invalid_value`,
  `out_of_memory` and `capacity_exceeded`. Rejected commands preserve state.
- If a reply queue and its overflow storage are both full, `processCurrent`
  returns `error.Full` and retains the result. A caller may retry before clearing
  current queues; the command is not applied twice and later commands remain
  unread. The current main loop propagates this error, as it does other queue
  submission failures.

Run `zig build test-camera` for the camera tests. Screen-view ownership,
active-camera deletion protection, developer input migration, renderer changes
and entity attachment are subsequent increments.

## Camera or entity?

**Use a lightweight camera object, optionally attached to an entity.** A camera needs a transform and projection, but no mesh, physics or AI. A `CameraSystem` owns camera instances; an optional entity reference supplies a parent transform. If entities later use components, a camera component can hold a `CameraId` without changing this interface.

Keep three responsibilities separate: **camera** describes a viewpoint, **controller** updates it, **render view** chooses which camera to display and at what resolution. Switching viewpoints does not automatically switch the player/vehicle being controlled.

## Minimal data

Conceptual types; IDs are handles with an index and generation to reject stale references.

```zig
Camera {
    id: CameraId,
    world_id: WorldId,
    position: Vec3,         // world space unless attached
    rotation: Quaternion,  // normalized; local to parent if attached
    vertical_fov: f32,      // radians; default pi / 2
    parent: ?EntityId,      // null = independently placed camera
}

RenderView {
    camera: CameraId,
    resolution: [2]u32,    // actual render-target pixels
}
```

Resolution belongs to the view: resizing a window must not modify every camera, and the same camera may later feed several targets. Initially resolution follows the framebuffer; aspect ratio is derived as width/height. Zero dimensions skip rendering. Viewport rectangles, independent render scales and offscreen targets can be added later.

Use existing world units, Y-up, and camera-local forward = -Z. Store quaternion rotation so vehicle roll and flying cameras work; yaw/pitch limits belong to individual controllers. Reject non-finite transforms, zero-length quaternions and FOV outside `0 < fov < pi`; normalize valid rotations. Ray traversal distance stays a renderer setting initially.

## Placement and behavior

- **Fixed camera:** world-space position/rotation; usable for scenery or a cutscene shot.
- **Vehicle/cockpit:** attach to an entity; position/rotation become local offsets. Resolve `world_transform = parent_world_transform × local_transform`, ignoring parent scale.
- **Third person:** a controller reads its target entity and updates a standalone camera's world transform. Orbit distance, smoothing, collision avoidance and look-at calculations belong to that controller.
- **Cutscene:** a controller animates position, rotation and FOV, or requests a switch between placed cameras. Start with instant cuts; blending is optional future behavior using a temporary camera pose.

Each camera has at most one controller writing its transform per frame. Inactive cameras remain registered; attachment poses are resolved when needed. Controllers decide whether their timelines continue while inactive.

## Event queues and lifecycle

Add a `camera` queue owned by `CameraSystem`. Its commands and related events are listed below. Creation returns the allocated ID via a result event to the requesting system's designated queue. Attach/detach preserves the current world pose; use `set_transform` afterward to choose a local offset. Reject cross-world attachment; deleting a parent detaches its cameras at their last resolved world poses.

The `render` queue receives `set_view_camera { camera_id }`; initially there is one screen view. Validate the handle before switching. Invalid requests preserve the current view and emit an error result. Reject destruction of a camera referenced by a view until that view is switched away. Keep one developer camera as the startup viewpoint.

Frame order: input → entity/vehicle updates → camera commands/controllers and attachment resolution → view selection → rendering. Use the existing current-frame submission path on the main thread; other producers submit deferred commands. Print and drain current queues as usual. The renderer reads one immutable resolved camera snapshot for the frame. Developer free-camera actions should eventually target `camera`; player/vehicle movement continues to target `entity`.

### Event table

All names below are proposed, not implemented. `id` means `CameraId`; `view` defaults to the primary screen view. Request/response operations additionally carry `{ request_id, reply_to }`; `reply_to` selects an explicitly supported owner queue, not a callback or broadcast. High-frequency input and transform updates need no success acknowledgment unless requested; failures report to their producer. Input events carry `{ frame, sequence, phase }`, using the existing started/changed/ended/cancelled semantics.

#### Camera lifecycle and properties — initial

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `camera` → CameraSystem | `create` | `world_id, position, rotation, vertical_fov, parent?` | Allocate a camera; initial transform is local when parented. Return its handle. |
| `camera` → CameraSystem | `destroy` | `id` | Remove an unreferenced camera and invalidate its handle. |
| `camera` → CameraSystem | `set_transform` | `id, position, rotation` | Atomically replace the transform in its current world/local space. |
| `camera` → CameraSystem | `set_fov` | `id, vertical_fov` | Update validated vertical FOV in radians. |

#### Entity attachment — initial

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `camera` → CameraSystem | `attach` | `id, entity: ?EntityId` | Attach, reparent or detach (`null`), preserving world pose. |
| `camera` → CameraSystem | `parent_removed` | `entity_id, last_world_pose` | Entity owner forwards removal before discarding the final transform; detach dependent cameras. |

#### Developer controls — initial

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `camera` → CameraSystem | `move` | `id, local_axis: Vec3` | Set developer-controller movement intent; release/cancel zeros it. Controller integrates speed with frame delta time. |
| `camera` → CameraSystem | `look` | `id, angular_delta: Vec3` | Apply pitch/yaw/roll displacement once, in radians; cancel clears pending deltas. |
| `camera` → CameraSystem | `reset_controls` | `id` | Clear held movement and pending look when control target changes, input is disabled, or focus is lost. |

#### Screen view — initial

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `render` → Renderer | `set_view_camera` | `view, camera_id` | Validate and switch the view at the frame boundary; does not change input control target. |
| `render` → Renderer | `resize_view` | `view, width_px, height_px` | Window backend reports framebuffer size; zero dimensions suspend the view. |

#### Command responses — initial

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| Requester's queue → requester | `camera_result` | `request_id, operation, status, camera_id?` | Report applied camera commands, allocated handles or rejection. |
| Requester's queue → requester | `view_result` | `request_id, operation, status, view, camera_id?` | Report applied view changes or rejection; success means applied, not merely enqueued. |

#### Inspection tools — later

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `camera` → CameraSystem | `query_camera` | `id` | Request camera state for an editor/settings/debug UI. |
| Requester's queue → requester | `camera_snapshot` | `request_id, camera_data, resolved_world_pose` | Return an owned copy of requested state. Rendering itself uses a frame snapshot, not this query path. |

#### Controllers and cutscenes — later

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `camera` → CameraSystem | `set_controller` | `id, config: none/free_fly/orbit/follow/sequence` | Assign one controller with a tagged configuration containing its target and tuning values. |
| `camera` → CameraSystem | `play_sequence` | `id, sequence_id, start_time, speed, loop` | Start camera animation of pose/FOV using an existing sequence asset. |
| `camera` → CameraSystem | `set_sequence_paused` | `id, paused` | Pause/resume the timeline without changing the current pose. |
| `camera` → CameraSystem | `seek_sequence` | `id, time` | Evaluate the sequence at a requested time. |
| `camera` → CameraSystem | `stop_sequence` | `id` | Stop playback and retain the current pose/FOV. |
| Initiator's queue → sequence owner | `sequence_finished` | `id, sequence_id, playback_request_id` | Notify natural completion of non-looping playback. |

#### View transitions and additional views — later

| Queue → consumer | Event | Payload beyond shared metadata | Purpose |
| --- | --- | --- | --- |
| `render` → Renderer | `blend_view_camera` | `view, target_camera_id, duration, easing` | Transition from the current resolved pose to a target. An instant switch interrupts a blend; referenced cameras remain protected. |
| `render` → Renderer | `create_view` | `camera_id, target_id, resolution` | Add another independently rendered view; return a `ViewId` in `view_result`. |
| `render` → Renderer | `destroy_view` | `view` | Release an additional view and its camera reference. |

Result statuses include `applied`, `invalid_handle`, `invalid_value`, `wrong_world`, `camera_in_use` and `unsupported_operation`. Camera/view mutations validate before applying; rejected requests leave state intact. Responses are registered on each supported requester queue because queues have one consumer. Deferred responses are read on that owner's next pass; an initial create result identifies the camera before a switch is requested.

Movement/look select the controlled camera ID explicitly. Gameplay retains its `entity.move`/`entity.look` routes; only developer free-camera controls use the camera events. Switching the controlled camera sends `reset_controls` to the old one and requires held inputs to return to neutral. Third-person, vehicle and cutscene controllers reuse `set_transform`, `set_fov`, `attach` and view-selection events instead of requiring separate camera types.

## Renderer integration and initial scope

Replace `cam_pos`, `yaw` and `pitch` in `main.zig` with a registered developer camera and a screen view. Derive forward/right/up from the full rotation, rather than reconstructing up from a fixed world-up vector; the current shader otherwise loses roll. Generate perspective rays with:

`normalize(forward + right * ndc.x * aspect * tan(fov/2) + up * ndc.y * tan(fov/2))`

The default 90° vertical FOV matches current gameplay rays. Update shared shader code for both profiles and preserve the icon renderer's separate framing. Use the selected camera for render streaming and developer picking; a switch to unloaded terrain must tolerate missing chunks while streaming catches up. Camera switching must not teleport an entity.

First implementation: camera registry, fixed/attached transforms, one switchable screen view, FOV and framebuffer resizing, and the existing developer controller. Verify stale IDs, switching, attachment/detachment, quaternion roll, aspect/FOV rays and active-camera deletion protection. Third-person behavior, cutscene animation, blending and multiple simultaneous views follow later.
