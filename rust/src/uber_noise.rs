/// Über Noise — a unified procedural noise function based on the techniques
/// described in Sean Murray's GDC talk "Math for Game Programmers: Noise-Based RNG".
///
/// Combines four techniques from the talk:
///
/// 1. **Sharpness** — continuous blend between Billow (abs noise, round hills),
///    standard Perlin, and Ridge (1-abs noise, sharp cliffs).
///
/// 2. **Domain Warping** — distort the sample position with a second noise field
///    before sampling the main noise. Creates the river/coastal "flowing" patterns
///    seen in NMS. Based on IQ's fbm domain warping.
///
/// 3. **Slope-Responsive FBM** — IQ's erosion method: accumulate the absolute
///    value of each octave's contribution as a proxy for local slope. Use it to
///    attenuate higher-frequency octaves on steep slopes.
///    Effect: flat areas keep full detail; slopes become smoother (eroded).
///
/// 4. **Altitude Damping** — reduce noise amplitude near the extremes of the
///    elevation range, creating flat basin floors and plateau tops.
use noise::{NoiseFn, Perlin};

// ---------------------------------------------------------------------------
// Parameters
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
pub struct UberNoiseParams {
    pub seed: u32,

    /// Number of FBM octaves (higher = more detail, more expensive).
    pub octaves: usize,

    /// Base sampling frequency (lower = larger terrain features).
    pub frequency: f64,

    /// Frequency multiplier per octave (default 2.0).
    pub lacunarity: f64,

    /// Amplitude decay per octave / persistence (default 0.5).
    pub gain: f32,

    /// Sharpness:
    ///   0.0 = full Billow — abs(noise), smooth rolling hills
    ///   0.5 = standard Perlin
    ///   1.0 = full Ridge — 1.0 - abs(noise), sharp angular ridges & cliffs
    pub sharpness: f32,

    /// Slope erosion strength (IQ's method).
    /// Higher values → steeper slopes become smoother (more eroded look).
    /// 0.0 = disabled; 2.0 = strong erosion.
    pub slope_erosion: f32,

    /// Domain warp: offset sample position by a separate noise field.
    /// Controls the warp amount in the same units as the noise input.
    /// For elevation noise sampled on unit sphere: 0.3–1.0 is a good range.
    pub warp_strength: f32,

    /// Warp noise sampling frequency (default ~0.6× main frequency).
    pub warp_scale: f64,

    /// Altitude damping: reduce noise amplitude as value approaches ±1.
    /// Simulates glacial smoothing of peaks and tectonic basin floors.
    /// 0.0 = no damping; 1.0 = strong (values near ±1 become very flat).
    pub altitude_damping: f32,
}

impl Default for UberNoiseParams {
    fn default() -> Self {
        Self {
            seed: 0,
            octaves: 6,
            frequency: 0.001,
            lacunarity: 2.0,
            gain: 0.5,
            sharpness: 0.4,       // slight ridge — more interesting than flat Perlin
            slope_erosion: 1.0,   // moderate erosion
            warp_strength: 0.4,   // noticeable but not overwhelming warp
            warp_scale: 0.0006,
            altitude_damping: 0.2,
        }
    }
}

// ---------------------------------------------------------------------------
// Struct
// ---------------------------------------------------------------------------

/// Compiled Über Noise sampler. Construct once, sample many times.
pub struct UberNoise {
    params: UberNoiseParams,
    primary: Perlin,
    warp_u: Perlin, // domain warp for first axis
    warp_v: Perlin, // domain warp for second axis
    warp_w: Perlin, // domain warp for third axis
    /// 1 / sum(gain^i for i in 0..octaves) — precomputed so sample() avoids
    /// recomputing the geometric series on every call (millions of calls per chunk).
    inv_max_amp: f32,
}

// Perlin is Send+Sync (pure function, no interior mutability).
unsafe impl Send for UberNoise {}
unsafe impl Sync for UberNoise {}

impl UberNoise {
    pub fn new(params: UberNoiseParams) -> Self {
        let seed = params.seed;
        let max_amp: f32 = (0..params.octaves)
            .map(|i| params.gain.powi(i as i32))
            .sum::<f32>()
            .max(1e-6);
        Self {
            primary: Perlin::new(seed),
            // Use well-separated seed offsets to avoid cross-correlation
            warp_u: Perlin::new(seed.wrapping_add(1_000)),
            warp_v: Perlin::new(seed.wrapping_add(2_000)),
            warp_w: Perlin::new(seed.wrapping_add(3_000)),
            inv_max_amp: 1.0 / max_amp,
            params,
        }
    }

    /// Sample the noise at a 3D point.
    ///
    /// For **elevation noise** pass the normalized sphere direction (unit vector).
    /// For **density / cave noise** pass the world-space position scaled to
    /// whatever frequency is desired.
    ///
    /// Returns a value in approximately **[-1, 1]**.
    pub fn sample(&self, x: f64, y: f64, z: f64) -> f32 {
        let p = &self.params;

        // ── Step 1: Domain Warping ─────────────────────────────────────────
        let (sx, sy, sz) = if p.warp_strength > 1e-4 {
            let ws = p.warp_strength as f64;
            let wf = p.warp_scale;
            let du = self.warp_u.get([x * wf,           y * wf,           z * wf          ]) * ws;
            let dv = self.warp_v.get([x * wf + 3.729,   y * wf + 1.381,   z * wf + 7.193  ]) * ws;
            let dw = self.warp_w.get([x * wf + 9.271,   y * wf + 6.554,   z * wf + 4.812  ]) * ws;
            (x + du, y + dv * 0.25, z + dw) // dampen vertical warp for elevation use
        } else {
            (x, y, z)
        };

        // ── Step 2: Slope-Responsive FBM with Sharpness ───────────────────
        let mut value = 0.0f32;
        let mut amplitude = 1.0f32;
        let mut frequency = p.frequency;
        let mut slope_acc = 1e-4_f32; // small epsilon prevents divide-by-zero

        for _ in 0..p.octaves {
            let raw = self.primary.get([sx * frequency, sy * frequency, sz * frequency]) as f32;
            let shaped = shape_noise(raw, p.sharpness);

            let erosion = 1.0 / (1.0 + slope_acc * p.slope_erosion);
            value += shaped * amplitude * erosion;
            slope_acc += amplitude * shaped.abs();

            amplitude *= p.gain;
            frequency *= p.lacunarity;
        }

        // ── Step 3: Normalize ─────────────────────────────────────────────
        let normalized = value * self.inv_max_amp;

        // ── Step 4: Altitude Damping ──────────────────────────────────────
        if p.altitude_damping > 1e-4 {
            let extreme = normalized.abs();
            let dampen = 1.0 - p.altitude_damping * extreme * extreme;
            normalized * dampen.max(0.0)
        } else {
            normalized
        }
    }

    #[allow(dead_code)]
    pub fn params(&self) -> &UberNoiseParams {
        &self.params
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Blend between Billow, standard Perlin, and Ridge based on `sharpness`.
#[inline]
fn shape_noise(raw: f32, sharpness: f32) -> f32 {
    let billow = raw.abs();
    let ridge = 1.0 - raw.abs();
    if sharpness < 0.5 {
        let t = sharpness * 2.0;
        billow * (1.0 - t) + raw * t
    } else {
        let t = (sharpness - 0.5) * 2.0;
        raw * (1.0 - t) + ridge * t
    }
}
