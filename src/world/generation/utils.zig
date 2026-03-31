pub fn mix32(x: u32) u32 {
    var n = x;
    n ^= n >> 16;
    n *%= 0x7feb352d;
    n ^= n >> 15;
    n *%= 0x846ca68b;
    n ^= n >> 16;
    return n;
}

pub fn hash(x: i32, z: i32) f32 {
    const ux: u32 = @bitCast(x);
    const uz: u32 = @bitCast(z);

    const n = mix32(ux ^ mix32(uz +% 0x9e3779b9));
    return @as(f32, @floatFromInt(n)) / 4294967295.0;
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn smooth(t: f32) f32 {
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
}

pub fn hash32(x: i32, z: i32) u32 {
    var n: u32 = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(z)) *% 668265263;
    n = (n ^ (n >> 13)) *% 1274126177;
    return n;
}

pub fn grad(h: u32, x: f32, z: f32) f32 {
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

pub fn posMod(a: i32, b: i32) i32 {
    return @mod(a, b);
}

pub fn smooth3(t: f32) f32 {
    return t * t * (3.0 - 2.0 * t);
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

pub fn hashFloat01(x: i32, y: i32, z: i32) f32 {
    const h = chunkHash3(x, y, z);
    return @as(f32, @floatFromInt(h & 0x00ffffff)) / 16777215.0;
}


pub fn clamp01(x: f32) f32 {
    if (x < 0.0) return 0.0;
    if (x > 1.0) return 1.0;
    return x;
}

pub fn rand01(x: i32, y: i32, z: i32, salt: u32) f32 {
    var h = chunkHash3(x, y, z) ^ salt;
    h = mix32(h);
    return @as(f32, @floatFromInt(h & 0x00ffffff)) / 16777215.0;
}
