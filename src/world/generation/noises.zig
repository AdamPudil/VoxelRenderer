fn hash(x: i32, z: i32) f32 {
    var n: u32 = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(z)) *% 668265263;
    n = (n ^ (n >> 13)) *% 1274126177;
    return @as(f32, @floatFromInt(n & 0x7fffffff)) / 2147483647.0;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn smooth(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

pub fn noise2D(x: f32, z: f32) f32 {
    const xi = @as(i32, @intFromFloat(@floor(x)));
    const zi = @as(i32, @intFromFloat(@floor(z)));

    const xf = x - @floor(x);
    const zf = z - @floor(z);

    const h00 = hash(xi, zi);
    const h10 = hash(xi + 1, zi);
    const h01 = hash(xi, zi + 1);
    const h11 = hash(xi + 1, zi + 1);

    const u = smooth(xf);
    const v = smooth(zf);

    return lerp(lerp(h00, h10, u), lerp(h01, h11, u), v);
}
