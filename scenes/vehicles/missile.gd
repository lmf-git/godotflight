extends RigidBody3D
class_name Missile

## Wing-mounted missile with drop-off, ignition, and self-destruct lifecycle

enum State { ATTACHED, DROPPING, FIRING, SPENT, EXPLODING }

var state: State = State.ATTACHED

# Missile parameters
const MOTOR_THRUST: float = 20000.0    # Newtons (~25g on 80kg missile)
const MOTOR_BURN_TIME: float = 7.0     # seconds
const LIFETIME_AFTER_SPENT: float = 8.0  # seconds before queue_free
const DROP_TIME: float = 0.6           # seconds of freefall before ignition
const EXPLODE_DURATION: float = 1.5    # seconds explosion stays visible
const ARM_DELAY: float = 0.3           # seconds after launch before collision detection active

const MAX_DISTANCE_SQ: float = 50000.0 * 50000.0
var _state_timer: float = 0.0
var _launch_timer: float = 0.0         # time since launch (for arm delay)
var _source_vehicle: RigidBody3D       # aircraft that fired us
var homing_target: Node3D = null       # optional IR homing target
var _cm_check_timer: float = 0.0       # countermeasure seeker check interval

@onready var exhaust_particles: GPUParticles3D = $ExhaustParticles
@onready var smoke_trail: GPUParticles3D = $SmokeTrail
@onready var exhaust_flame: MeshInstance3D = $ExhaustFlame
@onready var missile_body: MeshInstance3D = $MissileBody
@onready var nosecone: MeshInstance3D = $Nosecone
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

# Explosion visuals (created on demand)
var _explosion_mesh: MeshInstance3D
var _explosion_light: OmniLight3D

func _ready() -> void:
	add_to_group("missiles")
	collision_layer = 8   # Projectiles
	collision_mask = 5    # World + Vehicles
	if state == State.ATTACHED:
		freeze = true
	if exhaust_particles:
		exhaust_particles.emitting = false
	if smoke_trail:
		smoke_trail.emitting = false
	if exhaust_flame:
		exhaust_flame.visible = false
	contact_monitor = true
	max_contacts_reported = 1
	if not body_entered.is_connected(_on_body_entered):
		body_entered.connect(_on_body_entered)

func launch(initial_velocity: Vector3, source_vehicle: RigidBody3D = null) -> void:
	freeze = false
	gravity_scale = 1.0
	linear_velocity = initial_velocity
	state = State.DROPPING
	_state_timer = 0.0
	_launch_timer = 0.0
	if source_vehicle:
		_source_vehicle = source_vehicle
		add_collision_exception_with(source_vehicle)

func _physics_process(delta: float) -> void:
	if state == State.ATTACHED or state == State.EXPLODING:
		return

	_launch_timer += delta

	# Safety: destroy if too far from origin
	if global_position.length_squared() > MAX_DISTANCE_SQ:
		queue_free()
		return

	# Raycast ahead to catch ground hits at high speed (only after arm delay)
	if _launch_timer > ARM_DELAY:
		_check_raycast_collision(delta)

	_state_timer += delta

	match state:
		State.DROPPING:
			_orient_to_velocity(delta)
			if _state_timer >= DROP_TIME:
				_ignite()
		State.FIRING:
			var thrust_dir := -global_transform.basis.z
			apply_central_force(thrust_dir * MOTOR_THRUST)
			if homing_target and is_instance_valid(homing_target):
				# Periodically check if countermeasures fool the seeker
				_cm_check_timer -= delta
				if _cm_check_timer <= 0.0:
					_cm_check_timer = 0.1
					_check_countermeasures()
				_guide_to_target()
				# Proximity detonation — explode when close enough or past closest approach
				var to_tgt := homing_target.global_position - global_position
				var dist := to_tgt.length()
				var closing := linear_velocity.dot(to_tgt.normalized())
				if dist < 15.0 or (dist < 55.0 and closing < 0.0):
					_explode()
					return
			else:
				_orient_to_velocity(delta)
			if _state_timer >= MOTOR_BURN_TIME:
				_burn_out()
		State.SPENT:
			_orient_to_velocity(delta)
			if _state_timer >= LIFETIME_AFTER_SPENT:
				queue_free()

func _process(delta: float) -> void:
	if state == State.EXPLODING:
		_state_timer += delta
		var t: float = _state_timer / EXPLODE_DURATION
		# Expand and fade the explosion
		if _explosion_mesh:
			var radius: float = 1.0 + t * 4.0
			_explosion_mesh.scale = Vector3.ONE * radius
			var mat: StandardMaterial3D = _explosion_mesh.material_override
			if mat:
				mat.albedo_color.a = clamp(1.0 - t, 0.0, 1.0)
		if _explosion_light:
			_explosion_light.light_energy = maxf(0.0, 8.0 * (1.0 - t * 2.0))
		if _state_timer >= EXPLODE_DURATION:
			queue_free()

func _ignite() -> void:
	state = State.FIRING
	_state_timer = 0.0
	if exhaust_particles:
		exhaust_particles.emitting = true
	if smoke_trail:
		smoke_trail.emitting = true
	if exhaust_flame:
		exhaust_flame.visible = true

func _burn_out() -> void:
	state = State.SPENT
	_state_timer = 0.0
	if exhaust_particles:
		exhaust_particles.emitting = false
	if exhaust_flame:
		exhaust_flame.visible = false
	if smoke_trail:
		smoke_trail.emitting = false

const BLAST_RADIUS := 65.0

func _explode() -> void:
	if state == State.EXPLODING:
		return
	state = State.EXPLODING
	_state_timer = 0.0
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	freeze = true

	# Damage nearby AI aircraft
	var player_fired: bool = _source_vehicle != null and "is_occupied" in _source_vehicle \
			and _source_vehicle.is_occupied
	var hit_enemy := false
	for node in get_tree().get_nodes_in_group("ai_aircraft"):
		if is_instance_valid(node) and global_position.distance_to(node.global_position) <= BLAST_RADIUS:
			if node.has_method("take_hit"):
				node.take_hit(global_position)
				hit_enemy = true
	if player_fired and hit_enemy:
		for hud in get_tree().get_nodes_in_group("weapon_hud"):
			hud.register_hit()

	# Damage player aircraft parts in blast radius
	for node in get_tree().get_nodes_in_group("aircraft"):
		if is_instance_valid(node) and node != _source_vehicle:
			if global_position.distance_to(node.global_position) <= BLAST_RADIUS:
				if node.has_method("take_missile_damage"):
					node.take_missile_damage(global_position)

	# Hide missile body
	if missile_body:
		missile_body.visible = false
	if nosecone:
		nosecone.visible = false
	if exhaust_flame:
		exhaust_flame.visible = false
	if exhaust_particles:
		exhaust_particles.emitting = false
	if smoke_trail:
		smoke_trail.emitting = false
	if collision_shape:
		collision_shape.set_deferred("disabled", true)

	# Create explosion fireball
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.6, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 5.0

	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 12
	sphere.rings = 6

	_explosion_mesh = MeshInstance3D.new()
	_explosion_mesh.mesh = sphere
	_explosion_mesh.material_override = mat
	_explosion_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_explosion_mesh)

	# Flash light
	_explosion_light = OmniLight3D.new()
	_explosion_light.light_color = Color(1.0, 0.6, 0.2)
	_explosion_light.light_energy = 8.0
	_explosion_light.omni_range = 20.0
	_explosion_light.omni_attenuation = 2.0
	add_child(_explosion_light)

func _check_countermeasures() -> void:
	if not homing_target or not is_instance_valid(homing_target):
		return
	for flare in get_tree().get_nodes_in_group("flares"):
		if not is_instance_valid(flare):
			continue
		var dist := global_position.distance_to(flare.global_position)
		if dist < 300.0:
			# Probability scales with proximity: ~0.95 at ≤30 m, ~0.3 at 300 m
			var prob := lerpf(0.3, 0.95, 1.0 - clampf((dist - 30.0) / 270.0, 0.0, 1.0))
			if randf() < prob:
				homing_target = flare
				return


func _guide_to_target() -> void:
	if not homing_target or not is_instance_valid(homing_target):
		return
	var to_raw := homing_target.global_position - global_position
	var raw_dist := to_raw.length()
	if raw_dist < 0.1:
		return

	# Two-step lead prediction: first estimate intercept time, then refine
	# because the lead point is further away than the current target position
	var missile_speed := maxf(linear_velocity.length(), 50.0)
	var tgt_vel := Vector3.ZERO
	if homing_target is RigidBody3D:
		tgt_vel = (homing_target as RigidBody3D).linear_velocity
	var t1 := raw_dist / missile_speed
	var lead1 := homing_target.global_position + tgt_vel * t1
	var t2 := (lead1 - global_position).length() / missile_speed
	var target_pos := homing_target.global_position + tgt_vel * t2

	var to_lead := target_pos - global_position
	if to_lead.length_squared() < 0.01:
		return
	var to_target := to_lead.normalized()

	# Rotate body to follow velocity direction (keeps thrust aligned with travel)
	var speed := linear_velocity.length()
	var current_fwd := -global_transform.basis.z
	if speed > 10.0:
		var vel_dir := linear_velocity / speed
		var vel_angle := current_fwd.angle_to(vel_dir)
		if vel_angle > 0.01:
			var vel_axis := current_fwd.cross(vel_dir)
			if vel_axis.length_squared() > 0.001:
				apply_torque(vel_axis.normalized() * vel_angle * 1500.0)
				if angular_velocity.length_squared() > 0.01:
					apply_torque(-angular_velocity * 10.0)

	# Proportional navigation: lateral force proportional to angle error
	# High-G turns reduce seeker tracking effectiveness
	if speed > 1.0:
		var vel_norm := linear_velocity / speed
		var lateral := to_target - vel_norm * to_target.dot(vel_norm)
		var target_turn_rate := 0.0
		if homing_target is RigidBody3D:
			target_turn_rate = (homing_target as RigidBody3D).angular_velocity.length()
		var g_factor := clampf(1.0 - target_turn_rate / 2.5, 0.2, 1.0)
		apply_central_force(lateral * MOTOR_THRUST * 5.0 * g_factor)

func _orient_to_velocity(_delta: float) -> void:
	if linear_velocity.length_squared() < 1.0:
		return
	var target_dir := linear_velocity.normalized()
	var current_forward := -global_transform.basis.z
	var angle := current_forward.angle_to(target_dir)
	if angle < 0.001:
		return
	var axis := current_forward.cross(target_dir)
	if axis.length_squared() < 0.0001:
		return
	axis = axis.normalized()
	var correction_strength := 50.0
	apply_torque(axis * angle * correction_strength)
	apply_torque(-angular_velocity * 5.0)

func _check_raycast_collision(delta: float) -> void:
	var speed := linear_velocity.length()
	if speed < 1.0:
		return
	var ray_length := speed * delta * 2.0
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position,
		global_position + linear_velocity.normalized() * ray_length,
		5
	)
	var exclude_list: Array[RID] = [get_rid()]
	if _source_vehicle and is_instance_valid(_source_vehicle):
		exclude_list.append(_source_vehicle.get_rid())
	query.exclude = exclude_list
	var result := space_state.intersect_ray(query)
	if result:
		# Direct hit — also call take_hit on the collider for instant damage
		var hit: Node = result.get("collider")
		while hit:
			if hit.has_method("take_hit"):
				hit.take_hit(global_position)
				break
			hit = hit.get_parent() if hit.get_parent() is Node3D else null
		_explode()

func _on_body_entered(body: Node) -> void:
	if state == State.ATTACHED or state == State.EXPLODING:
		return
	# Ignore source vehicle collision
	if body == _source_vehicle:
		return
	# Don't detonate before arm delay
	if _launch_timer < ARM_DELAY:
		return
	_explode()
