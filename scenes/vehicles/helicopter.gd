extends Vehicle
class_name Helicopter

## Helicopter with Arma 3-style flight physics
## Features: collective, cyclic, anti-torque pedals, ground effect, translational lift

# Rotor properties
@export_group("Rotor Configuration")
@export var rotor_radius: float = 5.0       # meters
@export var rotor_rpm: float = 300.0        # revolutions per minute
@export var blade_count: int = 4

# Physics tuning
@export_group("Flight Characteristics")
@export var max_lift_force: float = 80000.0      # Newtons at full collective
@export var cyclic_authority: float = 8000.0     # Torque for pitch/roll (reduced)
@export var tail_rotor_authority: float = 15000.0 # Torque for yaw (increased)
@export var drag_coefficient: float = 0.5
@export var angular_drag: float = 4.0            # Increased for stability

# Stability assists (Arma 3 style - forgiving)
@export_group("Stability")
@export var auto_level_strength: float = 0.5     # How much it wants to level out (increased)
@export var stability_damping: float = 1.5       # Damps oscillations (increased)
@export var yaw_damping: float = 2.0             # Extra yaw damping (only with tail rotor)
@export var collective_response: float = 0.3     # How fast collective changes

# Hover hold PID
@export_group("Hover Hold")
@export var hover_pid_p: float = 0.03            # Proportional: response to altitude error
@export var hover_pid_i: float = 0.005           # Integral: eliminates steady-state drift
@export var hover_pid_d: float = 0.08            # Derivative: damps vertical velocity
@export var hover_pid_i_max: float = 0.15        # Integral windup clamp
@export var hover_base_collective: float = 0.38  # Starting point for PID adjustments

# Ground effect
@export_group("Ground Effect")
@export var ground_effect_height: float = 10.0   # Height where ground effect starts
@export var ground_effect_max_bonus: float = 0.2 # 20% extra lift at ground level

# Translational lift
@export_group("Translational Lift")
@export var translational_lift_speed: float = 15.0  # Speed for full ETL
@export var translational_lift_bonus: float = 0.2   # 20% extra lift at ETL

# Current state
var collective: float = 0.0        # Start at 0, player raises to hover
var cyclic_pitch: float = 0.0      # -1 to 1 (forward/back)
var cyclic_roll: float = 0.0       # -1 to 1 (left/right)
var pedal_input: float = 0.0       # -1 to 1 (yaw left/right)
var rotor_speed: float = 0.0       # 0 to 1 (spool up)

# Hover hold PID state
var _hover_hold_active := false
var _hover_target_alt: float = 0.0
var _hover_pid_integral: float = 0.0
var _hover_prev_error: float = 0.0

# Damage state
var has_tail_rotor := true
var has_main_rotor := true
var has_tail_boom := true
var damage_sequence := ["tail_rotor", "main_rotor", "tail_boom"]
var damage_index := 0

# Impact damage
@export_group("Damage")
@export var impact_damage_threshold: float = 15.0  # m/s collision speed to cause damage

# Rotor mesh for visual spin
@onready var main_rotor: Node3D = $MainRotor
@onready var tail_rotor: Node3D = $TailRotor
@onready var tail_boom: Node3D = $TailBoom
@onready var debug_draw: Node3D = $DebugDraw

func _ready() -> void:
	super._ready()
	mass = 4000.0  # kg, typical light helicopter
	requires_startup = true
	engine_running = false

	# Start with no rotor inertia
	rotor_speed = 0.0

	# Enable contact monitoring for impact detection
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)

func _input(event: InputEvent) -> void:
	if not is_occupied:
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_J:
		_break_next_part()

func _process(delta: float) -> void:
	super._process(delta)
	# Spool rotor based on engine state (runs even when not occupied)
	if engine_running:
		rotor_speed = move_toward(rotor_speed, 1.0, delta * 0.5)
	else:
		rotor_speed = move_toward(rotor_speed, 0.0, delta * 0.3)

	# Spin rotors visually
	if main_rotor and has_main_rotor:
		main_rotor.rotate_y(rotor_speed * rotor_rpm * TAU / 60.0 * delta)
	if tail_rotor and has_tail_rotor:
		tail_rotor.rotate_x(rotor_speed * rotor_rpm * 5 * TAU / 60.0 * delta)


func _process_inputs(delta: float) -> void:
	# Collective: Shift/Z (throttle_up/throttle_down)
	var collective_input := 0.0
	if Input.is_action_pressed("throttle_up"):
		collective_input = 1.0
	elif Input.is_action_pressed("throttle_down"):
		collective_input = -1.0

	if collective_input != 0.0:
		# Player is actively controlling - respond to input
		collective = clamp(collective + collective_input * collective_response * delta, 0.0, 1.0)
		# Reset hover hold so it captures new altitude on release
		_hover_hold_active = false
		_hover_pid_integral = 0.0
	elif altitude_agl > 3.0:
		# PID hover hold when airborne and no input
		if not _hover_hold_active:
			# Just released input - lock current altitude as target
			_hover_target_alt = altitude_agl
			_hover_pid_integral = 0.0
			_hover_prev_error = 0.0
			_hover_hold_active = true

		var alt_error: float = _hover_target_alt - altitude_agl
		_hover_pid_integral = clampf(_hover_pid_integral + alt_error * delta, -hover_pid_i_max, hover_pid_i_max)
		var alt_derivative: float = -linear_velocity.y  # Negative because falling = positive error rate
		var pid_output: float = hover_pid_p * alt_error + hover_pid_i * _hover_pid_integral + hover_pid_d * alt_derivative
		collective = clampf(hover_base_collective + pid_output, 0.0, 1.0)

	input_throttle = collective

	# Cyclic from mouse + W/S for pitch + A/D for roll
	cyclic_pitch = mouse_input.y
	# W = tilt forward (pitch down), S = tilt backward (pitch up)
	cyclic_pitch += Input.get_axis("move_forward", "move_backward") * 0.6
	cyclic_pitch = clamp(cyclic_pitch, -1.0, 1.0)
	cyclic_roll = mouse_input.x
	# A/D adds to roll
	cyclic_roll += Input.get_axis("move_left", "move_right")
	cyclic_roll = clamp(cyclic_roll, -1.0, 1.0)
	input_pitch = cyclic_pitch
	input_roll = cyclic_roll

	# Pedals: Q/E (negated so Q=left, E=right)
	pedal_input = -Input.get_axis("pedal_left", "pedal_right")
	input_yaw = pedal_input

func _apply_flight_physics(delta: float) -> void:
	if rotor_speed < 0.1:
		return

	# No main rotor = no flight physics (just fall)
	if not has_main_rotor:
		clear_debug_forces()
		return

	clear_debug_forces()

	var up := global_transform.basis.y
	var forward := -global_transform.basis.z
	var right := global_transform.basis.x

	# === LIFT FORCE ===
	# Base lift from collective and rotor speed
	var base_lift := max_lift_force * collective * rotor_speed * rotor_speed

	# Ground effect bonus
	var ground_effect := _calculate_ground_effect()
	var lift_with_ground_effect := base_lift * (1.0 + ground_effect)

	# Translational lift (ETL - Effective Translational Lift)
	var horizontal_speed: float = Vector2(linear_velocity.x, linear_velocity.z).length()
	var translational_factor: float = clamp(horizontal_speed / translational_lift_speed, 0.0, 1.0)
	var total_lift: float = lift_with_ground_effect * (1.0 + translational_lift_bonus * translational_factor)

	# Apply lift in rotor disc direction (slightly tilted by cyclic)
	var lift_direction: Vector3 = up
	lift_direction = lift_direction.rotated(right, cyclic_pitch * 0.3)  # Tilt forward/back
	lift_direction = lift_direction.rotated(forward, -cyclic_roll * 0.3) # Tilt left/right

	var lift_force: Vector3 = lift_direction * total_lift
	apply_central_force(lift_force)
	add_debug_force("lift", lift_force, Color.RED)

	# Debug: show ground effect
	if ground_effect > 0.01:
		add_debug_force("ground_fx", Vector3.UP * ground_effect * 20000, Color.CYAN)

	# Debug: show translational lift
	if translational_factor > 0.1:
		add_debug_force("trans_lift", Vector3.UP * translational_factor * 10000, Color.MAGENTA)

	# === DRAG ===
	var velocity_sq := linear_velocity.length_squared()
	if velocity_sq > 0.1:
		var drag_force := -linear_velocity.normalized() * velocity_sq * drag_coefficient
		apply_central_force(drag_force)
		add_debug_force("drag", drag_force, Color.GREEN)

	# === CYCLIC TORQUE ===
	# Cyclic tilts the rotor disc, creating a moment
	var pitch_torque := right * cyclic_pitch * cyclic_authority * rotor_speed
	var roll_torque := forward * cyclic_roll * cyclic_authority * rotor_speed
	apply_torque(pitch_torque + roll_torque)

	# === TAIL ROTOR / PEDALS ===
	# Main rotor torque tries to spin the body opposite to rotor direction
	# Increased multiplier so losing tail rotor causes noticeable spin
	var main_rotor_torque_magnitude: float = total_lift * 0.025
	var main_rotor_torque: Vector3 = -up * main_rotor_torque_magnitude

	# Tail rotor counters main rotor torque + provides yaw control
	# Without tail rotor, main rotor torque causes uncontrolled spin
	var total_tail_torque: Vector3 = Vector3.ZERO
	if has_tail_rotor:
		var tail_counter_torque: Vector3 = up * main_rotor_torque_magnitude  # Counter the main rotor
		var tail_yaw_control: Vector3 = up * pedal_input * tail_rotor_authority * rotor_speed
		total_tail_torque = tail_counter_torque + tail_yaw_control
		add_debug_force("tail_rotor", total_tail_torque * 0.1, Color.CYAN)

	apply_torque(main_rotor_torque + total_tail_torque)
	add_debug_force("main_torque", main_rotor_torque * 0.1, Color.ORANGE)

	# === YAW DAMPING ===
	# Only apply yaw damping when tail rotor is functional
	# Without tail rotor, helicopter should spin uncontrollably
	if has_tail_rotor:
		var yaw_damp: Vector3 = -up * up.dot(angular_velocity) * yaw_damping * mass
		apply_torque(yaw_damp)

	# === STABILITY ASSISTS ===
	_apply_stability(delta, up)

	# === ANGULAR DRAG ===
	# When tail rotor is missing, only damp pitch/roll, not yaw
	if has_tail_rotor:
		var angular_drag_torque: Vector3 = -angular_velocity * angular_drag * mass
		apply_torque(angular_drag_torque)
	else:
		# Strip out yaw component so helicopter spins freely
		var yaw_component: float = up.dot(angular_velocity)
		var pitch_roll_angular: Vector3 = angular_velocity - up * yaw_component
		var angular_drag_torque: Vector3 = -pitch_roll_angular * angular_drag * mass
		apply_torque(angular_drag_torque)

	# === VELOCITY VECTOR ===
	if airspeed > 1.0:
		add_debug_force("velocity", linear_velocity * 100, Color.YELLOW)

	# Update flight data
	angle_of_attack = calculate_aoa()

func _calculate_ground_effect() -> float:
	# Ground effect increases lift when close to ground
	if altitude_agl > ground_effect_height:
		return 0.0

	# Stronger effect closer to ground
	var effect_ratio := 1.0 - (altitude_agl / ground_effect_height)
	return ground_effect_max_bonus * effect_ratio * effect_ratio

func _apply_stability(_delta: float, up: Vector3) -> void:
	# Auto-leveling when cyclic is centered (Arma 3 style)
	if absf(cyclic_pitch) < 0.1 and absf(cyclic_roll) < 0.1:
		# Calculate how tilted we are
		var world_up := Vector3.UP
		var tilt_axis := up.cross(world_up)

		if tilt_axis.length() > 0.01:
			var tilt_angle := up.angle_to(world_up)
			var correction_torque := tilt_axis.normalized() * tilt_angle * auto_level_strength * mass
			apply_torque(correction_torque)

	# Damping to prevent oscillation
	# When tail rotor is missing, only damp pitch/roll oscillation
	if has_tail_rotor:
		var damping_torque := -angular_velocity * stability_damping * mass
		apply_torque(damping_torque)
	else:
		var up_dir := global_transform.basis.y
		var yaw_component: float = up_dir.dot(angular_velocity)
		var pitch_roll_angular: Vector3 = angular_velocity - up_dir * yaw_component
		var damping_torque := -pitch_roll_angular * stability_damping * mass
		apply_torque(damping_torque)

func _on_debug_toggled() -> void:
	if debug_draw:
		debug_draw.visible = debug_enabled

func _break_next_part() -> void:
	if damage_index >= damage_sequence.size():
		print("All parts already destroyed!")
		return

	var part_to_break: String = damage_sequence[damage_index]
	damage_index += 1

	match part_to_break:
		"tail_rotor":
			_destroy_tail_rotor()
		"main_rotor":
			_destroy_main_rotor()
		"tail_boom":
			_destroy_tail_boom()

func _destroy_tail_rotor() -> void:
	if not has_tail_rotor:
		return
	has_tail_rotor = false
	if tail_rotor:
		tail_rotor.visible = false
	print("Tail rotor destroyed! Losing yaw control!")

func _destroy_main_rotor() -> void:
	if not has_main_rotor:
		return
	has_main_rotor = false
	if main_rotor:
		main_rotor.visible = false
	print("Main rotor destroyed! No lift!")

func _destroy_tail_boom() -> void:
	if not has_tail_boom:
		return
	has_tail_boom = false
	has_tail_rotor = false  # Tail rotor goes with the boom
	if tail_boom:
		tail_boom.visible = false
	if tail_rotor:
		tail_rotor.visible = false
	print("Tail boom destroyed!")

func _on_body_entered(body: Node) -> void:
	# Actual collision with terrain or another object
	var impact_speed := linear_velocity.length()
	if impact_speed > impact_damage_threshold:
		print("Collision with %s at %.1f m/s" % [body.name, impact_speed])
		_apply_impact_damage(impact_speed)

func _apply_impact_damage(impact_speed: float) -> void:
	# Harder impacts cause more damage
	var damage_rolls := 1
	if impact_speed > impact_damage_threshold * 2:
		damage_rolls = 2
	if impact_speed > impact_damage_threshold * 3:
		damage_rolls = 3

	for i in damage_rolls:
		# Break parts based on what's still intact
		if has_tail_rotor:
			_destroy_tail_rotor()
		elif has_main_rotor:
			_destroy_main_rotor()
		elif has_tail_boom:
			_destroy_tail_boom()
		else:
			break
