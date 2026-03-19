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
		var hit_body: Node = result.get("collider")
		# Walk up the tree to find a node with take_hit (handles sub-shape colliders)
		while hit_body:
			if hit_body.has_method("take_hit"):
				hit_body.take_hit(result.position)
				# Notify HUD only when the player's gun scores the hit
				var v := _get_vehicle()
				if v and v.get("is_occupied") and v.is_occupied:
					for hud in get_tree().get_nodes_in_group("weapon_hud"):
						hud.register_hit()
				break
			hit_body = hit_body.get_parent() if hit_body.get_parent() is Node3D else null
		_spawn_bullet_hole(result.position, result.normal)

	# Muzzle flash
	_spawn_muzzle_flash(muzzle_pos + dir * 1.0)

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

func _spawn_muzzle_flash(pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.9, 0.4)
	light.light_energy = 8.0
	light.omni_range = 14.0
	get_tree().current_scene.add_child(light)
	light.global_position = pos
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.055)
	tw.tween_callback(light.queue_free)

func _spawn_bullet_hole(pos: Vector3, normal: Vector3) -> void:
	if normal.length_squared() < 0.01:
		return
	var n := normal.normalized()
	var arbitrary := Vector3.FORWARD if absf(n.dot(Vector3.UP)) > 0.9 else Vector3.UP
	var right := n.cross(arbitrary).normalized()
	var fwd := right.cross(n).normalized()

	var root := Node3D.new()
	get_tree().current_scene.add_child(root)
	root.global_position = pos + n * 0.02
	root.global_transform.basis = Basis(right, n, -fwd)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.04, 0.03, 0.9)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.3, 0.3)
	mi.mesh = quad
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(mi)

	var tw := root.create_tween()
	tw.tween_interval(20.0)
	tw.tween_method(func(a: float): mat.albedo_color.a = a, 0.9, 0.0, 3.0)
	tw.tween_callback(root.queue_free)

func _get_vehicle() -> Vehicle:
	var parent := get_parent()
	while parent:
		if parent is Vehicle:
			return parent
		parent = parent.get_parent()
	return null
