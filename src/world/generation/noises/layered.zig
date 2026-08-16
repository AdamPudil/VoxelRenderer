pub const noiseType = enum {
    perlin,
    voronoi,
};

pub const remapType = union(enum) {
    none,
    linear,
    invert,
    power: struct {
        exponent: f32,
    },
    root: struct {
        exponent: f32,
    },
    smoothStep,
    smootherStep,
    treshold: struct {
        treshold: f32,
    },
    terrace: struct { stepCount: f32 },
    ridge,
    valley,
};

pub const layer = struct {
    noise: noiseType,
    noiseGridSize: i32,

    remap: remapType,
};
