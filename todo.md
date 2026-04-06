# Voxel Renderer Improvement Roadmap

## 1. Terrain generation cleanup
1. [ ] Replace current layered terrain shaping with a heightmap-first approach.
2. [ ] Make terrain read as one coherent landform instead of multiple overlapping-looking shapes.
3. [ ] Keep current terrain version around as a comparison mode.
4. [ ] Rework material placement after heightmap pass.
   1. [ ] Grass on flatter top surfaces.
   2. [ ] Dirt as a shallow layer below topsoil.
   3. [ ] Stone on steeper slopes and deeper layers.
5. [ ] Tune height scales and frequencies for broader, more natural terrain.

## 2. Faster chunk generation from terrain classification
1. [ ] Classify chunks by relation to terrain height before voxel-filling them.
2. [ ] Mark chunks fully above terrain as empty immediately.
3. [ ] Mark chunks far below terrain as fully solid immediately.
4. [ ] Only run detailed voxel generation for chunks near the surface band.
5. [ ] Compute min/max terrain height across each chunk footprint `(x,z)`.
6. [ ] Use min/max height to decide whether a chunk is:
   1. [ ] fully empty
   2. [ ] fully solid
   3. [ ] mixed / requires detailed generation

## 3. CPU chunk generation threading
1. [ ] Keep chunk generation on a worker thread.
2. [ ] Main/render thread only sends latest camera chunk position.
3. [ ] Worker always builds nearest missing chunks to the camera first.
4. [ ] Main thread drains finished chunks and inserts them into the CPU world.
5. [ ] Keep world ownership on the main thread.
6. [ ] Keep OpenGL ownership on the render thread.
7. [ ] Add clear chunk state tracking.
   1. [ ] missing
   2. [ ] queued / inflight
   3. [ ] ready
8. [ ] Prevent duplicate generation of the same chunk.

## 4. GPU upload pipeline
1. [ ] Add a GPU upload queue separate from CPU generation.
2. [ ] Push finished chunk data into a GPU update queue after CPU insertion.
3. [ ] Stop rebuilding and uploading the whole streamed region.
4. [ ] Keep fixed GPU slots for streamed chunks.
5. [ ] Upload only changed chunk slots.
6. [ ] Use partial buffer updates instead of full buffer refreshes.
7. [ ] Limit GPU uploads per frame to avoid spikes.

## 5. Renderer traversal optimization
1. [ ] Add skipping over fully empty chunks.
2. [ ] Jump directly to the next chunk boundary when current chunk is empty.
3. [ ] Add coarse occupancy data inside chunks.
4. [ ] Use chunk -> coarse block -> voxel traversal.
5. [ ] Only do per-voxel stepping near actual geometry.
6. [ ] Reduce unnecessary ray steps through air.

## 6. Coarse block hierarchy inside chunk
1. [ ] Add a coarse occupancy mask per chunk.
2. [ ] Test a `16^3` chunk split into `4x4x4` coarse blocks.
3. [ ] Store one occupancy bit per coarse block.
4. [ ] On GPU, jump over empty coarse blocks.
5. [ ] Only descend to voxel stepping inside non-empty coarse blocks.
6. [ ] Benchmark whether `4x4x4` or another subdivision is better.

## 7. Future hierarchical structures
1. [ ] Evaluate whether fixed multi-level skip structures are enough.
2. [ ] Compare that against a full linearized octree later.
3. [ ] Consider octrees mainly for far distance / LOD / very sparse data.
4. [ ] Do not jump to full octrees before chunk and block skipping work well.
