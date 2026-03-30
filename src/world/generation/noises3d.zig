const noise = @import("noises2d.zig");

pub fn posMod(a: i32, b: i32) i32 {
    return @mod(a, b);
}

pub fn abs32(x: i32) i32 {
    return if (x < 0) -x else x;
}

pub fn chunkHash3(x: i32, y: i32, z: i32) u32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x85ebca6b;
    h ^= @as(u32, @bitCast(y)) *% 0xc2b2ae35;
    h = (h << 13) | (h >> 19);
    h ^= @as(u32, @bitCast(z)) *% 0x27d4eb2d;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

pub fn inMenger(x: i32, y: i32, z: i32) bool {
    var xx: u32 = @intCast(if (x < 0) -x else x);
    var yy: u32 = @intCast(if (y < 0) -y else y);
    var zz: u32 = @intCast(if (z < 0) -z else z);

    while (xx > 0 or yy > 0 or zz > 0) {
        const mx = xx % 2;
        const my = yy % 2;
        const mz = zz % 2;

        if ((mx == 1 and my == 1) or
            (mx == 1 and mz == 1) or
            (my == 1 and mz == 1))
        {
            return false;
        }

        xx /= 2;
        yy /= 2;
        zz /= 2;
    }

    return true;
}

pub fn inPyramidLocal(x: i32, y: i32, z: i32, size: i32) bool {
    const cx = size >> 1;
    const cz = cx;
    const radius = (size - 1) - y;
    if (radius < 0) return false;

    return abs32(x - cx) <= radius and abs32(z - cz) <= radius;
}

pub fn inOctahedronLocal(x: i32, y: i32, z: i32, size: i32) bool {
    const ch = size >> 1;
    return abs32(x - ch) + abs32(y - ch) + abs32(z - ch) <= ch;
}

pub fn inOrganicLocal(x: i32, y: i32, z: i32, size: i32) bool {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    const fz = @as(f32, @floatFromInt(z));
    const ch = @as(f32, @floatFromInt(size - 1)) * 0.5;

    // normalized local coords around center
    const nx = (fx - ch) / ch;
    const ny = (fy - ch) / ch;
    const nz = (fz - ch) / ch;

    // rounded main body
    const r2 = nx * nx + ny * ny + nz * nz;

    // tiled fractal-ish field
    const n1 = noise.fbmTile3(fx * 0.22, fy * 0.22, fz * 0.22, size);
    const n2 = noise.fbmTile3((fx + 17.0) * 0.45, (fy + 9.0) * 0.45, (fz + 31.0) * 0.45, size);

    // make cavities/tunnels
    const caves = @abs(n2 - 0.5);

    // base blob + noisy surface
    const density = (1.05 - r2) + (n1 - 0.5) * 0.85 - (0.18 - caves) * 2.2;

    return density > 0.0;
}

pub fn max3(a: f32, b: f32, c_: f32) f32 {
    return @max(a, @max(b, c_));
}

pub fn crystalCell(
    fx: f32,
    fy: f32,
    fz: f32,
    cx: f32,
    cy: f32,
    cz: f32,
    sx: f32,
    sy: f32,
    sz: f32,
) bool {
    const dx = @abs(fx - cx) / sx;
    const dy = @abs(fy - cy) / sy;
    const dz = @abs(fz - cz) / sz;

    // pointy crystal: sharp in one axis, narrower in others
    return max3(dx, dy, dz) + 0.35 * (dx + dy + dz) <= 1.0;
}

pub fn inCaveCrystalsLocal(x: i32, y: i32, z: i32, size: i32) bool {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    const fz = @as(f32, @floatFromInt(z));
    const ch = @as(f32, @floatFromInt(size - 1)) * 0.5;

    const nx = (fx - ch) / ch;
    const ny = (fy - ch) / ch;
    const nz = (fz - ch) / ch;

    const r2 = nx * nx + ny * ny + nz * nz;

    // outer rock body
    const rock_noise = noise.fbmTile3(fx * 0.18, fy * 0.18, fz * 0.18, size);
    const rock_density = (1.18 - r2) + (rock_noise - 0.5) * 0.55;

    if (rock_density <= 0.0) return false;

    // main cave chamber
    const cave_noise = noise.fbmTile3((fx + 41.0) * 0.23, (fy + 17.0) * 0.23, (fz + 73.0) * 0.23, size);
    const cave_shape =
        ((nx * nx) * 1.1) +
        ((ny * ny) * 0.55) +
        ((nz * nz) * 1.1);

    const cave_density = (0.42 - cave_shape) + (cave_noise - 0.5) * 0.28;
    const in_cave = cave_density > 0.0;

    if (!in_cave) return true;

    // crystal clusters inside cave
    // ceiling cluster
    if (crystalCell(fx, fy, fz, ch, 2.0, ch, 1.1, 4.8, 1.1)) return true;

    // floor cluster
    if (crystalCell(fx, fy, fz, ch - 3.0, @as(f32, @floatFromInt(size - 3)), ch + 2.0, 1.0, 3.8, 1.0)) return true;

    // side clusters
    if (crystalCell(fx, fy, fz, 2.0, ch + 1.0, ch - 2.0, 3.6, 1.0, 1.0)) return true;
    if (crystalCell(fx, fy, fz, @as(f32, @floatFromInt(size - 3)), ch - 1.0, ch + 1.0, 3.2, 1.0, 1.0)) return true;

    // small center shard
    if (crystalCell(fx, fy, fz, ch + 1.5, ch + 1.5, ch - 1.5, 0.8, 2.4, 0.8)) return true;

    return false;
}

pub fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

pub fn rand01(seed: u32) f32 {
    const v = seed & 0x00ffffff;
    return @as(f32, @floatFromInt(v)) / 16777215.0;
}

pub fn voronoiFeaturePoint3(
    cx: i32,
    cy: i32,
    cz: i32,
    cell_size: f32,
) [3]f32 {
    const h = chunkHash3(cx, cy, cz);

    const rx = rand01(h ^ 0xA511E9B3);
    const ry = rand01(h ^ 0x63D83595);
    const rz = rand01(h ^ 0xB8F1BBCD);

    return .{
        (@as(f32, @floatFromInt(cx)) + rx) * cell_size,
        (@as(f32, @floatFromInt(cy)) + ry) * cell_size,
        (@as(f32, @floatFromInt(cz)) + rz) * cell_size,
    };
}

const Voronoi3Sample = struct {
    d1: f32,
    d2: f32,
    d3: f32,
};

pub fn voronoi3Distances(
    wx: i32,
    wy: i32,
    wz: i32,
    cell_size_i: i32,
) Voronoi3Sample {
    const fx = @as(f32, @floatFromInt(wx));
    const fy = @as(f32, @floatFromInt(wy));
    const fz = @as(f32, @floatFromInt(wz));
    const cell_size = @as(f32, @floatFromInt(cell_size_i));

    const gx = @divFloor(wx, cell_size_i);
    const gy = @divFloor(wy, cell_size_i);
    const gz = @divFloor(wz, cell_size_i);

    var best1: f32 = 1e30;
    var best2: f32 = 1e30;
    var best3: f32 = 1e30;

    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = gx + dx;
                const cy = gy + dy;
                const cz = gz + dz;

                const p = voronoiFeaturePoint3(cx, cy, cz, cell_size);
                const ox = fx - p[0];
                const oy = fy - p[1];
                const oz = fz - p[2];
                const d2 = ox * ox + oy * oy + oz * oz;

                if (d2 < best1) {
                    best3 = best2;
                    best2 = best1;
                    best1 = d2;
                } else if (d2 < best2) {
                    best3 = best2;
                    best2 = d2;
                } else if (d2 < best3) {
                    best3 = d2;
                }
            }
        }
    }

    return .{
        .d1 = @sqrt(best1),
        .d2 = @sqrt(best2),
        .d3 = @sqrt(best3),
    };
}

pub fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

pub fn voronoiEdge3(
    wx: i32,
    wy: i32,
    wz: i32,
    cell_size_i: i32,
) f32 {
    const fx = @as(f32, @floatFromInt(wx));
    const fy = @as(f32, @floatFromInt(wy));
    const fz = @as(f32, @floatFromInt(wz));
    const cell_size = @as(f32, @floatFromInt(cell_size_i));

    const gx = @divFloor(wx, cell_size_i);
    const gy = @divFloor(wy, cell_size_i);
    const gz = @divFloor(wz, cell_size_i);

    var nearest: f32 = 1e30;
    var second: f32 = 1e30;

    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = gx + dx;
                const cy = gy + dy;
                const cz = gz + dz;

                const p = voronoiFeaturePoint3(cx, cy, cz, cell_size);
                const ox = fx - p[0];
                const oy = fy - p[1];
                const oz = fz - p[2];
                const d2 = ox * ox + oy * oy + oz * oz;

                if (d2 < nearest) {
                    second = nearest;
                    nearest = d2;
                } else if (d2 < second) {
                    second = d2;
                }
            }
        }
    }

    return @sqrt(second) - @sqrt(nearest);
}

pub fn inVoronoiBorderLocal(
    x: i32,
    y: i32,
    z: i32,
    size: i32,
) bool {
    _ = size;

    const edge = voronoiEdge3(x, y, z, 4);
    return edge < 0.85;
}

pub fn inVoronoiBorderWorld(
    x: i32,
    y: i32,
    z: i32,
) bool {
    const edge = voronoiEdge3(x, y, z, 12);
    return edge < 1.0;
}

const Voronoi4Sample = struct {
    d1: f32,
    d2: f32,
    d3: f32,
    d4: f32,
};
pub fn voronoi4Distances(
    wx: i32,
    wy: i32,
    wz: i32,
    cell_size_i: i32,
) Voronoi4Sample {
    const fx = @as(f32, @floatFromInt(wx));
    const fy = @as(f32, @floatFromInt(wy));
    const fz = @as(f32, @floatFromInt(wz));
    const cell_size = @as(f32, @floatFromInt(cell_size_i));

    const gx = @divFloor(wx, cell_size_i);
    const gy = @divFloor(wy, cell_size_i);
    const gz = @divFloor(wz, cell_size_i);

    var best1: f32 = 1e30;
    var best2: f32 = 1e30;
    var best3: f32 = 1e30;
    var best4: f32 = 1e30;

    var dz: i32 = -1;
    while (dz <= 1) : (dz += 1) {
        var dy: i32 = -1;
        while (dy <= 1) : (dy += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = gx + dx;
                const cy = gy + dy;
                const cz = gz + dz;

                const p = voronoiFeaturePoint3(cx, cy, cz, cell_size);
                const ox = fx - p[0];
                const oy = fy - p[1];
                const oz = fz - p[2];
                const d2 = ox * ox + oy * oy + oz * oz;

                if (d2 < best1) {
                    best4 = best3;
                    best3 = best2;
                    best2 = best1;
                    best1 = d2;
                } else if (d2 < best2) {
                    best4 = best3;
                    best3 = best2;
                    best2 = d2;
                } else if (d2 < best3) {
                    best4 = best3;
                    best3 = d2;
                } else if (d2 < best4) {
                    best4 = d2;
                }
            }
        }
    }

    return .{
        .d1 = @sqrt(best1),
        .d2 = @sqrt(best2),
        .d3 = @sqrt(best3),
        .d4 = @sqrt(best4),
    };
}
pub fn inVoronoiFaceEdgesWorld(
    x: i32,
    y: i32,
    z: i32,
) bool {
    const v = voronoi4Distances(x, y, z, 40);

    const e12 = v.d2 - v.d1;
    const e23 = v.d3 - v.d2;
    const e34 = v.d4 - v.d3;

    // must be near a 3-region tie, not just a normal 2-region face
    const line_metric = @max(e12, e23);

    // near 4-region vertex => make line thicker there
    const vertex_boost = 1.0 - clamp01(e34 / 1.6);

    const base_thickness: f32 = 4;
    const thickness = base_thickness + vertex_boost * 1.5;

    return line_metric < thickness;
}
