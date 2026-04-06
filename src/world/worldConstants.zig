pub const STREAM_CHUNKS_XZ = 16;
pub const STREAM_CHUNKS_Y = 16;

pub const BLOCK_VOXEL_CNT = 16; // voxels per block side
pub const BLOCK_PALLETE_SIZE = 256;

pub const CHUNK_BLOCK_CNT = 16; // blocks per chunk side
pub const CHUNK_VOXEL_CNT = BLOCK_VOXEL_CNT * CHUNK_BLOCK_CNT; // 256 voxels per chunk side
pub const CHUNK_BLOCK_TOTAL = CHUNK_BLOCK_CNT * CHUNK_BLOCK_CNT * CHUNK_BLOCK_CNT;
