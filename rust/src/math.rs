use crate::chunk::CubeFace;

/// Convert cube face coordinates (cu, cv) at a given sphere radius to a normalized sphere direction.
/// cu and cv are offsets in meters along the tangent axes from the face center.
/// Returns normalized direction vector [x, y, z].
pub fn cube_face_to_dir(face: CubeFace, cu: f32, cv: f32, planet_radius: f32) -> [f32; 3] {
    let (normal, tan_u, tan_v) = face.tangent_frame();
    let r = planet_radius;

    let cpx = normal[0] * r + tan_u[0] * cu + tan_v[0] * cv;
    let cpy = normal[1] * r + tan_u[1] * cu + tan_v[1] * cv;
    let cpz = normal[2] * r + tan_u[2] * cu + tan_v[2] * cv;

    let len = (cpx * cpx + cpy * cpy + cpz * cpz).sqrt();
    if len < 1e-9 {
        return [0.0, 1.0, 0.0];
    }
    [cpx / len, cpy / len, cpz / len]
}

/// Convert a world-space position to cube face coordinates.
/// Returns (face, cu, cv, height) where height is distance from planet center.
#[allow(dead_code)]
pub fn world_to_cube(wx: f32, wy: f32, wz: f32, radius: f32) -> (CubeFace, f32, f32, f32) {
    let height = (wx * wx + wy * wy + wz * wz).sqrt();
    if height < 1e-9 {
        return (CubeFace::PosY, 0.0, 0.0, 0.0);
    }

    let dx = wx / height;
    let dy = wy / height;
    let dz = wz / height;

    let face = CubeFace::from_dir(dx, dy, dz);
    let (normal, tan_u, tan_v) = face.tangent_frame();

    // Dominant axis component of normalized direction
    let dominant = dx * normal[0] + dy * normal[1] + dz * normal[2];

    // Project onto tangent axes, scale to cube coordinates (radius units)
    let u_comp = dx * tan_u[0] + dy * tan_u[1] + dz * tan_u[2];
    let v_comp = dx * tan_v[0] + dy * tan_v[1] + dz * tan_v[2];

    let cu = if dominant.abs() > 1e-9 {
        (u_comp / dominant) * radius
    } else {
        u_comp * radius
    };
    let cv = if dominant.abs() > 1e-9 {
        (v_comp / dominant) * radius
    } else {
        v_comp * radius
    };

    (face, cu, cv, height)
}
