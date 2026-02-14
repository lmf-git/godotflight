extends RigidBody3D
class_name Missile

## Wing-mounted missile with drop-off, ignition, and self-destruct lifecycle

enum State { ATTACHED, DROPPING, FIRING, SPENT, EXPLODING }

var state: State = State.ATTACHED

# Missile parameters
const MOTOR_THRUST: float = 12000.0    # Newtons (~15g on 80kg missile)
const MOTOR_BURN_TIME: float = 4.0     # seconds
const LIFETIME_AFTER_SPENT: float = 8.0  # seconds before queue_free
const DROP_TIME: float = 0.5           # seconds of freefall before ignition
const EXPLODE_DURATION: float = 1.5    # seconds explosion stays visible
const ARM_DELAY: float = 0.3           # seconds after launch before collision detection active

const MAX_DISTANCE_SQ: float = 50000.0 * 50000.0
var _state_timer: float = 0.0
var _launch_timer: float = 0.0         # time since launch (for arm delay)
var _source_vehicle: RigidBody3D       # aircraft that fired us

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

func _explode() -> void:
	if state == State.EXPLODING:
		return
	state = State.EXPLODING
	_state_timer = 0.0
	freeze = true

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
