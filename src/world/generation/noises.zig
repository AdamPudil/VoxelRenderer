fn mix32(x: u32) u32 {
    var n = x;
    n ^= n >> 16;
    n *%= 0x7feb352d;
    n ^= n >> 15;
    n *%= 0x846ca68b;
    n ^= n >> 16;
    return n;
}

fn hash(x: i32, z: i32) f32 {
    const ux: u32 = @bitCast(x);
    const uz: u32 = @bitCast(z);

    const n = mix32(ux ^ mix32(uz +% 0x9e3779b9));
    return @as(f32, @floatFromInt(n)) / 4294967295.0;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn smooth(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

fn hash32(x: i32, z: i32) u32 {
    var n: u32 = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(z)) *% 668265263;
    n = (n ^ (n >> 13)) *% 1274126177;
    return n;
}

fn grad(h: u32, x: f32, z: f32) f32 {
    return switch (h & 7) {
        0 => x + z,
        1 => x - z,
        2 => -x + z,
        3 => -x - z,
        4 => x,
        5 => -x,
        6 => z,
        else => -z,
    };
}

pub fn noise2D(x: f32, z: f32) f32 {
    const xi = @as(i32, @intFromFloat(@floor(x)));
    const zi = @as(i32, @intFromFloat(@floor(z)));

    const xf = x - @floor(x);
    const zf = z - @floor(z);

    const u = smooth(xf);
    const v = smooth(zf);

    const n00 = grad(hash32(xi, zi), xf, zf);
    const n10 = grad(hash32(xi + 1, zi), xf - 1.0, zf);
    const n01 = grad(hash32(xi, zi + 1), xf, zf - 1.0);
    const n11 = grad(hash32(xi + 1, zi + 1), xf - 1.0, zf - 1.0);

    const nx0 = lerp(n00, n10, u);
    const nx1 = lerp(n01, n11, u);

    return lerp(nx0, nx1, v) * 0.70710677;
}
