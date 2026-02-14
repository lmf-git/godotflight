extends Node3D
class_name AircraftGun

## Nose-mounted aircraft gun that fires hitscan rounds with tracer visuals

const FIRE_RATE: float = 10.0         # rounds per second
const RANGE: float = 2000.0           # meters
const TRACER_SPEED: float = 900.0     # m/s visual tracer speed
const TRACER_LENGTH: float = 8.0      # meters
const SPREAD: float = 0.008           # radians of random spread

var _cooldown: float = 0.0
var _tracers: Array[Dictionary] = []   # {mesh: MeshInstance3D, start: Vector3, dir: Vector3, dist: float}

# Tracer mesh template
var _tracer_mat: StandardMaterial3D
var _tracer_mesh: CylinderMesh

func _ready() -> void:
	_tracer_mat = StandardMaterial3D.new()
	_tracer_mat.albedo_color = Color(1.0, 0.9, 0.3, 0.9)
	_tracer_mat.emission_enabled = true
	_tracer_mat.emission = Color(1.0, 0.8, 0.2)
	_tracer_mat.emission_energy_multiplier = 3.0
	_tracer_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_tracer_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_tracer_mat.billboard_mode = BaseMaterial3D.BILLBOARD_DISABLED

	_tracer_mesh = CylinderMesh.new()
	_tracer_mesh.top_radius = 0.03
	_tracer_mesh.bottom_radius = 0.03
	_tracer_mesh.height = TRACER_LENGTH
	_tracer_mesh.radial_segments = 4

func fire(muzzle_pos: Vector3, forward_dir: Vector3, velocity_offset: Vector3) -> void:
	if _cooldown > 0.0:
		return
	_cooldown = 1.0 / FIRE_RATE

	# Apply spread
	var spread_x := randf_range(-SPREAD, SPREAD)
	var spread_y := randf_range(-SPREAD, SPREAD)
	var right := forward_dir.cross(Vector3.UP).normalized()
	var up := right.cross(forward_dir).normalized()
	var dir := (forward_dir + right * spread_x + up * spread_y).normalized()

	# Hitscan: raycast for hit detection
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		muzzle_pos,
		muzzle_pos + dir * RANGE,
		5  # World + Vehicles
	)
	# Exclude parent vehicle
	var vehicle := _get_vehicle()
	if vehicle:
		query.exclude = [vehicle.get_rid()]
	var result := space_state.intersect_ray(query)

	var hit_dist := RANGE
	if result:
		hit_dist = muzzle_pos.distance_to(result.position)

	# Create tracer visual
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = _tracer_mesh
	mesh_inst.material_override = _tracer_mat
	mesh_inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mesh_inst)

	_tracers.append({
		"mesh": mesh_inst,
		"start": muzzle_pos,
		"dir": dir,
		"dist": 0.0,
		"max_dist": hit_dist,
		"vel_offset": velocity_offset,
	})

func _process(delta: float) -> void:
	_cooldown -= delta

	# Animate tracers
	var to_remove: Array[int] = []
	for i in _tracers.size():
		var t: Dictionary = _tracers[i]
		t["dist"] += TRACER_SPEED * delta
		var mesh: MeshInstance3D = t["mesh"]

		if t["dist"] > t["max_dist"] + TRACER_LENGTH:
			mesh.queue_free()
			to_remove.append(i)
			continue

		# Position tracer along its path, accounting for aircraft velocity drift
		var time_elapsed: float = t["dist"] / TRACER_SPEED
		var drift: Vector3 = t["vel_offset"] * time_elapsed
		var center_dist: float = t["dist"] - TRACER_LENGTH * 0.5
		var pos: Vector3 = t["start"] + t["dir"] * center_dist + drift
		mesh.global_position = pos

		# Orient tracer along direction
		var end: Vector3 = t["start"] + t["dir"] * t["dist"] + drift
		var start: Vector3 = t["start"] + t["dir"] * maxf(0.0, t["dist"] - TRACER_LENGTH) + drift
		var look_dir: Vector3 = (end - start).normalized()
		if look_dir.length_squared() > 0.01:
			mesh.look_at(pos + look_dir)
			mesh.rotate_object_local(Vector3.RIGHT, PI * 0.5)  # Cylinder is Y-up, rotate to face along Z

	# Remove finished tracers (iterate backwards)
	for i in range(to_remove.size() - 1, -1, -1):
		_tracers.remove_at(to_remove[i])

func _get_vehicle() -> Vehicle:
	var parent := get_parent()
	while parent:
		if parent is Vehicle:
			return parent
		parent = parent.get_parent()
	return null
