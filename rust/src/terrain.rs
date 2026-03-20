use noise::{Fbm, MultiFractal, NoiseFn, Perlin};

use crate::chunk::{CubeFace, CHUNK_SIZE, VOXEL_GRID, VOXEL_OVERLAP};
use crate::math::cube_face_to_dir;
use crate::uber_noise::{UberNoise, UberNoiseParams};

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub struct PlanetParams {
    pub radius: f32,
    /// ±meters of terrain height variation from noise
    pub elevation_range: f32,
    pub seed: u32,
    /// 0 = Earth-like planet, 1 = Moon with craters
    pub terrain_style: i32,
}

/// A procedurally placed settlement site.
#[derive(Clone)]
pub struct CitySpec {
    /// Unit-sphere direction to the site centre.
    pub dir: [f32; 3],
    /// Ground elevation above sea level (metres).
    pub base_elev_m: f32,
    /// Radius of the flattened pad (metres on sphere surface).
    pub flat_radius_m: f32,
    /// 0 = town, 1 = city, 2 = airport
    pub kind: u8,
}

/// A procedurally placed impact crater (moon terrain mode).
#[derive(Clone)]
pub struct CraterSpec {
    /// Unit-sphere direction to crater centre.
    pub dir: [f32; 3],
    /// Crater rim radius in metres.
    pub radius_m: f32,
    /// Maximum depth of the bowl below the surrounding surface (metres).
    pub depth_m: f32,
}

// ---------------------------------------------------------------------------
// Tiny deterministic PRNG (LCG) used only during construction
// ---------------------------------------------------------------------------

fn lcg_next(state: &mut u64) -> f32 {
    *state = state
        .wrapping_mul(6_364_136_223_846_793_005u64)
        .wrapping_add(1_442_695_040_888_963_407u64);
    ((*state >> 33) as f32) / (u32::MAX as f32)
}

fn random_unit_sphere(state: &mut u64) -> [f32; 3] {
    for _ in 0..200 {
        let x = lcg_next(state) * 2.0 - 1.0;
        let y = lcg_next(state) * 2.0 - 1.0;
        let z = lcg_next(state) * 2.0 - 1.0;
        let len2 = x * x + y * y + z * z;
        if len2 > 0.001 && len2 <= 1.0 {
            let len = len2.sqrt();
            return [x / len, y / len, z / len];
        }
    }
    [1.0, 0.0, 0.0]
}

// ---------------------------------------------------------------------------
// Terrain sampler
// ---------------------------------------------------------------------------

pub struct TerrainSampler {
    pub params: PlanetParams,
    elevation: UberNoise,
    cave: Fbm<Perlin>,
    /// Zero-crossings of this noise define river channel networks.
    river: Fbm<Perlin>,
    /// Procedurally placed settlement sites (planet mode only).
    cities: Vec<CitySpec>,
    /// Procedurally placed impact craters (moon mode only).
    craters: Vec<CraterSpec>,
}

// Safety: UberNoise and Fbm<Perlin> are stateless after construction
unsafe impl Send for TerrainSampler {}
unsafe impl Sync for TerrainSampler {}

impl TerrainSampler {
    pub fn new(params: PlanetParams) -> Self {
        let elev_params = if params.terrain_style == 1 {
            // Moon: gentle rolling base hills — craters dominate the relief.
            UberNoiseParams {
                seed: params.seed,
                octaves: 4,
                frequency: 0.4,
                lacunarity: 2.0,
                gain: 0.5,
                sharpness: 0.3,
                slope_erosion: 0.1,
                warp_strength: 0.15,
                warp_scale: 0.3,
                altitude_damping: 0.05,
            }
        } else {
            // Earth-like planet: sharp ridges, erosion, warp.
            UberNoiseParams {
                seed: params.seed,
                octaves: 6,
                frequency: 0.85,
                lacunarity: 2.0,
                gain: 0.5,
                sharpness: 0.70,
                slope_erosion: 0.70,
                warp_strength: 0.65,
                warp_scale: 0.6,
                altitude_damping: 0.55,
            }
        };

        let elevation = UberNoise::new(elev_params);

        // Deeper cave worms: 5 octaves, sampled at lower frequency (larger caves).
        let cave = Fbm::<Perlin>::new(params.seed.wrapping_add(1337))
            .set_octaves(5)
            .set_frequency(1.0);

        let river = Fbm::<Perlin>::new(params.seed.wrapping_add(9001))
            .set_octaves(3)
            .set_frequency(1.0);

        // ── City site generation (planet mode only) ───────────────────────────
        let cities = if params.terrain_style != 1 {
            let mut rng: u64 = (params.seed as u64).wrapping_mul(0xbeef_cafe_dead_1337);
            let mut candidates: Vec<([f32; 3], f32)> = Vec::new();

            for _ in 0..500 {
                let dir = random_unit_sphere(&mut rng);
                let v = (elevation.sample(dir[0] as f64, dir[1] as f64, dir[2] as f64) - 0.25) as f32;
                let elev_m = v * params.elevation_range;
                if elev_m >= 5.0 && elev_m <= 200.0 {
                    let rv = river.get([
                        dir[0] as f64 * 4.0,
                        dir[1] as f64 * 4.0,
                        dir[2] as f64 * 4.0,
                    ]) as f32;
                    if rv.abs() > 0.22 {
                        candidates.push((dir, elev_m));
                    }
                }
            }

            let min_chord = 1500.0_f32 / params.radius;
            let mut out: Vec<CitySpec> = Vec::new();
            for &(dir, elev_m) in &candidates {
                let too_close = out.iter().any(|c: &CitySpec| {
                    let dot = dir[0] * c.dir[0] + dir[1] * c.dir[1] + dir[2] * c.dir[2];
                    ((1.0 - dot.clamp(-1.0, 1.0)) * 2.0).sqrt() < min_chord
                });
                if !too_close {
                    let kind: u8 = match out.len() % 6 {
                        0 => 2,     // airport every 6th
                        1 | 2 => 1, // city
                        _ => 0,     // town
                    };
                    let flat_r: f32 = match kind {
                        2 => 480.0,
                        1 => 300.0,
                        _ => 170.0,
                    };
                    out.push(CitySpec { dir, base_elev_m: elev_m, flat_radius_m: flat_r, kind });
                    if out.len() >= 30 {
                        break;
                    }
                }
            }
            out
        } else {
            Vec::new()
        };

        // ── Crater generation (moon mode only) ───────────────────────────────
        let craters = if params.terrain_style == 1 {
            let mut rng: u64 = (params.seed as u64).wrapping_mul(0xdead_beef_1234_5678);
            let mut v: Vec<CraterSpec> = Vec::new();

            // Large basins (800–2000 m radius)
            for _ in 0..8 {
                let dir = random_unit_sphere(&mut rng);
                let radius_m = 800.0 + lcg_next(&mut rng) * 1200.0;
                let depth_m = radius_m * 0.20 * (0.8 + lcg_next(&mut rng) * 0.4);
                v.push(CraterSpec { dir, radius_m, depth_m });
            }
            // Medium craters (200–600 m radius)
            for _ in 0..35 {
                let dir = random_unit_sphere(&mut rng);
                let radius_m = 200.0 + lcg_next(&mut rng) * 400.0;
                let depth_m = radius_m * 0.22 * (0.7 + lcg_next(&mut rng) * 0.6);
                v.push(CraterSpec { dir, radius_m, depth_m });
            }
            // Small pockmarks (30–150 m radius)
            for _ in 0..100 {
                let dir = random_unit_sphere(&mut rng);
                let radius_m = 30.0 + lcg_next(&mut rng) * 120.0;
                let depth_m = radius_m * 0.25 * (0.6 + lcg_next(&mut rng) * 0.8);
                v.push(CraterSpec { dir, radius_m, depth_m });
            }
            v
        } else {
            Vec::new()
        };

        Self { params, elevation, cave, river, cities, craters }
    }

    pub fn cities(&self) -> &[CitySpec] {
        &self.cities
    }

    // ── Elevation sampling ───────────────────────────────────────────────────

    /// Sample elevation at a normalized sphere direction (dx, dy, dz).
    /// Returns offset in meters from planet surface (positive = above sea level).
    pub fn elevation_at(&self, dx: f32, dy: f32, dz: f32) -> f32 {
        if self.params.terrain_style == 1 {
            return self.elevation_at_moon(dx, dy, dz);
        }

        let v = (self.elevation.sample(dx as f64, dy as f64, dz as f64) - 0.25) as f32;

        // River valley carving: only on land and below ~400 m.
        let v_carved = if v > 0.01 {
            let rs = 4.0_f64;
            let rv = self.river.get([dx as f64 * rs, dy as f64 * rs, dz as f64 * rs]) as f32;

            let elev_gate = 400.0 / self.params.elevation_range;
            let elev_fade = (1.0 - (v / elev_gate).min(1.0)).powf(1.5);

            let channel = (1.0 - (rv.abs() / 0.38).min(1.0)).powf(1.5) * elev_fade;

            if channel > 0.001 {
                let sea_margin = 15.0 / self.params.elevation_range;
                let canyon_cap = 500.0 / self.params.elevation_range;
                v - channel * (v + sea_margin).min(canyon_cap)
            } else {
                v
            }
        } else {
            v
        };

        // City pad flattening
        let mut v_final = v_carved;
        for city in &self.cities {
            let dot = (dx * city.dir[0] + dy * city.dir[1] + dz * city.dir[2]).clamp(-1.0, 1.0);
            let chord = ((1.0 - dot) * 2.0).sqrt();
            let chord_r = city.flat_radius_m / self.params.radius;
            if chord < chord_r * 1.5 {
                let t = (1.0 - chord / chord_r).clamp(0.0, 1.0);
                let t = t * t * (3.0 - 2.0 * t);
                let target = city.base_elev_m / self.params.elevation_range;
                v_final = v_final * (1.0 - t) + target * t;
            }
        }

        v_final * self.params.elevation_range
    }

    /// Moon terrain: gentle base undulation + crater bowl depressions with rim uplift.
    fn elevation_at_moon(&self, dx: f32, dy: f32, dz: f32) -> f32 {
        let base_v = self.elevation.sample(dx as f64, dy as f64, dz as f64) as f32;
        let base = base_v * self.params.elevation_range * 0.06;

        let mut crater_sum = 0.0_f32;
        for crater in &self.craters {
            let dot = (dx * crater.dir[0] + dy * crater.dir[1] + dz * crater.dir[2])
                .clamp(-1.0, 1.0);
            let chord = ((1.0 - dot) * 2.0_f32).sqrt();
            let d = chord / (crater.radius_m / self.params.radius);
            if d < 2.0 {
                crater_sum += crater_profile(d, crater.depth_m);
            }
        }

        base + crater_sum
    }

    // ── Chunk density ────────────────────────────────────────────────────────

    /// Fill a VOXEL_GRID^3 density array for the given chunk.
    /// Index layout: ix + iy * VOXEL_GRID + iz * VOXEL_GRID * VOXEL_GRID
    pub fn fill_chunk(&self, face: CubeFace, lod: u8, cx: i32, cy: i32) -> Vec<f32> {
        let voxel_size = (1u32 << lod) as f32;
        let chunk_meters = CHUNK_SIZE as f32 * voxel_size;
        let r = self.params.radius;

        let mut densities = vec![0.0f32; VOXEL_GRID * VOXEL_GRID * VOXEL_GRID];

        for iz in 0..VOXEL_GRID {
            let cv = cy as f32 * chunk_meters
                + (iz as i32 - VOXEL_OVERLAP as i32) as f32 * voxel_size;

            for ix in 0..VOXEL_GRID {
                let cu = cx as f32 * chunk_meters
                    + (ix as i32 - VOXEL_OVERLAP as i32) as f32 * voxel_size;

                let dir = cube_face_to_dir(face, cu, cv, r);
                let (dx, dy, dz) = (dir[0], dir[1], dir[2]);

                let elev = self.elevation_at(dx, dy, dz);
                let surface_h = r + elev;

                for iy in 0..VOXEL_GRID {
                    let h = r + elev + (iy as f32 - VOXEL_GRID as f32 * 0.5) * voxel_size;
                    let wx = dx * h;
                    let wy = dy * h;
                    let wz = dz * h;

                    let mut density = surface_h - h;

                    // Cave worms: planet only (moon has no caves).
                    // cave_scale=0.010, threshold=0.25, carve strength=280.
                    // depth_fade starts 5 m above surface to guarantee cave openings.
                    if self.params.terrain_style != 1 {
                        let cave_scale = 0.010_f64;
                        let cave_v = self.cave.get([
                            wx as f64 * cave_scale,
                            wy as f64 * cave_scale,
                            wz as f64 * cave_scale,
                        ]) as f32;
                        let carve = (cave_v - 0.25).max(0.0) * 280.0;
                        if carve > 0.0 {
                            let depth_fade = ((density + 5.0) / 30.0).clamp(0.0, 1.0);
                            density -= carve * depth_fade;
                        }
                    }

                    let idx = ix + iy * VOXEL_GRID + iz * VOXEL_GRID * VOXEL_GRID;
                    densities[idx] = density;
                }
            }
        }

        densities
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Lunar crater elevation profile as a function of normalised distance d
/// (0 = crater centre, 1 = rim edge) and bowl depth (metres).
#[inline]
fn crater_profile(d: f32, depth: f32) -> f32 {
    if d < 1.0 {
        depth * (d * d - 1.0)
    } else if d < 1.5 {
        let t = (d - 1.0) / 0.5;
        depth * 0.28 * (1.0 - t) * (1.0 - t)
    } else {
        0.0
    }
}
