extends RigidBody3D
class_name AIAircraft

## AI aircraft with part-based damage and combat AI.
## Patrols by orbiting. When the player occupies an aircraft within COMBAT_RANGE,
## switches to pursuit/attack: fires missiles first, then lead-aimed guns.

@export var orbit_radius: float = 2000.0
@export var orbit_speed: float = 180.0   # m/s
@export var cruise_altitude: float = 600.0

var _angle: float = 0.0
var _center: Vector3
var _hit_flash_timer: float = 0.0

# Part state
var has_left_wing: bool = true
var has_right_wing: bool = true
var has_horizontal_tail: bool = true
var has_vertical_tail: bool = true

var _fuselage_mesh: MeshInstance3D
var _left_wing_mesh: MeshInstance3D
var _right_wing_mesh: MeshInstance3D
var _htail_mesh: MeshInstance3D
var _vtail_mesh: MeshInstance3D

const _BODY_COLOR := Color(0.45, 0.45, 0.55)

# === COMBAT ===
const MISSILE_SCENE := preload("res://scenes/vehicles/missile.tscn")
const COMBAT_RANGE     : float = 8000.0
const MISSILE_RANGE    : float = 3000.0
const GUN_RANGE        : float = 900.0
const MISSILE_COOLDOWN : float = 18.0   # seconds between missile shots
const GUN_FIRE_INTERVAL: float = 0.09   # seconds between gun rounds (~11 rps)
const MUZZLE_OFFSET    := Vector3(0.0, 0.0, -3.5)  # nose-forward

var _missiles_remaining: int = 2
var _missile_cooldown  : float = 5.0    # initial delay before first shot
var _gun_cooldown      : float = 0.0
var _target            : Node3D = null

# Countermeasures
var _countermeasures: int = 6
var _cm_cooldown: float = 0.0
const CM_DETECT_RANGE: float = 1500.0
const CM_COOLDOWN: float = 4.0


func _ready() -> void:
	collision_layer = 4
	collision_mask = 13   # World + Vehicles + Projectiles
	mass = 3000.0
	gravity_scale = 0.0
	angular_damp = 4.0
	add_to_group("ai_aircraft")
	_center = Vector3(global_position.x, cruise_altitude, global_position.z)
	_angle = randf() * TAU
	_build_mesh()


func _wing_factor() -> float:
	return (0.5 if has_left_wing else 0.0) + (0.5 if has_right_wing else 0.0)


func _process(delta: float) -> void:
	if _hit_flash_timer > 0.0:
		_hit_flash_timer -= delta
		var col := Color(1, 1, 1).lerp(_BODY_COLOR, 1.0 - _hit_flash_timer / 0.2)
		for child in get_children():
			if child is MeshInstance3D and child.material_override:
				child.material_override.albedo_color = col


func _physics_process(delta: float) -> void:
	var wing_fac := _wing_factor()
	gravity_scale = 1.0  # real gravity always — lift counteracts it

	if _missile_cooldown > 0.0: _missile_cooldown -= delta
	if _gun_cooldown > 0.0:     _gun_cooldown -= delta
	if _cm_cooldown > 0.0:      _cm_cooldown -= delta

	_check_incoming_missiles()
	_update_target()

	var desired_dir: Vector3
	if _target and is_instance_valid(_target):
		desired_dir = _combat_flight()
	else:
		desired_dir = _patrol_flight(delta)

	_apply_aero_flight(desired_dir, wing_fac)


# ── Flight modes — return a desired direction, no forces ──────────────────────

const SAFE_ALTITUDE : float = 150.0
const BREAK_OFF_DIST: float = 350.0

func _patrol_flight(delta: float) -> Vector3:
	_angle += (orbit_speed / orbit_radius) * delta
	var patrol_target := Vector3(
		_center.x + sin(_angle) * orbit_radius,
		cruise_altitude,
		_center.z + cos(_angle) * orbit_radius
	)
	var dir := (patrol_target - global_position).normalized()
	var alt_err := cruise_altitude - global_position.y
	return (dir + Vector3.UP * clampf(alt_err * 0.04, -0.5, 0.5)).normalized()


func _combat_flight() -> Vector3:
	var target_pos := _target.global_position
	var target_vel := Vector3.ZERO
	if _target is RigidBody3D:
		target_vel = (_target as RigidBody3D).linear_velocity
	var dist := global_position.distance_to(target_pos)
	var wing_fac := _wing_factor()

	var dir: Vector3
	if global_position.y < SAFE_ALTITUDE and wing_fac > 0.0:
		dir = (linear_velocity.normalized() + Vector3.UP * 2.0).normalized()
	elif dist < BREAK_OFF_DIST:
		var away    := (global_position - target_pos).normalized()
		var lateral := away.cross(Vector3.UP).normalized()
		dir = (away * 0.7 + lateral * 0.5 + Vector3.UP * 0.3).normalized()
	else:
		var lead_t   := dist / maxf(linear_velocity.length(), orbit_speed)
		var lead_pos := target_pos + target_vel * lead_t
		var to_lead  := lead_pos - global_position
		var alt_target := maxf(target_pos.y + 80.0, SAFE_ALTITUDE)
		to_lead.y += alt_target - global_position.y
		dir = to_lead.normalized()

	_try_attack(target_pos, target_vel, dist)
	return dir


# ── Aerodynamic flight model ──────────────────────────────────────────────────

const _AIR_RHO   := 1.225
const _WING_AREA := 20.0
const _THRUST    := 26000.0
const _CL_0      := 0.28
const _CL_ALPHA  := 2.5
const _CD_0      := 0.035
const _ASPECT    := 4.0
const _OSWALD    := 0.70

func _apply_aero_flight(desired_dir: Vector3, wing_fac: float) -> void:
	var speed := linear_velocity.length()
	var q     := 0.5 * _AIR_RHO * speed * speed
	var fwd   := -global_transform.basis.z
	var up    :=  global_transform.basis.y
	var right :=  global_transform.basis.x

	# ── Lift ──────────────────────────────────────────────────────────────────
	if speed > 5.0 and wing_fac > 0.0:
		var local_vel := global_transform.basis.inverse() * linear_velocity
		var aoa       := atan2(-local_vel.y, maxf(-local_vel.z, 1.0))
		var cl        := clampf(_CL_0 + _CL_ALPHA * aoa, -1.4, 1.4) * wing_fac
		var vel_dir   := linear_velocity.normalized()
		var lift_dir  := vel_dir.cross(right).normalized()
		if lift_dir.dot(up) < 0:
			lift_dir = -lift_dir
		apply_central_force(lift_dir * q * _WING_AREA * cl)

	# ── Drag ──────────────────────────────────────────────────────────────────
	if speed > 0.1:
		var cl_ref := _CL_0 * wing_fac
		var cd := _CD_0 + cl_ref * cl_ref / (PI * _OSWALD * _ASPECT)
		apply_central_force(-linear_velocity.normalized() * q * _WING_AREA * cd)

	# ── Thrust — maintain cruise speed ────────────────────────────────────────
	var throttle := clampf(0.7 + (orbit_speed - speed) * 0.008, 0.2, 1.0)
	apply_central_force(fwd * _THRUST * throttle)

	# ── Roll + Pitch PD controller ────────────────────────────────────────────
	if desired_dir.length_squared() > 0.01 and speed > 15.0:
		var desired := desired_dir.normalized()

		# ROLL: bank into the turn so lift vector points toward the inside of the arc
		var horiz_fwd := Vector3(fwd.x, 0.0, fwd.z)
		var bank_amount := 0.0
		if horiz_fwd.length_squared() > 0.01:
			var turn_cross := horiz_fwd.normalized().cross(Vector3(desired.x, 0.0, desired.z).normalized())
			bank_amount = clampf(turn_cross.y * 3.0, -1.0, 1.0)
		var desired_up  := (Vector3.UP - right * bank_amount).normalized()
		var roll_err    := up.cross(desired_up).dot(fwd)
		if has_left_wing and has_right_wing:
			apply_torque(fwd * roll_err * 12000.0 * wing_fac)

		# PITCH: align nose with desired direction
		var pitch_err  := fwd.cross(desired).dot(right)
		var htail_fac  := 1.0 if has_horizontal_tail else 0.15
		apply_torque(right * pitch_err * 20000.0 * htail_fac)

	# ── Angular damping — smooth out oscillations ─────────────────────────────
	apply_torque(-angular_velocity * 1.8 * mass)

	# ── Damage instability ────────────────────────────────────────────────────
	if not has_horizontal_tail:
		apply_torque(global_transform.basis.x * randf_range(-1.0, 1.0) * mass * 12.0)
	if not has_vertical_tail:
		apply_torque(Vector3.UP * randf_range(-1.0, 1.0) * mass * 6.0)
	if has_left_wing != has_right_wing:
		var roll_dir := 1.0 if not has_right_wing else -1.0
		apply_torque(-global_transform.basis.z * roll_dir * mass * 30.0)


# ── Combat ────────────────────────────────────────────────────────────────────

func _update_target() -> void:
	_target = null
	for node in get_tree().get_nodes_in_group("aircraft"):
		if "is_occupied" in node and node.is_occupied:
			if global_position.distance_to(node.global_position) <= COMBAT_RANGE:
				_target = node
				return


func _try_attack(target_pos: Vector3, target_vel: Vector3, dist: float) -> void:
	var nose   := -global_transform.basis.z
	var to_tgt := (target_pos - global_position).normalized()

	# Missiles first — wide cone (they home), within missile range
	if _missiles_remaining > 0 and dist <= MISSILE_RANGE and _missile_cooldown <= 0.0:
		if nose.dot(to_tgt) > 0.70:   # within ~46°
			_fire_missile()
			return

	# Guns when missiles are spent — tight cone with lead aim
	if dist <= GUN_RANGE and _gun_cooldown <= 0.0:
		var t        := dist / 900.0  # bullet travel time
		var lead_pos := target_pos + target_vel * t
		var to_lead  := (lead_pos - global_position).normalized()
		if nose.dot(to_lead) > 0.97:  # within ~14°
			_fire_gun_at(lead_pos)


func _fire_missile() -> void:
	_missiles_remaining -= 1
	_missile_cooldown = MISSILE_COOLDOWN
	var missile: Missile = MISSILE_SCENE.instantiate()
	get_tree().current_scene.add_child(missile)
	missile.global_position = global_position + global_transform.basis * MUZZLE_OFFSET
	missile.global_transform.basis = global_transform.basis
	missile.homing_target = _target
	missile.launch(linear_velocity, self)


func _fire_gun_at(lead_pos: Vector3) -> void:
	_gun_cooldown = GUN_FIRE_INTERVAL
	var muzzle   := global_position + global_transform.basis * MUZZLE_OFFSET
	var aim_dir  := (lead_pos - muzzle).normalized()

	# Small random spread
	var arbitrary := Vector3.FORWARD if absf(aim_dir.dot(Vector3.UP)) > 0.9 else Vector3.UP
	var right    := aim_dir.cross(arbitrary).normalized()
	var up_vec   := right.cross(aim_dir).normalized()
	const SPREAD := 0.006
	aim_dir = (aim_dir
		+ right  * randf_range(-SPREAD, SPREAD)
		+ up_vec * randf_range(-SPREAD, SPREAD)).normalized()

	# Hitscan
	var space := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(muzzle, muzzle + aim_dir * 1200.0, 5)
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	var hit_dist := 1200.0
	if result:
		hit_dist = muzzle.distance_to(result.position)
		var hit: Node = result.get("collider")
		while hit:
			if hit.has_method("take_hit"):
				hit.take_hit(result.position)
				break
			hit = hit.get_parent() if hit.get_parent() is Node3D else null

	_spawn_muzzle_flash(muzzle)
	_spawn_tracer(muzzle, muzzle + aim_dir * hit_dist)


func _spawn_muzzle_flash(pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.9, 0.4)
	light.light_energy = 6.0
	light.omni_range = 12.0
	get_tree().current_scene.add_child(light)
	light.global_position = pos
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.055)
	tw.tween_callback(light.queue_free)


func _spawn_tracer(from: Vector3, to: Vector3) -> void:
	var length      := from.distance_to(to)
	var dir         := (to - from).normalized() if length > 0.1 else -global_transform.basis.z
	var visible_len := minf(length, 50.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.95, 0.4, 0.85)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.85, 0.2)
	mat.emission_energy_multiplier = 4.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.025
	mesh.bottom_radius = 0.025
	mesh.height = visible_len
	mesh.radial_segments = 4

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	get_tree().current_scene.add_child(mi)
	mi.global_position = from + dir * (visible_len * 0.5)
	mi.look_at(from + dir)
	mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)

	var tw := mi.create_tween()
	tw.tween_method(func(a: float): mat.albedo_color.a = a, 0.85, 0.0, 0.12)
	tw.tween_callback(mi.queue_free)


# ── Damage ────────────────────────────────────────────────────────────────────

func take_hit(blast_pos: Vector3 = Vector3.ZERO) -> void:
	_hit_flash_timer = 0.2

	var intact: Array[String] = []
	if has_left_wing:       intact.append("left_wing")
	if has_right_wing:      intact.append("right_wing")
	if has_horizontal_tail: intact.append("horizontal_tail")
	if has_vertical_tail:   intact.append("vertical_tail")

	if intact.is_empty():
		_die()
		return

	var chosen: String
	if blast_pos != Vector3.ZERO:
		var part_positions := {
			"left_wing":       global_position + global_transform.basis.x * -2.0,
			"right_wing":      global_position + global_transform.basis.x * 2.0,
			"horizontal_tail": global_position - global_transform.basis.z * 2.5,
			"vertical_tail":   global_position - global_transform.basis.z * 2.5 + global_transform.basis.y * 0.4,
		}
		var best_dist := INF
		for part in intact:
			var d: float = (part_positions[part] as Vector3).distance_to(blast_pos)
			if d < best_dist:
				best_dist = d
				chosen = part
	else:
		chosen = intact.pick_random()

	match chosen:
		"left_wing":       _destroy_left_wing()
		"right_wing":      _destroy_right_wing()
		"horizontal_tail": _destroy_horizontal_tail()
		"vertical_tail":   _destroy_vertical_tail()

	if not has_left_wing and not has_right_wing \
			and not has_horizontal_tail and not has_vertical_tail:
		_die()


func _destroy_left_wing() -> void:
	if not has_left_wing: return
	has_left_wing = false
	if _left_wing_mesh:
		_spawn_hit_smoke(_left_wing_mesh.global_position)
		_spawn_debris(_left_wing_mesh.global_position, Vector3(3.0, 0.12, 1.8))
		_left_wing_mesh.queue_free()
		_left_wing_mesh = null
	print("%s: left wing gone" % name)


func _destroy_right_wing() -> void:
	if not has_right_wing: return
	has_right_wing = false
	if _right_wing_mesh:
		_spawn_hit_smoke(_right_wing_mesh.global_position)
		_spawn_debris(_right_wing_mesh.global_position, Vector3(3.0, 0.12, 1.8))
		_right_wing_mesh.queue_free()
		_right_wing_mesh = null
	print("%s: right wing gone" % name)


func _destroy_horizontal_tail() -> void:
	if not has_horizontal_tail: return
	has_horizontal_tail = false
	if _htail_mesh:
		_spawn_hit_smoke(_htail_mesh.global_position)
		_spawn_debris(_htail_mesh.global_position, Vector3(2.5, 0.1, 1.0))
		_htail_mesh.queue_free()
		_htail_mesh = null
	print("%s: horizontal tail gone" % name)


func _destroy_vertical_tail() -> void:
	if not has_vertical_tail: return
	has_vertical_tail = false
	if _vtail_mesh:
		_spawn_hit_smoke(_vtail_mesh.global_position)
		_spawn_debris(_vtail_mesh.global_position, Vector3(0.12, 0.8, 1.0))
		_vtail_mesh.queue_free()
		_vtail_mesh = null
	print("%s: vertical tail gone" % name)


func _spawn_hit_smoke(world_pos: Vector3) -> void:
	var root := Node3D.new()
	get_tree().current_scene.add_child(root)
	root.global_position = world_pos
	var fire_mat := StandardMaterial3D.new()
	fire_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fire_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fire_mat.emission_enabled = true
	fire_mat.emission = Color(1.0, 0.4, 0.05)
	fire_mat.emission_energy_multiplier = 6.0
	fire_mat.albedo_color = Color(1.0, 0.5, 0.1, 1.0)
	var fire_sphere := SphereMesh.new()
	fire_sphere.radius = 0.4
	fire_sphere.height = 0.8
	var fire_mesh := MeshInstance3D.new()
	fire_mesh.mesh = fire_sphere
	fire_mesh.material_override = fire_mat
	root.add_child(fire_mesh)
	for i in 4:
		var smoke_mat := StandardMaterial3D.new()
		smoke_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smoke_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smoke_mat.albedo_color = Color(0.1, 0.1, 0.1, 0.85)
		var sm := SphereMesh.new()
		sm.radius = 0.3
		sm.height = 0.6
		var smi := MeshInstance3D.new()
		smi.mesh = sm
		smi.material_override = smoke_mat
		smi.position = Vector3(randf_range(-0.8, 0.8), randf_range(0.2, 1.2), randf_range(-0.8, 0.8))
		root.add_child(smi)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3(6, 6, 6), 2.5)
	tw.parallel().tween_method(
		func(a: float) -> void:
			fire_mat.albedo_color.a = a * 0.5
			fire_mat.emission_energy_multiplier = a * 6.0
			for child in root.get_children():
				if child is MeshInstance3D and child != fire_mesh and child.material_override:
					child.material_override.albedo_color.a = a * 0.85,
		1.0, 0.0, 2.5)
	tw.tween_callback(root.queue_free)


func _spawn_debris(world_pos: Vector3, size: Vector3) -> void:
	var body := RigidBody3D.new()
	body.mass = 60.0
	body.collision_layer = 0
	body.collision_mask = 1
	get_tree().current_scene.add_child(body)
	body.global_position = world_pos
	body.linear_velocity = linear_velocity
	body.continuous_cd = true
	body.angular_damp = 1.5  # tumble slows naturally; linear left alone so gravity is unaffected
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _BODY_COLOR
	mi.material_override = mat
	body.add_child(mi)
	var col := CollisionShape3D.new()
	var sh := BoxShape3D.new()
	sh.size = size
	col.shape = sh
	body.add_child(col)
	# Despawn 30 s after hitting the ground; no artificial damp while airborne
	body.contact_monitor = true
	body.max_contacts_reported = 1
	body.body_entered.connect(func(hit_body: Node):
		if body.get_meta("settled", false) or not (hit_body is StaticBody3D):
			return
		body.set_meta("settled", true)
		var t := Timer.new()
		t.wait_time = 30.0
		t.one_shot = true
		t.timeout.connect(func(): if is_instance_valid(body): body.queue_free())
		body.add_child(t)
		t.start()
	)
	var fallback := Timer.new()
	fallback.wait_time = 60.0
	fallback.one_shot = true
	fallback.timeout.connect(func(): if is_instance_valid(body): body.queue_free())
	body.add_child(fallback)
	fallback.start()


func _die() -> void:
	remove_from_group("ai_aircraft")

	if _fuselage_mesh:
		_spawn_debris(_fuselage_mesh.global_position, Vector3(0.6, 0.4, 6.0))
	if has_left_wing and _left_wing_mesh:
		_spawn_debris(_left_wing_mesh.global_position, Vector3(3.0, 0.12, 1.8))
	if has_right_wing and _right_wing_mesh:
		_spawn_debris(_right_wing_mesh.global_position, Vector3(3.0, 0.12, 1.8))
	if has_horizontal_tail and _htail_mesh:
		_spawn_debris(_htail_mesh.global_position, Vector3(2.5, 0.1, 1.0))
	if has_vertical_tail and _vtail_mesh:
		_spawn_debris(_vtail_mesh.global_position, Vector3(0.12, 0.8, 1.0))

	var exp_root := Node3D.new()
	get_tree().current_scene.add_child(exp_root)
	exp_root.global_position = global_position
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.55, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 7.0
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	var exp_mesh := MeshInstance3D.new()
	exp_mesh.mesh = sphere
	exp_mesh.material_override = mat
	exp_root.add_child(exp_mesh)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.5, 0.2)
	light.light_energy = 15.0
	light.omni_range = 40.0
	exp_root.add_child(light)
	var tw := exp_root.create_tween()
	tw.tween_property(exp_root, "scale", Vector3(12, 12, 12), 0.8)
	tw.parallel().tween_method(
		func(a: float): mat.albedo_color.a = a; mat.emission_energy_multiplier = a * 7.0,
		1.0, 0.0, 0.8)
	tw.tween_callback(func(): exp_root.queue_free())
	print("%s destroyed!" % name)
	queue_free()


# ── Countermeasures ───────────────────────────────────────────────────────────

func _check_incoming_missiles() -> void:
	if _cm_cooldown > 0.0 or _countermeasures <= 0:
		return
	for missile in get_tree().get_nodes_in_group("missiles"):
		if not is_instance_valid(missile):
			continue
		if not (missile is Missile) or missile.state != Missile.State.FIRING:
			continue
		if missile.homing_target != self:
			continue
		if global_position.distance_to(missile.global_position) > CM_DETECT_RANGE:
			continue
		_countermeasures -= 1
		_cm_cooldown = CM_COOLDOWN
		_spawn_cm_flare()
		_spawn_cm_flare()
		return


func _spawn_cm_flare() -> void:
	var flare := RigidBody3D.new()
	flare.mass = 0.2
	flare.gravity_scale = 1.0
	flare.collision_layer = 0
	flare.collision_mask = 1  # World layer so flares land on terrain
	flare.continuous_cd = true  # prevent tunnelling through trimesh terrain at speed
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.2, 0.2, 0.2)
	col.shape = box
	flare.add_child(col)
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.15
	sm.height = 0.3
	mi.mesh = sm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.3)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.2)
	mat.emission_energy_multiplier = 8.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	flare.add_child(mi)
	flare.add_to_group("flares")
	get_tree().current_scene.add_child(flare)
	var side := global_transform.basis.x * (1.0 if randf() > 0.5 else -1.0)
	var backward := global_transform.basis.z  # +Z is rearward in Godot
	flare.global_position = global_position + side * 2.0 + backward * 2.0
	flare.linear_velocity = linear_velocity + side * 40.0 + backward * 30.0 + Vector3.DOWN * 15.0
	var tw := flare.create_tween()
	tw.tween_interval(2.5)
	tw.tween_method(func(e: float): mat.emission_energy_multiplier = e, 8.0, 0.0, 1.5)
	tw.tween_callback(flare.queue_free)


# ── Mesh ──────────────────────────────────────────────────────────────────────

func _build_mesh() -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = _BODY_COLOR

	_fuselage_mesh = MeshInstance3D.new()
	var fm := BoxMesh.new()
	fm.size = Vector3(0.6, 0.4, 6.0)
	_fuselage_mesh.mesh = fm
	_fuselage_mesh.material_override = mat.duplicate()
	add_child(_fuselage_mesh)

	_left_wing_mesh = MeshInstance3D.new()
	var lwm := BoxMesh.new()
	lwm.size = Vector3(3.0, 0.12, 1.8)
	_left_wing_mesh.mesh = lwm
	_left_wing_mesh.material_override = mat.duplicate()
	_left_wing_mesh.position = Vector3(-2.0, -0.1, 0.5)
	add_child(_left_wing_mesh)

	_right_wing_mesh = MeshInstance3D.new()
	var rwm := BoxMesh.new()
	rwm.size = Vector3(3.0, 0.12, 1.8)
	_right_wing_mesh.mesh = rwm
	_right_wing_mesh.material_override = mat.duplicate()
	_right_wing_mesh.position = Vector3(2.0, -0.1, 0.5)
	add_child(_right_wing_mesh)

	_htail_mesh = MeshInstance3D.new()
	var htm := BoxMesh.new()
	htm.size = Vector3(2.5, 0.1, 1.0)
	_htail_mesh.mesh = htm
	_htail_mesh.material_override = mat.duplicate()
	_htail_mesh.position = Vector3(0, 0, 2.5)
	add_child(_htail_mesh)

	_vtail_mesh = MeshInstance3D.new()
	var vtm := BoxMesh.new()
	vtm.size = Vector3(0.12, 0.8, 1.0)
	_vtail_mesh.mesh = vtm
	_vtail_mesh.material_override = mat.duplicate()
	_vtail_mesh.position = Vector3(0, 0.4, 2.5)
	add_child(_vtail_mesh)

	var ex_mat := StandardMaterial3D.new()
	ex_mat.albedo_color = Color(1.0, 0.5, 0.1)
	ex_mat.emission_enabled = true
	ex_mat.emission = Color(1.0, 0.4, 0.05)
	ex_mat.emission_energy_multiplier = 3.0
	ex_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var exhaust := MeshInstance3D.new()
	var exhaust_mesh := CylinderMesh.new()
	exhaust_mesh.top_radius = 0.18
	exhaust_mesh.bottom_radius = 0.18
	exhaust_mesh.height = 0.3
	exhaust.mesh = exhaust_mesh
	exhaust.material_override = ex_mat
	exhaust.rotation_degrees = Vector3(90, 0, 0)
	exhaust.position = Vector3(0, 0, 3.2)
	add_child(exhaust)

	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(7.0, 0.8, 6.0)
	col.shape = shape
	add_child(col)
