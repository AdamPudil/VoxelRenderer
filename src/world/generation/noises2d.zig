const utils = @import("utils.zig");

pub fn noise2D(x: f32, z: f32) f32 {
    const xi = @as(i32, @intFromFloat(@floor(x)));
    const zi = @as(i32, @intFromFloat(@floor(z)));

    const xf = x - @floor(x);
    const zf = z - @floor(z);

    const u = utils.smooth(xf);
    const v = utils.smooth(zf);

    const n00 = utils.grad(utils.hash32(xi, zi), xf, zf);
    const n10 = utils.grad(utils.hash32(xi + 1, zi), xf - 1.0, zf);
    const n01 = utils.grad(utils.hash32(xi, zi + 1), xf, zf - 1.0);
    const n11 = utils.grad(utils.hash32(xi + 1, zi + 1), xf - 1.0, zf - 1.0);

    const nx0 = utils.lerp(n00, n10, u);
    const nx1 = utils.lerp(n01, n11, u);

    return utils.lerp(nx0, nx1, v) * 0.70710677;
}

fn valueNoiseTile3(x: f32, y: f32, z: f32, period: i32) f32 {
    const xi0f = @floor(x);
    const yi0f = @floor(y);
    const zi0f = @floor(z);

    const tx = x - xi0f;
    const ty = y - yi0f;
    const tz = z - zi0f;

    const xi0: i32 = @intFromFloat(xi0f);
    const yi0: i32 = @intFromFloat(yi0f);
    const zi0: i32 = @intFromFloat(zi0f);

    const xi1 = xi0 + 1;
    const yi1 = yi0 + 1;
    const zi1 = zi0 + 1;

    const x0 = utils.posMod(xi0, period);
    const y0 = utils.posMod(yi0, period);
    const z0 = utils.posMod(zi0, period);
    const x1 = utils.posMod(xi1, period);
    const y1 = utils.posMod(yi1, period);
    const z1 = utils.posMod(zi1, period);

    const sx = utils.smooth3(tx);
    const sy = utils.smooth3(ty);
    const sz = utils.smooth3(tz);

    const c000 = utils.hashFloat01(x0, y0, z0);
    const c100 = utils.hashFloat01(x1, y0, z0);
    const c010 = utils.hashFloat01(x0, y1, z0);
    const c110 = utils.hashFloat01(x1, y1, z0);
    const c001 = utils.hashFloat01(x0, y0, z1);
    const c101 = utils.hashFloat01(x1, y0, z1);
    const c011 = utils.hashFloat01(x0, y1, z1);
    const c111 = utils.hashFloat01(x1, y1, z1);

    const x00 = utils.lerp(c000, c100, sx);
    const x10 = utils.lerp(c010, c110, sx);
    const x01 = utils.lerp(c001, c101, sx);
    const x11 = utils.lerp(c011, c111, sx);

    const y0v = utils.lerp(x00, x10, sy);
    const y1v = utils.lerp(x01, x11, sy);

    return utils.lerp(y0v, y1v, sz);
}

pub fn fbmTile3(x: f32, y: f32, z: f32, period: i32) f32 {
    var sum: f32 = 0.0;
    var amp: f32 = 0.5;
    var freq: f32 = 1.0;
    var norm: f32 = 0.0;

    inline for (0..4) |_| {
        sum += valueNoiseTile3(x * freq, y * freq, z * freq, @intFromFloat(@as(f32, @floatFromInt(period)) * freq)) * amp;
        norm += amp;
        amp *= 0.5;
        freq *= 2.0;
    }

    return sum / norm;
}
