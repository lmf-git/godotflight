extends Vehicle
class_name Car

## Simple car with arcade-style physics and raycast suspension

@export_group("Engine")
@export var engine_power: float = 20000.0
@export var brake_power: float = 25000.0
@export var max_speed: float = 35.0  # m/s (~125 km/h)

@export_group("Steering")
@export var steering_speed: float = 4.0
@export var max_steer_angle: float = 35.0  # degrees
@export var steering_return_speed: float = 6.0
@export var wheelbase: float = 2.6  # distance between front and rear axles

@export_group("Wheels")
@export var wheel_grip: float = 30.0  # lateral grip multiplier
@export var slip_threshold: float = 4.0  # lateral velocity where grip starts to reduce

@export_group("Suspension")
@export var spring_stiffness: float = 35000.0   # N/m
@export var damping_coefficient: float = 4500.0  # N/(m/s)
@export var suspension_travel: float = 0.25      # meters of travel
@export var wheel_radius: float = 0.3            # meters

# State
var throttle_input: float = 0.0
var brake_input: float = 0.0
var steer_input: float = 0.0
var current_steer: float = 0.0

# Suspension state
var _prev_compression := [0.0, 0.0, 0.0, 0.0]  # FL, FR, RL, RR

# Damage state
var has_wheel_fl := true
var has_wheel_fr := true
var has_wheel_rl := true
var has_wheel_rr := true
var damage_sequence := ["wheel_fl", "wheel_fr", "wheel_rl", "wheel_rr"]
var damage_index := 0

# Impact damage
@export_group("Damage")
@export var impact_damage_threshold: float = 15.0

# Wheel references
@onready var wheel_fl: Node3D = $WheelFL
@onready var wheel_fr: Node3D = $WheelFR
@onready var wheel_rl: Node3D = $WheelRL
@onready var wheel_rr: Node3D = $WheelRR
@onready var debug_draw: Node3D = $DebugDraw

# Suspension raycasts
@onready var susp_ray_fl: RayCast3D = $SuspensionRayFL
@onready var susp_ray_fr: RayCast3D = $SuspensionRayFR
@onready var susp_ray_rl: RayCast3D = $SuspensionRayRL
@onready var susp_ray_rr: RayCast3D = $SuspensionRayRR

func _ready() -> void:
	super._ready()
	mass = 1500.0  # kg
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

func _input(event: InputEvent) -> void:
	if not is_occupied:
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_J:
		_break_next_part()

func _physics_process(delta: float) -> void:
	# Suspension runs always (even unoccupied)
	_apply_suspension(delta)
	super._physics_process(delta)
	# Passive forces always apply (drag, friction, resistance)
	_apply_passive_physics(delta)

func _process(delta: float) -> void:
	# Rotate wheels visually based on speed
	var forward_speed: float = -global_transform.basis.z.dot(linear_velocity)
	var wheel_rotation_speed: float = forward_speed / wheel_radius

	# Front wheels - steer and spin
	if wheel_fl and has_wheel_fl:
		wheel_fl.rotation.y = deg_to_rad(current_steer)
		var roll_fl: Node3D = wheel_fl.get_node_or_null("Roll")
		if roll_fl:
			roll_fl.rotate_x(wheel_rotation_speed * delta)
	if wheel_fr and has_wheel_fr:
		wheel_fr.rotation.y = deg_to_rad(current_steer)
		var roll_fr: Node3D = wheel_fr.get_node_or_null("Roll")
		if roll_fr:
			roll_fr.rotate_x(wheel_rotation_speed * delta)

	# Rear wheels - just spin
	if wheel_rl and has_wheel_rl:
		var roll_rl: Node3D = wheel_rl.get_node_or_null("Roll")
		if roll_rl:
			roll_rl.rotate_x(wheel_rotation_speed * delta)
	if wheel_rr and has_wheel_rr:
		var roll_rr: Node3D = wheel_rr.get_node_or_null("Roll")
		if roll_rr:
			roll_rr.rotate_x(wheel_rotation_speed * delta)

func _apply_suspension(delta: float) -> void:
	var rays: Array = [susp_ray_fl, susp_ray_fr, susp_ray_rl, susp_ray_rr]
	var wheels: Array = [wheel_fl, wheel_fr, wheel_rl, wheel_rr]
	var has_wheel: Array = [has_wheel_fl, has_wheel_fr, has_wheel_rl, has_wheel_rr]
	var ray_length: float = suspension_travel + wheel_radius  # 0.55m

	for i in 4:
		if not rays[i] or not has_wheel[i]:
			_prev_compression[i] = 0.0
			continue

		var mount_y: float = rays[i].position.y  # 0.55 in local space

		if not rays[i].is_colliding():
			# Wheel fully extended (in air)
			_prev_compression[i] = 0.0
			if wheels[i]:
				wheels[i].position.y = mount_y - ray_length + wheel_radius
			continue

		# Ray is hitting ground
		var hit_point: Vector3 = rays[i].get_collision_point()
		var hit_normal: Vector3 = rays[i].get_collision_normal()
		var ray_origin_world: Vector3 = rays[i].global_position
		var hit_distance: float = ray_origin_world.distance_to(hit_point)

		# Compression: how much shorter than full ray length
		var compression: float = clamp(ray_length - hit_distance, 0.0, suspension_travel)

		# Compression velocity for damping
		var compression_velocity: float = (compression - _prev_compression[i]) / delta
		_prev_compression[i] = compression

		# Spring-damper force
		var force_magnitude: float = (compression * spring_stiffness) + (compression_velocity * damping_coefficient)
		force_magnitude = max(force_magnitude, 0.0)  # Springs only push

		# Apply force at the wheel position along the surface normal
		var force_vector: Vector3 = hit_normal * force_magnitude
		var force_position: Vector3 = rays[i].global_position - global_position
		apply_force(force_vector, force_position)

		# Update visual wheel position
		if wheels[i]:
			wheels[i].position.y = mount_y - hit_distance + wheel_radius

func _process_inputs(delta: float) -> void:
	# Throttle/Brake/Reverse: W/S
	throttle_input = 0.0
	brake_input = 0.0
	var forward_speed: float = (-global_transform.basis.z).dot(linear_velocity)
	if Input.is_action_pressed("collective_up"):
		if forward_speed < -1.0:
			brake_input = 1.0
		else:
			throttle_input = 1.0
	if Input.is_action_pressed("collective_down"):
		if forward_speed > 1.0:
			brake_input = 1.0
		else:
			throttle_input = -1.0

	# Steering: A/D
	steer_input = Input.get_axis("pedal_right", "pedal_left")

	# Smooth steering
	var target_steer: float = steer_input * max_steer_angle
	if absf(steer_input) > 0.1:
		current_steer = move_toward(current_steer, target_steer, steering_speed * max_steer_angle * delta)
	else:
		current_steer = move_toward(current_steer, 0.0, steering_return_speed * max_steer_angle * delta)

	input_throttle = throttle_input
	input_yaw = steer_input

func _apply_flight_physics(_delta: float) -> void:
	clear_debug_forces()

	var forward: Vector3 = -global_transform.basis.z
	var up: Vector3 = global_transform.basis.y

	# Get forward velocity
	var forward_speed: float = forward.dot(linear_velocity)

	# === THROTTLE ===
	var rear_wheel_factor: float = 0.0
	if has_wheel_rl:
		rear_wheel_factor += 0.5
	if has_wheel_rr:
		rear_wheel_factor += 0.5

	if throttle_input != 0 and rear_wheel_factor > 0:
		var speed_limit: float = max_speed if throttle_input > 0 else max_speed * 0.4
		var current_dir_speed: float = forward_speed * sign(throttle_input)
		if current_dir_speed < speed_limit:
			var power: float = engine_power if throttle_input > 0 else engine_power * 0.5
			var throttle_force: Vector3 = forward * power * throttle_input * rear_wheel_factor
			apply_central_force(throttle_force)
			add_debug_force("throttle", throttle_force, Color.BLUE)

	# === BRAKING ===
	var speed: float = linear_velocity.length()
	if brake_input > 0 and speed > 0.5:
		var brake_force: Vector3 = -linear_velocity.normalized() * brake_power * brake_input
		apply_central_force(brake_force)
		add_debug_force("brake", brake_force, Color.RED)

	# === STEERING (Ackermann-style turn radius) ===
	var front_wheel_factor: float = 0.0
	if has_wheel_fl:
		front_wheel_factor += 0.5
	if has_wheel_fr:
		front_wheel_factor += 0.5

	if absf(current_steer) > 0.5 and absf(forward_speed) > 0.5 and front_wheel_factor > 0:
		var steer_rad: float = deg_to_rad(current_steer)
		var turn_angular_velocity: float = forward_speed * tan(steer_rad) / wheelbase * front_wheel_factor

		var target_omega: float = turn_angular_velocity
		var current_omega: float = angular_velocity.dot(up)
		var omega_diff: float = target_omega - current_omega

		var steer_torque: float = omega_diff * mass * 1.2
		apply_torque(up * steer_torque)

	# === CORNERING SPEED LOSS ===
	if absf(current_steer) > 1.0 and speed > 2.0:
		var steer_factor: float = absf(current_steer) / max_steer_angle
		var cornering_drag: Vector3 = -linear_velocity.normalized() * speed * steer_factor * mass * 0.5
		apply_central_force(cornering_drag)

func _apply_passive_physics(_delta: float) -> void:
	# Return steering to center and brake hard when unoccupied
	if not is_occupied:
		throttle_input = 0.0
		brake_input = 0.0
		steer_input = 0.0
		current_steer = move_toward(current_steer, 0.0, steering_return_speed * max_steer_angle * _delta)
		# Full brake + kill spin when nobody is driving
		if linear_velocity.length() > 0.2:
			apply_central_force(-linear_velocity.normalized() * brake_power)
		if angular_velocity.length() > 0.05:
			apply_torque(-angular_velocity * mass * 5.0)

	var right: Vector3 = global_transform.basis.x
	var speed: float = linear_velocity.length()

	# === LATERAL FRICTION (tire grip) - applied at wheel positions for body roll ===
	var lateral_velocity: float = right.dot(linear_velocity)
	var rays: Array = [susp_ray_fl, susp_ray_fr, susp_ray_rl, susp_ray_rr]
	var has_wheel: Array = [has_wheel_fl, has_wheel_fr, has_wheel_rl, has_wheel_rr]

	var grip_per_wheel: float = wheel_grip / 4.0
	if absf(lateral_velocity) > slip_threshold:
		grip_per_wheel *= slip_threshold / absf(lateral_velocity)

	for i in 4:
		if rays[i] and has_wheel[i] and rays[i].is_colliding():
			var friction_force: Vector3 = -right * lateral_velocity * grip_per_wheel * mass
			var force_pos: Vector3 = rays[i].global_position - global_position
			apply_force(friction_force, force_pos)

	# === ROLLING RESISTANCE ===
	if speed > 0.1:
		var rolling_resistance: Vector3 = -linear_velocity.normalized() * mass * 1.5
		apply_central_force(rolling_resistance)

	# === AIR DRAG (quadratic) ===
	var drag_coefficient: float = 0.5
	var drag: Vector3 = -linear_velocity * speed * drag_coefficient
	apply_central_force(drag)

	# === ANGULAR DAMPING ===
	apply_torque(-angular_velocity * mass * 3.0)

func _on_debug_toggled() -> void:
	if debug_draw:
		debug_draw.visible = debug_enabled

func _break_next_part() -> void:
	if damage_index >= damage_sequence.size():
		print("All wheels already destroyed!")
		return

	var part_to_break: String = damage_sequence[damage_index]
	damage_index += 1

	match part_to_break:
		"wheel_fl":
			_destroy_wheel_fl()
		"wheel_fr":
			_destroy_wheel_fr()
		"wheel_rl":
			_destroy_wheel_rl()
		"wheel_rr":
			_destroy_wheel_rr()

func _destroy_wheel_fl() -> void:
	if not has_wheel_fl:
		return
	has_wheel_fl = false
	if wheel_fl:
		spawn_debris(wheel_fl, 15.0)
		wheel_fl = null
	if susp_ray_fl:
		susp_ray_fl.enabled = false
	print("Front left wheel destroyed!")

func _destroy_wheel_fr() -> void:
	if not has_wheel_fr:
		return
	has_wheel_fr = false
	if wheel_fr:
		spawn_debris(wheel_fr, 15.0)
		wheel_fr = null
	if susp_ray_fr:
		susp_ray_fr.enabled = false
	print("Front right wheel destroyed!")

func _destroy_wheel_rl() -> void:
	if not has_wheel_rl:
		return
	has_wheel_rl = false
	if wheel_rl:
		spawn_debris(wheel_rl, 15.0)
		wheel_rl = null
	if susp_ray_rl:
		susp_ray_rl.enabled = false
	print("Rear left wheel destroyed!")

func _destroy_wheel_rr() -> void:
	if not has_wheel_rr:
		return
	has_wheel_rr = false
	if wheel_rr:
		spawn_debris(wheel_rr, 15.0)
		wheel_rr = null
	if susp_ray_rr:
		susp_ray_rr.enabled = false
	print("Rear right wheel destroyed!")

func _get_wheel_count() -> int:
	var count := 0
	if has_wheel_fl:
		count += 1
	if has_wheel_fr:
		count += 1
	if has_wheel_rl:
		count += 1
	if has_wheel_rr:
		count += 1
	return count

func _on_body_entered(body: Node) -> void:
	var impact_speed := linear_velocity.length()
	if impact_speed > impact_damage_threshold:
		print("Collision with %s at %.1f m/s" % [body.name, impact_speed])
		_apply_impact_damage(impact_speed)

func _apply_impact_damage(impact_speed: float) -> void:
	var damage_rolls := 1
	if impact_speed > impact_damage_threshold * 2:
		damage_rolls = 2

	for i in damage_rolls:
		if has_wheel_fl:
			_destroy_wheel_fl()
		elif has_wheel_fr:
			_destroy_wheel_fr()
		elif has_wheel_rl:
			_destroy_wheel_rl()
		elif has_wheel_rr:
			_destroy_wheel_rr()
		else:
			break
