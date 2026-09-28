# Game Engine Roadmap

## Current Focus

- [ ] Events: build the queue structure and event loop from compile-time event descriptors.

## Rendering

### GPU upload pipeline

- [ ] Add a GPU upload queue separate from CPU generation.
- [ ] Push finished chunk data into a GPU update queue after CPU insertion.
- [ ] Stop rebuilding and uploading the whole streamed region.
- [ ] Keep fixed GPU slots for streamed chunks.
- [ ] Upload only changed chunk slots.
- [ ] Use partial buffer updates instead of full buffer refreshes.
- [ ] Limit GPU uploads per frame to avoid spikes.

### Renderer traversal optimization

- [ ] Add skipping over fully empty chunks.
- [ ] Jump directly to the next chunk boundary when the current chunk is empty.
- [ ] Add coarse occupancy data inside chunks.
- [ ] Use chunk -> coarse block -> voxel traversal.
- [ ] Only do per-voxel stepping near actual geometry.
- [ ] Reduce unnecessary ray steps through air.
- [ ] Benchmark different coarse subdivisions, including `4x4x4`.

### Future rendering structures

- [ ] Evaluate whether fixed multi-level skip structures are sufficient.
- [ ] Compare fixed skip structures against a linearized octree.
- [ ] Consider octrees for long render distances, LOD, and very sparse data.
- [ ] Finish chunk and block skipping before adopting a full octree.

### Voxel item icon rendering

- [ ] Define the voxel-map/model format used by inventory items.
- [ ] Render item icons from voxel maps with a consistent camera, projection, lighting, and transparent background.
- [ ] Decide whether icons are generated during asset building, at load time, or lazily on first use.
- [ ] Cache generated icons by item/model and invalidate them when the source voxel map changes.
- [ ] Support configurable icon framing, rotation, scale, and animation where needed.
- [ ] Batch icon generation so it does not interrupt gameplay rendering.
- [ ] Provide a fallback icon when a voxel map is missing or icon generation fails.

## World

### Terrain generation cleanup

- [ ] Replace the current layered terrain shaping with a heightmap-first approach.
- [ ] Make terrain read as one coherent landform instead of several overlapping shapes.
- [ ] Keep the current terrain version as a comparison mode.
- [ ] Rework material placement after the heightmap pass.
  - [ ] Place grass on flatter top surfaces.
  - [ ] Add a shallow dirt layer below topsoil.
  - [ ] Place stone on steeper slopes and in deeper layers.
- [ ] Tune height scales and frequencies for broader, more natural terrain.

### Faster chunk generation

- [ ] Classify chunks by their relation to terrain height before filling voxels.
- [ ] Mark chunks fully above the terrain as empty immediately.
- [ ] Mark chunks far below the terrain as fully solid immediately.
- [ ] Only perform detailed voxel generation near the surface band.
- [ ] Compute minimum and maximum terrain height across each chunk footprint `(x, z)`.
- [ ] Use the height range to classify each chunk as empty, solid, or mixed.

### Chunk generation threading

- [ ] Keep chunk generation on a worker thread.
- [ ] Have the main/render thread send only the latest camera chunk position.
- [ ] Build the nearest missing chunks first.
- [ ] Drain finished chunks and insert them into the CPU world on the main thread.
- [ ] Keep world ownership on the main thread.
- [ ] Keep OpenGL ownership on the render thread.
- [ ] Track chunks as missing, queued/inflight, or ready.
- [ ] Prevent duplicate generation of the same chunk.

### World storage

- [ ] Add a coarse occupancy mask per chunk.
- [ ] Test splitting each chunk into `4x4x4` coarse regions.
- [ ] Store one occupancy bit per coarse region.
- [ ] Expose occupancy data to the renderer for empty-region skipping.

## Events — Current

### Event definitions

- [x] Define event type descriptors.
- [x] Define individual event descriptors and payload types.
- [x] Generate event types and their metadata at compile time.
- [x] Validate duplicate type IDs, event IDs, and names at compile time.

### Event queues

- [x] Generate one strongly typed queue for each event type at compile time.
- [x] Keep queue capacities independent so high-volume event types cannot fill critical queues.
- [x] Finish the reusable fixed-capacity ring buffer.
- [x] Apply each event type's queue-full behavior:
  - [x] defer to the next frame
  - [x] move to a debt/overflow queue
  - [x] replace the newest queued event
  - [x] replace the oldest queued event
  - [x] discard the incoming event
  - [x] warn or remain silent
- [x] Make queue-full actions mutually exclusive.
- [ ] Decide whether queues require thread safety or remain owned by the event loop thread.

### Event loop

- [ ] Build an event loop containing all generated event queues.
- [ ] Add a type-safe API for submitting events to the correct queue.
- [ ] Process event-type queues in priority order.
- [ ] Preserve FIFO ordering within each queue.
- [ ] Define a per-frame processing budget to prevent one queue from starving others.
- [ ] Move deferred and debt events at the frame boundary.
- [ ] Define how systems register handlers for event types or individual events.
- [ ] Define immediate versus queued dispatch.
- [ ] Define whether handlers may safely enqueue new events during dispatch.
- [ ] Integrate event processing with the main engine loop.

### Event tests

- [ ] Test queue wraparound, full, and empty behavior.
- [ ] Test isolation between event-type queues.
- [ ] Test priority ordering and FIFO ordering.
- [x] Test every queue-full policy.
- [ ] Test events submitted while the event loop is dispatching.
- [ ] Test frame deferral and debt queue handling.

## Entities

- [ ] Define the entity identifier and lifetime model.
- [ ] Define the component storage model.
- [ ] Add entity creation and destruction.
- [ ] Add component insertion, removal, and queries.
- [ ] Define how entity systems are scheduled.
- [ ] Connect entity lifecycle changes to the event system.

## Physics System

- [ ] Define physics body and collider components.
- [ ] Add fixed-timestep physics updates.
- [ ] Add broad-phase and narrow-phase collision detection.
- [ ] Add collision response.
- [ ] Add voxel-world collision queries.
- [ ] Emit collision events through the event system.

## UI System

- [ ] Define the UI hierarchy and element lifetime model.
- [ ] Add layout, sizing, and anchoring.
- [ ] Add text and basic widget rendering.
- [ ] Add focus, hover, and activation handling.
- [ ] Route UI actions through the input and event systems.
- [ ] Keep inventory data and rules independent from inventory widgets.
- [ ] Build reusable slot-grid, equipment-slot, hotbar, page-selector, and tooltip widgets.
- [ ] Support mouse, keyboard, and gamepad inventory navigation.
- [ ] Render held/dragged item stacks and valid or invalid drop targets.
- [ ] Display stack counts, equipment-slot symbols, and rarity decoration.
- [ ] Display generated voxel item icons without coupling items to GPU texture objects.

## Input System

- [ ] Separate raw platform input from gameplay actions.
- [ ] Track pressed, held, and released states.
- [ ] Add configurable action bindings.
- [ ] Support keyboard, mouse, and gamepad input.
- [ ] Define input focus and consumption between gameplay and UI.
- [ ] Emit input events through the event system.

## Inventory System

### Items

- [ ] Define stable item identifiers and immutable item definitions.
- [ ] Store mutable item-stack state separately from shared item definitions.
- [ ] Define stack limits, rarity, tags, and equipment compatibility.
- [ ] Reference voxel maps/models used to generate item icons.
- [ ] Add data-driven item loading with validation and useful errors.

### Containers and operations

- [ ] Define inventory containers, pages, slots, and capacity.
- [ ] Support grid inventories, hotbars, and typed equipment slots.
- [ ] Add insert, remove, swap, move, split, merge, and transfer operations.
- [ ] Return explicit operation results, including remainders and rejection reasons.
- [ ] Make multi-slot transfers atomic so failed operations do not lose or duplicate items.
- [ ] Support containers that provide extra capacity, such as backpacks.
- [ ] Define what happens to contained items when a capacity-providing item is removed.

### Integration

- [ ] Attach inventories to entities without embedding UI or rendering state in inventory data.
- [ ] Expose read-only inventory views for UI rendering.
- [ ] Convert UI actions into validated inventory commands.
- [ ] Emit events for item insertion, removal, movement, equipment changes, and rejected operations.
- [ ] Save and load item stacks, containers, equipment, and nested storage.

### Inventory tests

- [ ] Test stacking at, below, and above stack limits.
- [ ] Test whole-stack and half-stack movement.
- [ ] Test typed equipment-slot validation.
- [ ] Test transfers between grid inventories, equipment, and hotbars.
- [ ] Test nested/capacity-providing containers and their removal rules.
- [ ] Test serialization and invalid item data.

## Game State System

- [ ] Define engine and gameplay state lifecycles.
- [ ] Add state transitions and a state stack if needed.
- [ ] Define which systems update and render in each state.
- [ ] Handle initialization, suspension, resumption, and shutdown.
- [ ] Route state changes through the event system.
