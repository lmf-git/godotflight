pub const CHUNK_SIZE: usize = 32;
pub const VOXEL_OVERLAP: usize = 2;
pub const VOXEL_GRID: usize = CHUNK_SIZE + VOXEL_OVERLAP * 2; // 36

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CubeFace {
    PosX = 0,
    NegX = 1,
    PosY = 2,
    NegY = 3,
    PosZ = 4,
    NegZ = 5,
}

impl CubeFace {
    /// Returns (face_normal, tangent_u, tangent_v) as ([f32;3], [f32;3], [f32;3])
    pub fn tangent_frame(&self) -> ([f32; 3], [f32; 3], [f32; 3]) {
        match self {
            CubeFace::PosX => ([1., 0., 0.], [0., 0., 1.], [0., 1., 0.]),
            CubeFace::NegX => ([-1., 0., 0.], [0., 0., -1.], [0., 1., 0.]),
            CubeFace::PosY => ([0., 1., 0.], [1., 0., 0.], [0., 0., 1.]),
            CubeFace::NegY => ([0., -1., 0.], [-1., 0., 0.], [0., 0., 1.]),
            CubeFace::PosZ => ([0., 0., 1.], [-1., 0., 0.], [0., 1., 0.]),
            CubeFace::NegZ => ([0., 0., -1.], [1., 0., 0.], [0., 1., 0.]),
        }
    }

    pub fn from_dir(dx: f32, dy: f32, dz: f32) -> CubeFace {
        let ax = dx.abs();
        let ay = dy.abs();
        let az = dz.abs();
        if ax >= ay && ax >= az {
            if dx > 0.0 {
                CubeFace::PosX
            } else {
                CubeFace::NegX
            }
        } else if ay >= ax && ay >= az {
            if dy > 0.0 {
                CubeFace::PosY
            } else {
                CubeFace::NegY
            }
        } else if dz > 0.0 {
            CubeFace::PosZ
        } else {
            CubeFace::NegZ
        }
    }

    pub fn all() -> [CubeFace; 6] {
        [
            CubeFace::PosX,
            CubeFace::NegX,
            CubeFace::PosY,
            CubeFace::NegY,
            CubeFace::PosZ,
            CubeFace::NegZ,
        ]
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct ChunkKey {
    pub face: CubeFace,
    pub lod: u8,
    pub cx: i32,
    pub cy: i32,
}


pub struct ChunkResult {
    pub key: ChunkKey,
    pub mesh_data: Option<MeshData>,
}

pub struct MeshData {
    pub vertices: Vec<[f32; 3]>,
    pub normals: Vec<[f32; 3]>,
    pub indices: Vec<i32>,
}

pub enum ChunkState {
    Requested,
    Empty, // Chunk was generated but produced no geometry (fully underground/sky)
}
