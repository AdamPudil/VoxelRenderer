# Profile-guided renderer optimization plan

Status: first implementation batch implemented: stationary capture/metadata,
comparison utility, and opt-in direct diagnostics. Optimization phases 3–5 remain
measurement-gated; no production optimization or speedup is claimed.
Date: 2026-11-09.

This plan sets the next implementation order from the captured RTX 3060 runs.
It complements [the earlier shader investigation](rtx3060_shader_performance.md).
The detailed capture analysis is in `logs/profile-analysis.md` (local, ignored).

## Evidence and objective

Confirmed direct-run configuration: RTX 3060, NVIDIA 580.178.04, OpenGL 4.6,
ReleaseSafe, 1920×1008, direct lighting, scalar R32UI headers, terrain overlay
empty-group skipping enabled. Camera motion and published terrain were not
recorded. The face run was captured separately; matched camera/geometry and all
startup settings still need confirmation.

| Median measurement | Direct capture | Face capture |
|---|---:|---:|
| GPU world pass | 142.086 ms | 32.664 ms |
| GPU measured passes total | 143.458 ms | 34.120 ms |
| CPU frame including presentation waits | 149.967 ms | 49.918 ms |

The world pass accounts for 99.1% of measured direct-run GPU time. CPU work
outside swap has a 0.28 ms median. After excluding frames 1–40, the world-pass
medians remain 146.974 ms direct and 35.915 ms face. These runs implicate direct
lighting and reveal a substantial remaining geometry/shading cost, but their
median difference is not an isolated measurement of lighting time.

Optimize GPU rendering first. Preserve geometry, sky sample directions/count,
point-light behavior, optics, selection, and lighting results. A 60 FPS target
would require the whole frame to fit within 16.67 ms; even the current face-only
baseline exceeds that, so lighting improvements alone cannot establish that goal.
Do not promise a speedup before measuring it.

## 1. Establish repeatable captures

- [x] Add benchmark options for fixed camera position/orientation, framebuffer
  size, warm-up, measured frame count, and controlled exit. Save scene/generation
  settings, camera, geometry revision and light revision alongside timings.
- [x] Write a metadata sidecar: GPU/driver, build/source identifier (including
  dirty-tree identity), shader flags, resolution, lighting mode, requested swap
  interval, upload mode, and benchmark settings. Preserve existing CSV consumers.
- [x] Record CPU frame interval separately from instrumented stage sum. Retain
  separate swap timing and nonblocking GPU collection; report dropped samples.
- [x] Allow explicit swap-interval selection for profiling without changing the
  normal default. Compare GPU durations separately from presentation cadence.
- [x] Add a capture-comparison utility that selects frame ranges and reports
  sample counts, median/p95/p99, stage shares, and missing GPU samples.

Use at least 300 measured frames per case after terrain settles and shader/cache
warm-up. Verify stable published geometry for stationary runs; separately capture
cold-cache frames and streaming transitions rather than discarding those costs.
Repeat each case at least three times, alternating baseline/candidate order.
The minimum scene set is stationary near terrain, a long grazing terrain view,
terrain with authored edits, reflective/glass blocks, and a repeatable moving
camera route. Start with stationary terrain; expand coverage as changes warrant.

**Exit criterion:** repeated baseline runs have quantified variability and
comparable metadata. All further speedup claims reference matched captures.

## 2. Attribute work inside the world pass

Files: `src/graphics/shaders/include/lighting_cache.glsl`, `lighting.glsl`,
`frag_traverse.glsl`, `hierarchy.glsl`, `src/graphics/lightingCache.zig`, and
`src/graphics/frameTimings.zig`.

- [x] Add opt-in direct-lighting counters: lookup/hit/miss counts, ownership
  success, same-frame pending entries, probe exhaustion/collisions, population
  window rejection, and actual calls to `evaluateLighting()`.
- [x] Count actual point/sky visibility rays and their traversal iterations;
  distinguish primary/optical traversal from shadow traversal. Track hierarchy
  node visits and step-budget exhaustion. These are algorithmic counters, not
  hardware cache-miss or instruction counters.
- [ ] Correlate counters with cache invalidation events and revision changes.
  Measure cold cache, stationary warm cache, camera motion, and terrain edits.
- [x] Keep counters compiled out normally. Use sampled instrumentation or
  sharded counters to limit contention, handle overflow, and asynchronously read
  completed diagnostic buffers. Compare performance with diagnostics disabled;
  report instrumentation overhead instead of treating it as production timing.
- [x] Label cache-publication timing explicitly: `Cache.end()` is a barrier.
  Direct-lighting evaluation belongs to the world draw, not that timing bucket.

**Decision:** high repeated evaluations per reusable face prioritizes phase 3.
If warm-cache hit rate is already high, prioritize phase 4 and measure the costs
of cache lookup and ray traversal before redesigning the cache. Existing GI
counters do not measure direct-cache behavior.

## 3. Remove duplicate direct-lighting evaluations

The current 65,536-entry budget limits writes, not tracing. Pixels unable to
claim a slot, including those sharing a face claimed during the current draw,
still evaluate lighting. Raising the budget alone is not a solution to that
same-draw duplication.

- [ ] Prototype an opt-in request → evaluate → shade path, initially for opaque
  primary surfaces. Deduplicate using the complete current face/level key and
  geometry/light revision; verify that each job uses the same sample point as
  the reference path, including lighting-ring transitions.
- [ ] Evaluate unique missing faces in a separate GPU pass, publish results with
  appropriate barriers, and consume them in the final shade pass. Reuse suitable
  queue/buffer infrastructure from GI without adopting GI's progressive sampling
  or changing direct-lighting semantics.
- [ ] Compare storing primary hit data against repeating primary traversal.
  Include intermediate memory, bandwidth, extra passes, barriers, and all
  fallback work in total timings. World-draw time alone is no longer sufficient.
- [ ] Keep the existing exact evaluation fallback for queue/table overflow,
  collisions, unsupported optical surfaces, and unresolved requests. Bound
  memory and queue accesses; recognize that exact fallback leaves worst-case
  ray work unbounded by the queue budget. Never spin on a same-draw writer.
- [ ] Retain full invalidation correctness initially. Consider finer invalidation
  only after measurements justify it: unchanged faces can still receive changed
  shadows from distant edited occluders.

**Exit criterion:** fewer actual duplicate evaluations and lower total GPU time
in cold and warm scenes, with matching reference lighting. A temporal estimate
or deferred visible lighting is a separate quality-mode proposal, not an implicit
fallback. If extra traversal/buffer cost cancels the gain, keep the baseline.

## 4. Reduce the remaining traversal cost

Run each experiment independently in both face and direct modes. Some header
reuse and packed shadow lookups are already implemented; do not duplicate them.

- [ ] Benchmark the existing `-Dvector-world-headers=true` switch first. Test
  terrain and authored blocks with both upload paths; it does not vectorize
  terrain nodes. Do not enable it by default solely on theoretical fetch count.
- [ ] Reuse the primary ray's chunk header until it crosses a chunk boundary,
  following the existing shadow-ray approach. Cover out-of-region transitions,
  procedural terrain, overlays, negative coordinates, and optical ray restarts.
- [ ] Experiment with one vector fetch per terrain-node record. Audit the shared
  index pool, record alignment, offsets, allocation limits and all upload modes;
  retain a separate scalar baseline and measure additional view/binding costs.
- [ ] Use node/step counters to decide whether retained terrain traversal state
  or direct column-interval traversal is worthwhile. Preserve the exact union
  of published columns and never skip authored edits based only on base terrain.
- [ ] Only afterward investigate reciprocal reuse and camera-ray invariant
  hoisting. Preserve zero-direction handling, signed boundary ownership,
  simultaneous crossings, and the existing numerical-progress safeguards.

**Exit criterion:** reference-equivalent hits/images and a repeatable GPU-time
improvement. Fewer source-level texture operations alone is not acceptance.

## 5. Specialize matte scenes if optics overhead is material

`castReflectedRay()` has a dynamically indexed 16-entry ray stack. The captures
provide no evidence yet of actual register allocation or spills.

- [ ] Compare an independently compiled matte-only shader against the optical
  shader on identical matte geometry. A branch inside the existing shader may
  retain its resource costs, so it is not a sufficient specialization test.
- [ ] Select the variant only from conservative, atomically published material
  metadata. Account for all visible/reflected content, edits, streaming, camera
  medium, transparency and refraction; unknown metadata uses the optical path.
- [ ] Preserve emission, selection, icons and lighting. If a safe global matte
  variant wins, consider mixed-scene separation later, including its extra costs.

**Exit criterion:** measured benefit and correct variant switching when glass or
reflective materials enter/leave the scene. Do not reduce stack depth or optical
budgets without proving that supported behavior remains intact.

## Acceptance and rollout

Every experiment has an independent switch and a reference path until validated.
Keep changes when the gain exceeds measured run-to-run variation (initial target:
at least 5% lower median total GPU time), without meaningful p95/p99 regressions
in representative cases. Record memory/upload changes and startup/streaming costs.
Small changes below that threshold can be retained only with stronger statistical
evidence or a separate concrete benefit. Never hide a regression in an average.

Run checks appropriate to each change:

- `zig build test-profile` and `zig build test-profile-gpu` for profiler changes.
- `zig build test-hierarchy`, `zig build test-lighting-rings`, and
  `zig build test-render` for traversal/direct-lighting changes; `test-gi` when
  shared lighting or queue code changes. Use ReleaseSafe for validation builds.
- `zig build test` when CPU metadata, packing, publication or configuration changes.
- Compile both GLSL compatibility and desktop variants. Validate incremental and
  snapshot uploads where layouts/publication change. Add focused parity cases
  for thin geometry, signed boundaries, grazing rays, edited overlays, emitters,
  lighting transitions, glass, reflections, and cold-cache invalidation as needed.

Mesa/EGL establishes correctness, not RTX speed. Final acceptance requires the
RTX 3060 captures. Exact packed hits should agree; floating-point image tolerance
must be explicit and justified rather than silently widening existing checks.

## First implementation batch and deferred work

Start with **repeatable capture/metadata and opt-in direct-cache diagnostics**.
Then choose cache deduplication or traversal work from those results. Benchmark
the existing vector-header switch as a small independent experiment once the
capture setup is repeatable. Implement one optimization at a time.

Defer CPU threading rewrites, streaming-budget tuning, and GI optimization:
current captures do not establish them as sustained bottlenecks. Keep the isolated
15.85 ms streaming hitch on the regression list. Presentation controls can explain
pacing but will not remove the measured shader workload.

Render scale, fewer sky rays, coarser rings and lower optical budgets remain
explicit optional quality/performance modes after equivalent-image work. They
must have separate visual evaluation and should not be reported as preserving
current rendering quality.

## Implementation record (2026-11-09)

The first batch adds `src/profileCapture.zig`, `src/sourceIdentity.zig`,
`src/graphics/directDiagnostics.zig`, the fragment diagnostic include, and
`utils/compare_profiles.py`. See the README profiling section for commands and
counter semantics. Existing timing CSV columns and CPU/GPU stages are preserved;
full frame cadence uses a separate domain. Source hashes cover dirty/untracked
source and asset contents, with separate build/runtime identities.

Stationary runs require a complete published terrain request plus stable revisions,
then warm-up, and fail on measured geometry/light changes. A bounded final poll
collects completed samples outside measurement. Cold and transition frames remain
available in the phase sidecar. Moving routes and authored-edit/optical benchmark
fixtures remain future coverage; interactive captures already record their poses
and revisions. No automatic cold-cache reset or progressive lighting is introduced.

Diagnostics are compiled out normally. Enabled shaders sample pixels, shard
64-bit carry counters, and asynchronously read eight fenced buffers (112 KiB).
Tests compare exact rendered bytes against the uninstrumented shader on both
GLSL profiles, exercise cold/warm/invalidation and population rejection, and
verify sampling and counter carry. `same_frame_pending` cannot identify a face
until publication and must not be interpreted as an exact duplicate-face count.

Stationary RTX validation: three alternating baseline/diagnostic pairs, each with
300 measured frames after 60 stable and 120 warm-up frames, at 1920×1008,
position `(100,453,100)`, yaw/pitch `(3.14,-0.15)`, direct lighting, scalar headers,
incremental uploads, hidden window and requested swap interval 0. All six runs
completed with stable geometry/light revisions and zero missing GPU/diagnostic
samples. Metadata matched apart from the intentional diagnostic stride.

| Run | Baseline GPU total median / p95 / p99 (ms) | Diagnostic GPU total median / p95 / p99 (ms) |
|---|---|---|
| 1 | 69.028 / 69.819 / 70.159 | 154.260 / 157.923 / 166.236 |
| 2 | 68.836 / 69.579 / 69.913 | 152.727 / 155.305 / 158.161 |
| 3 | 68.769 / 69.536 / 69.756 | 152.410 / 155.743 / 160.237 |

Baseline median spread is 0.38% (sample standard deviation 0.134 ms). Sampled
instrumentation at stride 64 adds **121.9%** to the median of run medians; its
GPU durations must not be used as production performance. Warm sampled cache hit
rates are 99.917–99.923%, with 13–14 sampled evaluations per frame caused by
probe exhaustion. This stationary view favors phase 4 traversal experiments over
a cache-phase redesign. It does not establish behavior during camera motion,
optics or authored edits. CPU correctness suites ran concurrently, so these are
initial capture/diagnostic validation results, not an optimization acceptance run.
The old unmatched captures in the evidence section are not comparable to these.

Raw captures and comparison JSON are local/ignored under `logs/pgo-validation/`.
The build/runtime source identity for these runs is
`ac5cbd96230fbb99ead989720e9c8f681c8c3197b758727de5ff7dc52efafaaf`.
The phase 1 stationary repeatability gate is quantified; representative moving,
edited and optical scenes and independently measured phase 4 experiments remain.
Do not mark phases 3–5 complete or enable optimizations from these diagnostics.
