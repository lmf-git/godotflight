extends Node3D

## Procedural terrain with a flat zone around the runway.
## Generates chunked terrain that follows the camera and works with floating origin.
## Mesh generation runs on WorkerThreadPool to avoid main-thread hitches.

# Terrain config
@export var chunk_size := 500.0        # meters per chunk edge
@export var grid_resolution := 25      # vertices per chunk edge (25 = 20m spacing at 500m chunks)
@export var view_range := 6            # chunks visible in each direction from center
@export var max_height := 120.0        # peak terrain height in meters
@export var terrain_seed := 42

# Runway flat zone (world-space, matching runway at X:-15..15, Z:-750..750)
@export var flat_rect := Rect2(-80, -900, 160, 1800)  # x, z, w, h
@export var blend_margin := 150.0      # meters to blend from flat to full height

var _noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _chunks := {}  # Vector2i -> MeshInstance3D
var _pending_builds := {}  # Vector2i -> true (queued on worker pool)
var _world_offset := Vector3.ZERO  # accumulated floating-origin shift
var _material: StandardMaterial3D
var _last_center := Vector2i(999999, 999999)


func _ready() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = terrain_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.0008
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = terrain_seed + 7
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 0.004
	_detail_noise.fractal_octaves = 2

	_material = StandardMaterial3D.new()
	_material.albedo_color = Color(0.3, 0.45, 0.2, 1.0)
	_material.roughness = 0.9
	_material.vertex_color_use_as_albedo = true
	_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	_update_chunks()


func _process(_delta: float) -> void:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return

	var cam_pos := cam.global_position
	var center := Vector2i(
		floori((cam_pos.x + _world_offset.x) / chunk_size),
		floori((cam_pos.z + _world_offset.z) / chunk_size)
	)

	if center != _last_center:
		_last_center = center
		_update_chunks()


func notify_origin_shift(offset: Vector3) -> void:
	_world_offset += offset


func _update_chunks() -> void:
	var needed := {}
	for cx in range(_last_center.x - view_range, _last_center.x + view_range + 1):
		for cz in range(_last_center.y - view_range, _last_center.y + view_range + 1):
			needed[Vector2i(cx, cz)] = true

	# Remove chunks that are no longer needed
	var to_remove := []
	for key in _chunks:
		if not needed.has(key):
			to_remove.append(key)
	for key in to_remove:
		_chunks[key].queue_free()
		_chunks.erase(key)

	# Queue missing chunks for background generation
	for key in needed:
		if not _chunks.has(key) and not _pending_builds.has(key):
			_pending_builds[key] = true
			WorkerThreadPool.add_task(_build_chunk_threaded.bind(key))


# --- Worker thread: heavy mesh computation ---

func _build_chunk_threaded(coord: Vector2i) -> void:
	var world_x := coord.x * chunk_size
	var world_z := coord.y * chunk_size
	var step := chunk_size / float(grid_resolution - 1)

	# Generate height grid
	var heights := PackedFloat32Array()
	heights.resize(grid_resolution * grid_resolution)

	for gz in range(grid_resolution):
		for gx in range(grid_resolution):
			var wx := world_x + gx * step
			var wz := world_z + gz * step
			heights[gz * grid_resolution + gx] = _sample_height(wx, wz)

	# Compute normals from finite differences
	var normals_grid: Array[Vector3] = []
	normals_grid.resize(grid_resolution * grid_resolution)

	for gz in range(grid_resolution):
		for gx in range(grid_resolution):
			var idx := gz * grid_resolution + gx
			var h := heights[idx]
			var hL := heights[idx - 1] if gx > 0 else h
			var hR := heights[idx + 1] if gx < grid_resolution - 1 else h
			var hD := heights[(gz - 1) * grid_resolution + gx] if gz > 0 else h
			var hU := heights[(gz + 1) * grid_resolution + gx] if gz < grid_resolution - 1 else h
			normals_grid[idx] = Vector3(hL - hR, 2.0 * step, hD - hU).normalized()

	# Build triangle arrays
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var tri_count := (grid_resolution - 1) * (grid_resolution - 1) * 6
	verts.resize(tri_count)
	norms.resize(tri_count)
	cols.resize(tri_count)
	var vi := 0

	for gz in range(grid_resolution - 1):
		for gx in range(grid_resolution - 1):
			var i00 := gz * grid_resolution + gx
			var i10 := i00 + 1
			var i01 := (gz + 1) * grid_resolution + gx
			var i11 := i01 + 1

			var x0 := gx * step
			var x1 := (gx + 1) * step
			var z0 := gz * step
			var z1 := (gz + 1) * step

			var wx0 := world_x + gx * step
			var wz0 := world_z + gz * step

			var c00 := _height_color(heights[i00], wx0, wz0)
			var c10 := _height_color(heights[i10], wx0 + step, wz0)
			var c01 := _height_color(heights[i01], wx0, wz0 + step)
			var c11 := _height_color(heights[i11], wx0 + step, wz0 + step)

			# Triangle 1
			verts[vi] = Vector3(x0, heights[i00], z0)
			norms[vi] = normals_grid[i00]
			cols[vi] = c00
			vi += 1
			verts[vi] = Vector3(x1, heights[i10], z0)
			norms[vi] = normals_grid[i10]
			cols[vi] = c10
			vi += 1
			verts[vi] = Vector3(x0, heights[i01], z1)
			norms[vi] = normals_grid[i01]
			cols[vi] = c01
			vi += 1

			# Triangle 2
			verts[vi] = Vector3(x1, heights[i10], z0)
			norms[vi] = normals_grid[i10]
			cols[vi] = c10
			vi += 1
			verts[vi] = Vector3(x1, heights[i11], z1)
			norms[vi] = normals_grid[i11]
			cols[vi] = c11
			vi += 1
			verts[vi] = Vector3(x0, heights[i01], z1)
			norms[vi] = normals_grid[i01]
			cols[vi] = c01
			vi += 1

	_integrate_chunk.call_deferred(coord, verts, norms, cols)


# --- Main thread: scene tree integration ---

func _integrate_chunk(coord: Vector2i, verts: PackedVector3Array, norms: PackedVector3Array, cols: PackedColorArray) -> void:
	_pending_builds.erase(coord)

	# Discard if chunk is no longer in view range or was already built
	if _chunks.has(coord):
		return
	if abs(coord.x - _last_center.x) > view_range or abs(coord.y - _last_center.y) > view_range:
		return

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(verts.size()):
		st.set_color(cols[i])
		st.set_normal(norms[i])
		st.add_vertex(verts[i])
	var mesh := st.commit()

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	mesh_inst.material_override = _material
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# Position in world coords; the terrain node's own position handles origin shift
	var world_x := coord.x * chunk_size
	var world_z := coord.y * chunk_size
	mesh_inst.position = Vector3(world_x, 0.02, world_z)

	# Collision
	var body := StaticBody3D.new()
	body.collision_layer = 1  # world layer
	body.collision_mask = 0
	var col_shape := CollisionShape3D.new()
	col_shape.shape = mesh.create_trimesh_shape()
	body.add_child(col_shape)
	mesh_inst.add_child(body)

	add_child(mesh_inst)
	_chunks[coord] = mesh_inst


func _sample_height(world_x: float, world_z: float) -> float:
	var h := _noise.get_noise_2d(world_x, world_z) * max_height
	h += _detail_noise.get_noise_2d(world_x, world_z) * max_height * 0.15
	var blend := _runway_blend(world_x, world_z)
	return h * blend


func _runway_blend(world_x: float, world_z: float) -> float:
	var dx := 0.0
	if world_x < flat_rect.position.x:
		dx = flat_rect.position.x - world_x
	elif world_x > flat_rect.end.x:
		dx = world_x - flat_rect.end.x

	var dz := 0.0
	if world_z < flat_rect.position.y:
		dz = flat_rect.position.y - world_z
	elif world_z > flat_rect.end.y:
		dz = world_z - flat_rect.end.y

	var dist := sqrt(dx * dx + dz * dz)
	if dist <= 0.0:
		return 0.0
	if dist >= blend_margin:
		return 1.0
	var t := dist / blend_margin
	return t * t * (3.0 - 2.0 * t)


func _height_color(h: float, world_x: float, world_z: float) -> Color:
	var blend := _runway_blend(world_x, world_z)
	var base_green := Color(0.3, 0.48, 0.2)
	var dark_green := Color(0.2, 0.35, 0.12)
	var brown := Color(0.4, 0.32, 0.18)
	var rock := Color(0.45, 0.42, 0.38)

	if blend < 0.1:
		return Color(0.35, 0.52, 0.25)

	var norm_h := clampf(h / max_height, -1.0, 1.0)
	if norm_h < 0.0:
		return dark_green.lerp(base_green, norm_h + 1.0)
	elif norm_h < 0.5:
		return base_green.lerp(brown, norm_h * 2.0)
	else:
		return brown.lerp(rock, (norm_h - 0.5) * 2.0)
