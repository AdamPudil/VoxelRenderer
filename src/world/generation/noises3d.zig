const utils = @import("utils.zig");
const noise2d = @import("noises2d.zig");
const std = @import("std");

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn smooth01(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
}

fn hash2(x: i32, z: i32) u32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x85ebca6b;
    h ^= @as(u32, @bitCast(z)) *% 0xc2b2ae35;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return h;
}

fn rand01FromHash(h: u32) f32 {
    return @as(f32, @floatFromInt(h & 0x00ffffff)) / 16777215.0;
}

pub fn valueNoise2(x: f32, z: f32, scale: f32) f32 {
    const fx = x / scale;
    const fz = z / scale;

    const x0: i32 = @intFromFloat(@floor(fx));
    const z0: i32 = @intFromFloat(@floor(fz));
    const x1 = x0 + 1;
    const z1 = z0 + 1;

    const tx = smooth01(fx - @as(f32, @floatFromInt(x0)));
    const tz = smooth01(fz - @as(f32, @floatFromInt(z0)));

    const v00 = rand01FromHash(hash2(x0, z0));
    const v10 = rand01FromHash(hash2(x1, z0));
    const v01 = rand01FromHash(hash2(x0, z1));
    const v11 = rand01FromHash(hash2(x1, z1));

    const a = lerp(v00, v10, tx);
    const b = lerp(v01, v11, tx);
    return lerp(a, b, tz) * 2.0 - 1.0;
}

pub fn fbm2(x: f32, z: f32) f32 {
    var sum: f32 = 0.0;
    var amp: f32 = 1.0;
    var norm: f32 = 0.0;
    var scale: f32 = 96.0;

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        sum += valueNoise2(x, z, scale) * amp;
        norm += amp;
        amp *= 0.5;
        scale *= 0.5;
    }

    return sum / norm;
}

pub fn ridge2(x: f32, z: f32) f32 {
    const n = valueNoise2(x, z, 48.0);
    return 1.0 - @abs(n);
}

pub fn terrainBaseHeight(wx: i32, wz: i32) i32 {
    const x = @as(f32, @floatFromInt(wx));
    const z = @as(f32, @floatFromInt(wz));

    const broad = fbm2(x, z); // large hills
    const detail = valueNoise2(x + 1000.0, z - 700.0, 24.0);
    const ridges = ridge2(x - 300.0, z + 500.0);

    const h =
        broad * 18.0 +
        detail * 4.0 +
        ridges * 6.0;

    return @as(i32, @intFromFloat(@floor(h)));
}

pub fn terrainSlope(wx: i32, wz: i32) i32 {
    const h = terrainBaseHeight(wx, wz);
    const hx = terrainBaseHeight(wx + 1, wz);
    const hz = terrainBaseHeight(wx, wz + 1);

    const dx = @abs(hx - h);
    const dz = @abs(hz - h);
    return @intCast(dx + dz);
}

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

pub fn sample3(x: f32, y: f32, z: f32) f32 {
    const xy = noise2d.noise2D(x, y);
    const yz = noise2d.noise2D(y + 31.7, z - 11.3);
    const xz = noise2d.noise2D(x - 19.1, z + 47.9);
    return (xy + yz + xz) / 3.0;
}

pub fn fbm3(x: f32, y: f32, z: f32, octaves: u32, lacunarity: f32, gain: f32) f32 {
    var sum: f32 = 0.0;
    var amp: f32 = 1.0;
    var freq: f32 = 1.0;
    var norm: f32 = 0.0;
    var i: u32 = 0;
    while (i < octaves) : (i += 1) {
        sum += sample3(x * freq, y * freq, z * freq) * amp;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return if (norm > 0.0) sum / norm else 0.0;
}

pub fn caveNoise(x: f32, y: f32, z: f32) f32 {
    const a = @abs(fbm3(x * 0.045, y * 0.06, z * 0.045, 3, 2.0, 0.5));
    const b = @abs(fbm3(x * 0.09 + 17.3, y * 0.08 - 8.1, z * 0.09 + 41.5, 2, 2.0, 0.5));
    return a * 0.7 + b * 0.3;
}

pub fn overhangNoise(x: f32, y: f32, z: f32) f32 {
    const warp = fbm3(x * 0.018, y * 0.018, z * 0.018, 2, 2.0, 0.5);
    return fbm3(x * 0.032 + warp * 5.0, y * 0.024, z * 0.032 - warp * 5.0, 4, 2.0, 0.5);
}

pub fn terrainDensity(x: f32, y: f32, z: f32) f32 {
    const base_height = noise2d.terrainBaseHeight(x, z);
    const slope = noise2d.slopeMask(x, z);
    const surface_delta = base_height - y;

    var density = surface_delta;

    if (surface_delta > -18.0 and surface_delta < 10.0) {
        const overhang = overhangNoise(x, y, z);
        const cliff_mask = @max(0.0, @min((slope - 1.8) * 0.45, 1.0));
        density += (overhang - 0.08) * (7.0 + cliff_mask * 10.0);
    }

    if (surface_delta > 6.0) {
        const caves = caveNoise(x, y, z);
        density -= @max(0.0, 0.34 - caves) * 38.0;
    }

    density += fbm3(x * 0.02, y * 0.02, z * 0.02, 2, 2.0, 0.5) * 1.5;
    return density;
}

pub fn terrainMaterial(x: i32, y: i32, z: i32) u16 {
    const fx = @as(f32, @floatFromInt(x));
    const fy = @as(f32, @floatFromInt(y));
    const fz = @as(f32, @floatFromInt(z));

    const h = noise2d.terrainBaseHeight(fx, fz);
    const slope = noise2d.slopeMask(fx, fz);
    const surface_depth = h - fy;

    if (surface_depth <= 1.2 and slope < 2.2) return 2; // grass
    if (surface_depth <= 4.0 and slope < 3.4) return 1; // dirt
    return 3; // stone
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

    const nx = (fx - ch) / ch;
    const ny = (fy - ch) / ch;
    const nz = (fz - ch) / ch;

    const r2 = nx * nx + ny * ny + nz * nz;

    const n1 = noise2d.fbmTile3(fx * 0.22, fy * 0.22, fz * 0.22, size);
    const n2 = noise2d.fbmTile3((fx + 17.0) * 0.45, (fy + 9.0) * 0.45, (fz + 31.0) * 0.45, size);

    const caves = @abs(n2 - 0.5);
    const density = (1.05 - r2) + (n1 - 0.5) * 0.85 - (0.18 - caves) * 2.2;

    return density > 0.0;
}

pub fn max3(a: f32, b: f32, c_: f32) f32 {
    return @max(a, @max(b, c_));
}

pub fn crystalCell(fx: f32, fy: f32, fz: f32, cx: f32, cy: f32, cz: f32, sx: f32, sy: f32, sz: f32) bool {
    const dx = @abs(fx - cx) / sx;
    const dy = @abs(fy - cy) / sy;
    const dz = @abs(fz - cz) / sz;
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
    const rock_noise = noise2d.fbmTile3(fx * 0.18, fy * 0.18, fz * 0.18, size);
    const rock_density = (1.18 - r2) + (rock_noise - 0.5) * 0.55;
    if (rock_density <= 0.0) return false;

    const cave_noise = noise2d.fbmTile3((fx + 41.0) * 0.23, (fy + 17.0) * 0.23, (fz + 73.0) * 0.23, size);
    const cave_shape = ((nx * nx) * 1.1) + ((ny * ny) * 0.55) + ((nz * nz) * 1.1);
    const cave_density = (0.42 - cave_shape) + (cave_noise - 0.5) * 0.28;
    const in_cave = cave_density > 0.0;
    if (!in_cave) return true;

    if (crystalCell(fx, fy, fz, ch, 2.0, ch, 1.1, 4.8, 1.1)) return true;
    if (crystalCell(fx, fy, fz, ch - 3.0, @as(f32, @floatFromInt(size - 3)), ch + 2.0, 1.0, 3.8, 1.0)) return true;
    if (crystalCell(fx, fy, fz, 2.0, ch + 1.0, ch - 2.0, 3.6, 1.0, 1.0)) return true;
    if (crystalCell(fx, fy, fz, @as(f32, @floatFromInt(size - 3)), ch - 1.0, ch + 1.0, 3.2, 1.0, 1.0)) return true;
    if (crystalCell(fx, fy, fz, ch + 1.5, ch + 1.5, ch - 1.5, 0.8, 2.4, 0.8)) return true;

    return false;
}

fn voronoiFeaturePoint3(cell_x: i32, cell_y: i32, cell_z: i32) [3]f32 {
    return .{
        @as(f32, @floatFromInt(cell_x)) + utils.rand01(cell_x, cell_y, cell_z, 0x68bc21eb),
        @as(f32, @floatFromInt(cell_y)) + utils.rand01(cell_x, cell_y, cell_z, 0x02e5be93),
        @as(f32, @floatFromInt(cell_z)) + utils.rand01(cell_x, cell_y, cell_z, 0x967a889b),
    };
}

fn sort3(a: *f32, b: *f32, c_: *f32) void {
    if (a.* > b.*) {
        const t = a.*;
        a.* = b.*;
        b.* = t;
    }
    if (b.* > c_.*) {
        const t = b.*;
        b.* = c_.*;
        c_.* = t;
    }
    if (a.* > b.*) {
        const t = a.*;
        a.* = b.*;
        b.* = t;
    }
}

fn voronoiNearest3(x: f32, y: f32, z: f32) [3]f32 {
    const base_x: i32 = @intFromFloat(@floor(x));
    const base_y: i32 = @intFromFloat(@floor(y));
    const base_z: i32 = @intFromFloat(@floor(z));

    var d1: f32 = 1e9;
    var d2: f32 = 1e9;
    var d3: f32 = 1e9;

    var oz: i32 = -1;
    while (oz <= 1) : (oz += 1) {
        var oy: i32 = -1;
        while (oy <= 1) : (oy += 1) {
            var ox: i32 = -1;
            while (ox <= 1) : (ox += 1) {
                const cx = base_x + ox;
                const cy = base_y + oy;
                const cz = base_z + oz;
                const p = voronoiFeaturePoint3(cx, cy, cz);
                const dx = p[0] - x;
                const dy = p[1] - y;
                const dz = p[2] - z;
                const d = @sqrt(dx * dx + dy * dy + dz * dz);

                if (d < d1) {
                    d3 = d2;
                    d2 = d1;
                    d1 = d;
                } else if (d < d2) {
                    d3 = d2;
                    d2 = d;
                } else if (d < d3) {
                    d3 = d;
                }
            }
        }
    }

    return .{ d1, d2, d3 };
}

pub fn inVoronoiBorderLocal(x: i32, y: i32, z: i32, size: i32) bool {
    const fx = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(size)) * 3.0;
    const fy = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(size)) * 3.0;
    const fz = (@as(f32, @floatFromInt(z)) + 0.5) / @as(f32, @floatFromInt(size)) * 3.0;
    const d = voronoiNearest3(fx, fy, fz);
    return (d[1] - d[0]) < 0.12;
}

pub fn inVoronoiBorderWorld(x: i32, y: i32, z: i32) bool {
    const fx = (@as(f32, @floatFromInt(x)) + 0.5) * 0.16;
    const fy = (@as(f32, @floatFromInt(y)) + 0.5) * 0.16;
    const fz = (@as(f32, @floatFromInt(z)) + 0.5) * 0.16;
    const d = voronoiNearest3(fx, fy, fz);
    return (d[1] - d[0]) < 0.09;
}

pub fn inVoronoiFaceEdgesWorld(x: i32, y: i32, z: i32) bool {
    const fx = (@as(f32, @floatFromInt(x)) + 0.5) * 0.16;
    const fy = (@as(f32, @floatFromInt(y)) + 0.5) * 0.16;
    const fz = (@as(f32, @floatFromInt(z)) + 0.5) * 0.16;
    const d = voronoiNearest3(fx, fy, fz);
    var a = d[0];
    var b = d[1];
    var c = d[2];
    sort3(&a, &b, &c);
    return (b - a) < 0.08 and (c - a) < 0.16;
}
