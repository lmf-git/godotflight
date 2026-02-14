extends Vehicle
class_name FixedWing

## Fixed-wing aircraft with realistic aerodynamic flight model
## Features: lift/drag curves, stall, control surfaces, engine thrust

# Wing properties
@export_group("Wing Configuration")
@export var wing_area: float = 16.0       # m²
@export var wing_span: float = 10.0       # meters
@export var aspect_ratio: float = 6.25    # span² / area

# Aerodynamic coefficients
@export_group("Aerodynamics")
@export var cl_0: float = 0.35            # Lift coefficient at zero AoA (wing installed at ~4° incidence)
@export var cl_alpha: float = 2.8         # Lift curve slope (per radian) - finite wing correction
@export var cl_max: float = 1.3           # Maximum lift coefficient (clean wing)
@export var stall_angle: float = 15.0     # degrees
@export var cd_0: float = 0.05            # Parasitic drag coefficient (increased)
@export var oswald_efficiency: float = 0.75 # Oswald span efficiency

# Control surface authority
@export_group("Control Surfaces")
@export var elevator_authority: float = 18000.0  # Pitch torque
@export var aileron_authority: float = 9000.0    # Roll torque
@export var rudder_authority: float = 3000.0     # Yaw torque

# Engine
@export_group("Engine")
@export var max_thrust: float = 12000.0   # Newtons (powerful warbird ~T/W 0.6)
@export var throttle_response: float = 0.8 # How fast throttle changes

# Stability
@export_group("Stability")
@export var pitch_stability: float = 0.3
@export var roll_stability: float = 0.3
@export var yaw_stability: float = 0.6
@export var angular_damping: float = 1.5

# Ground effect
@export_group("Ground Effect")
@export var ground_effect_height: float = 10.0  # half wingspan
@export var ground_effect_max_bonus: float = 0.3  # 30% extra lift at ground level (realistic)

# State
var throttle: float = 0.0           # 0 to 1
var elevator_input: float = 0.0     # -1 to 1
var aileron_input: float = 0.0      # -1 to 1
var rudder_input: float = 0.0       # -1 to 1
var flaps_input: float = 0.0        # 0 to 1 (flaps setting)
var is_stalled := false
var current_cl: float = 0.0
var current_cd: float = 0.0
var ground_effect_factor: float = 0.0
var gear_down := true
var gear_position: float = 1.0      # 0 = retracted, 1 = extended
var nosewheel_current_angle: float = 0.0  # Current smoothed steering angle (radians)
var _last_damage_frame: int = -1

# Missiles
var missiles: Array[Missile] = []
var next_missile_index: int = 0
const MISSILE_SCENE := preload("res://scenes/vehicles/missile.tscn")
var hardpoint_positions: Array[Vector3] = [
	Vector3(-2.0, -0.3, 0.5),   # Left wing
	Vector3(2.0, -0.3, 0.5),    # Right wing
]

# Gun
var gun: AircraftGun
var gun_firing := false

# Flaps settings
@export_group("Flaps")
@export var flaps_cl_bonus: float = 0.3      # Extra lift coefficient from flaps (reduced)
@export var flaps_cd_penalty: float = 0.1    # Extra drag from flaps (increased)
@export var flaps_response: float = 0.5      # How fast flaps deploy

# Damage state
var has_left_wing := true
var has_right_wing := true
var has_horizontal_tail := true
var has_vertical_tail := true
var damage_sequence := ["left_wing", "right_wing", "horizontal_tail", "vertical_tail"]
var damage_index := 0

# Impact damage
@export_group("Damage")
@export var impact_damage_threshold: float = 20.0  # m/s collision speed to cause damage
@export var gear_break_speed: float = 8.0          # m/s vertical speed to collapse gear

# Landing gear
@export_group("Landing Gear")
@export var nosewheel_steer_angle: float = 45.0        # Max nosewheel steering angle (degrees)
@export var brake_force: float = 20000.0               # Max brake force (Newtons)

# Gear damage state
var has_front_gear := true
var has_left_gear := true
var has_right_gear := true

# Air density (sea level standard)
const AIR_DENSITY: float = 1.225  # kg/m³

@onready var propeller: Node3D = $Propeller
@onready var landing_gear: Node3D = $LandingGear
@onready var debug_draw: Node3D = $DebugDraw

# Wheel colliders
@onready var front_wheel_col: CollisionShape3D = $FrontWheelCollider
@onready var left_wheel_col: CollisionShape3D = $LeftWheelCollider
@onready var right_wheel_col: CollisionShape3D = $RightWheelCollider
@onready var left_wing_mesh: MeshInstance3D = $LeftWing
@onready var right_wing_mesh: MeshInstance3D = $RightWing
@onready var left_wing_collider: CollisionShape3D = $LeftWingCollider
@onready var right_wing_collider: CollisionShape3D = $RightWingCollider
@onready var horizontal_tail_mesh: MeshInstance3D = $HorizontalTail
@onready var vertical_tail_mesh: MeshInstance3D = $VerticalTail
@onready var htail_collider: CollisionShape3D = $HTailCollider
@onready var vtail_collider: CollisionShape3D = $VTailCollider

# Control surfaces
@onready var left_aileron: MeshInstance3D = $LeftWing/LeftAileron
@onready var right_aileron: MeshInstance3D = $RightWing/RightAileron
@onready var left_flap: MeshInstance3D = $LeftWing/LeftFlap
@onready var right_flap: MeshInstance3D = $RightWing/RightFlap
@onready var left_elevator: MeshInstance3D = $HorizontalTail/LeftElevator
@onready var right_elevator: MeshInstance3D = $HorizontalTail/RightElevator
@onready var rudder: MeshInstance3D = $VerticalTail/Rudder

func _ready() -> void:
	super._ready()
	mass = 2000.0  # kg, light aircraft
	requires_startup = true
	engine_running = false

	# Initialize landing gear to extended position
	if landing_gear:
		for gear_node in landing_gear.get_children():
			gear_node.visible = true

	# Enable contact monitoring for impact detection
	contact_monitor = true
	max_contacts_reported = 4
	body_shape_entered.connect(_on_body_shape_entered)

	# Spawn missiles at hardpoints
	_spawn_missiles()

	# Create nose gun
	gun = AircraftGun.new()
	gun.position = Vector3(0, 0, -10.0)  # Near propeller/nose
	add_child(gun)

func _input(event: InputEvent) -> void:
	if not is_occupied:
		return

	if event.is_action_pressed("toggle_gear"):
		# Block extending gear when body is on the ground (no clearance for struts)
		if not gear_down and altitude_agl < 1.5 and gear_position < 0.5:
			print("Cannot extend gear - not enough ground clearance!")
		else:
			gear_down = not gear_down
			print("Gear toggled: ", gear_down)

	if event is InputEventKey and event.pressed and event.keycode == KEY_J:
		_break_next_part()

	# Flaps control: [ to decrease, ] to increase
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_BRACKETRIGHT:
			flaps_input = clamp(flaps_input + 0.25, 0.0, 1.0)
			print("Flaps: %.0f%%" % (flaps_input * 100))
		elif event.keycode == KEY_BRACKETLEFT:
			flaps_input = clamp(flaps_input - 0.25, 0.0, 1.0)
			print("Flaps: %.0f%%" % (flaps_input * 100))
		elif event.keycode == KEY_F:
			fire_missile()
		elif event.keycode == KEY_G:
			gun_firing = true
	# Gun release
	if event is InputEventKey and not event.pressed:
		if event.keycode == KEY_G:
			gun_firing = false

func _physics_process(delta: float) -> void:
	_update_wheel_colliders()
	super._physics_process(delta)

func _process(delta: float) -> void:
	super._process(delta)
	# Spin propeller based on throttle (idle spin when engine running)
	if propeller:
		var spin := throttle * 50.0
		if engine_running and throttle < 0.01:
			spin = 5.0  # slow idle spin
		propeller.rotate_z(spin * delta)

	# Gun firing
	if gun_firing and is_occupied and gun:
		var muzzle := gun.global_position
		var forward := -global_transform.basis.z
		gun.fire(muzzle, forward, linear_velocity)

	# Animate landing gear
	var target_gear: float = 1.0 if gear_down else 0.0
	gear_position = move_toward(gear_position, target_gear, delta * 0.5)

	# Update landing gear animation + nosewheel steering
	_animate_landing_gear(delta)

	# Animate control surfaces
	_animate_control_surfaces()

func _animate_landing_gear(delta: float) -> void:
	if not landing_gear:
		return

	# Front strut is shorter so it finishes slightly faster
	var front_progress: float = clamp(gear_position * 1.2, 0.0, 1.0)
	var main_progress: float = gear_position

	# Retract angle: 0 = extended (down), PI/2 = retracted (up)
	var front_retract_angle: float = (1.0 - front_progress) * PI / 2.0
	var main_retract_angle: float = (1.0 - main_progress) * PI / 2.0

	var front_gear: Node3D = landing_gear.get_node_or_null("FrontGear")
	var left_gear: Node3D = landing_gear.get_node_or_null("LeftGear")
	var right_gear: Node3D = landing_gear.get_node_or_null("RightGear")

	# Front gear: retraction + gradual nosewheel steering
	if front_gear:
		var target_steer: float = 0.0
		if gear_position > 0.85 and is_occupied:
			target_steer = rudder_input * deg_to_rad(nosewheel_steer_angle)
		# Smoothly rotate toward target steering angle
		var steer_speed: float = 3.0  # radians per second
		nosewheel_current_angle = move_toward(nosewheel_current_angle, target_steer, steer_speed * delta)
		front_gear.rotation = Vector3(front_retract_angle, nosewheel_current_angle, 0.0)

	# Main gear rotates forward into wings (negative X rotation)
	if left_gear:
		left_gear.rotation.x = -main_retract_angle
	if right_gear:
		right_gear.rotation.x = -main_retract_angle

func _process_inputs(delta: float) -> void:
	# Throttle: Shift/Ctrl (requires engine running)
	if engine_running:
		var throttle_input := 0.0
		if Input.is_action_pressed("throttle_up"):
			throttle_input = 1.0
		elif Input.is_action_pressed("throttle_down"):
			throttle_input = -1.0
		throttle = clamp(throttle + throttle_input * throttle_response * delta, 0.0, 1.0)
	else:
		throttle = 0.0
	input_throttle = throttle

	# Elevator (pitch) from mouse Y + W/S keys
	elevator_input = -mouse_input.y  # Pull back = pitch up
	if Input.is_action_pressed("collective_up"):
		elevator_input -= 0.6  # W = pitch down (push forward)
	if Input.is_action_pressed("collective_down"):
		elevator_input += 0.6  # S = pitch up (pull back for takeoff rotation)
	elevator_input = clamp(elevator_input, -1.0, 1.0)

	# Ailerons (roll) from mouse X + A/D keys
	aileron_input = mouse_input.x
	aileron_input += Input.get_axis("move_left", "move_right") * 0.5
	aileron_input = clamp(aileron_input, -1.0, 1.0)

	# Rudder: Q/E — limit deflection at high speed (full rudder only for ground steering)
	var raw_rudder := -Input.get_axis("yaw_left", "yaw_right")
	var rudder_limit: float = clampf(lerpf(1.0, 0.15, airspeed / 80.0), 0.15, 1.0)
	rudder_input = raw_rudder * rudder_limit

	input_pitch = elevator_input
	input_roll = aileron_input
	input_yaw = rudder_input

func _apply_flight_physics(delta: float) -> void:
	clear_debug_forces()

	var forward := -global_transform.basis.z
	var up := global_transform.basis.y
	var right := global_transform.basis.x

	# Get velocity in local coordinates
	var local_velocity: Vector3 = get_local_velocity()
	var _airspeed_local: float = local_velocity.length()

	# Calculate angle of attack
	angle_of_attack = calculate_aoa()
	var _aoa_rad: float = deg_to_rad(angle_of_attack)

	# === LIFT ===
	current_cl = _calculate_lift_coefficient(angle_of_attack)

	# Flaps add lift coefficient
	current_cl += flaps_input * flaps_cl_bonus

	var dynamic_pressure: float = 0.5 * AIR_DENSITY * airspeed * airspeed
	var lift_magnitude: float = dynamic_pressure * wing_area * current_cl

	# Wing damage reduces lift (each wing is 50%)
	var wing_factor: float = _get_wing_factor()
	lift_magnitude *= wing_factor

	# Ground effect - increases lift when close to ground
	ground_effect_factor = _calculate_ground_effect()
	lift_magnitude *= (1.0 + ground_effect_factor)

	# Lift acts perpendicular to velocity, in the plane of the wing
	var lift_direction: Vector3 = Vector3.UP
	if airspeed > 1.0:
		var velocity_dir: Vector3 = linear_velocity.normalized()
		lift_direction = velocity_dir.cross(right).normalized()
		if lift_direction.dot(up) < 0:
			lift_direction = -lift_direction

	var lift_force: Vector3 = lift_direction * lift_magnitude
	apply_central_force(lift_force)
	add_debug_force("lift", lift_force, Color.RED)

	# Asymmetric wing damage causes severe roll - missing wing means no lift on that side
	var roll_asymmetry: float = _get_roll_asymmetry()
	if absf(roll_asymmetry) > 0.01 and airspeed > 5.0:
		# Much stronger effect - nearly uncontrollable with one wing
		var asymmetric_roll_torque: Vector3 = forward * roll_asymmetry * lift_magnitude * 0.8
		apply_torque(asymmetric_roll_torque)
		# Also apply yaw from asymmetric drag
		var asymmetric_yaw: Vector3 = up * roll_asymmetry * dynamic_pressure * 50.0
		apply_torque(asymmetric_yaw)

	# Add ground effect indicator
	if ground_effect_factor > 0.01:
		add_debug_force("ground_fx", Vector3.UP * ground_effect_factor * 10000, Color.CYAN)

	# === DRAG ===
	# Parasitic + Induced drag
	var induced_drag_coef: float = (current_cl * current_cl) / (PI * oswald_efficiency * aspect_ratio)
	current_cd = cd_0 + induced_drag_coef

	# Flaps add drag
	current_cd += flaps_input * flaps_cd_penalty

	# High AoA form drag - wing presents more cross-section to airflow
	var aoa_rad_abs := deg_to_rad(absf(angle_of_attack))
	var form_drag := sin(aoa_rad_abs)
	current_cd += 0.25 * form_drag * form_drag

	# Post-stall drag penalty (steeper than pre-stall)
	if is_stalled:
		current_cd += 0.15 * (absf(angle_of_attack) - stall_angle) / 10.0

	var drag_magnitude: float = dynamic_pressure * wing_area * current_cd
	var drag_force: Vector3 = Vector3.ZERO
	if airspeed > 0.1:
		drag_force = -linear_velocity.normalized() * drag_magnitude
	apply_central_force(drag_force)
	add_debug_force("drag", drag_force, Color.GREEN)

	# === THRUST ===
	var thrust_force: Vector3 = forward * max_thrust * throttle
	apply_central_force(thrust_force)
	add_debug_force("thrust", thrust_force, Color.BLUE)

	# === STALL PITCH-DOWN MOMENT ===
	# Aerodynamic nose-down torque past stall — mimics center of pressure shift
	var abs_aoa := absf(angle_of_attack)
	if abs_aoa > stall_angle and airspeed > 5.0:
		var stall_excess: float = clampf((abs_aoa - stall_angle) / 20.0, 0.0, 1.0)
		# Gentle pitch-down tendency, recoverable with elevator
		var pitch_down_torque: float = -signf(angle_of_attack) * stall_excess * dynamic_pressure * wing_area * 0.025
		apply_torque(right * pitch_down_torque)

	# === CONTROL SURFACES ===
	# Effectiveness scales with dynamic pressure (need ~55 m/s for full authority)
	var control_effectiveness: float = clamp(dynamic_pressure / 2000.0, 0.08, 1.0)

	# Reduce control effectiveness in stall (disturbed airflow over tail)
	if abs_aoa > stall_angle:
		var stall_penalty: float = clamp((abs_aoa - stall_angle) / 25.0, 0.0, 0.4)
		control_effectiveness *= (1.0 - stall_penalty)

	# Elevator (pitch) - requires horizontal tail
	if has_horizontal_tail:
		var pitch_torque: Vector3 = right * elevator_input * elevator_authority * control_effectiveness
		apply_torque(pitch_torque)

	# Ailerons (roll) - effectiveness reduced with wing damage
	var aileron_effectiveness: float = wing_factor
	var roll_torque: Vector3 = forward * aileron_input * aileron_authority * control_effectiveness * aileron_effectiveness
	apply_torque(roll_torque)

	# Rudder (yaw) - requires vertical tail
	if has_vertical_tail:
		var yaw_torque: Vector3 = up * rudder_input * rudder_authority * control_effectiveness
		apply_torque(yaw_torque)

	# === SIDESLIP SIDE FORCE ===
	# Yaw creates sideslip, sideslip creates lateral force that curves flight path
	var local_vel := get_local_velocity()
	if airspeed > 5.0:
		var sideslip := atan2(local_vel.x, -local_vel.z)
		var side_force := -right * sideslip * dynamic_pressure * wing_area * 0.15
		apply_central_force(side_force)

	# === MANEUVERING DRAG ===
	# Turning/rotating through the air bleeds speed (induced drag already covers most of this)
	var angular_speed_sq := angular_velocity.length_squared()
	if angular_speed_sq > 0.01 and airspeed > 5.0:
		var maneuver_drag := angular_speed_sq * dynamic_pressure * wing_area * 0.006
		apply_central_force(-linear_velocity.normalized() * maneuver_drag)

	# === GROUND FORCES ===
	_apply_ground_forces(delta)

	# === STABILITY ===
	_apply_stability(delta, up, forward, right)

	# === ANGULAR DAMPING ===
	var damping := -angular_velocity * angular_damping * mass
	apply_torque(damping)

	# === VELOCITY VECTOR ===
	if airspeed > 1.0:
		add_debug_force("velocity", linear_velocity * 100, Color.YELLOW)

func _calculate_lift_coefficient(aoa: float) -> float:
	var aoa_rad := deg_to_rad(aoa)

	# Pre-stall: linear lift curve
	if absf(aoa) < stall_angle:
		is_stalled = false
		var cl := cl_0 + cl_alpha * aoa_rad
		return clamp(cl, -cl_max, cl_max)

	# Post-stall: lift drops off (simplified model)
	is_stalled = true
	var stall_rad: float = deg_to_rad(stall_angle)
	var post_stall_aoa: float = absf(aoa) - stall_angle

	# Gradual dropoff after stall
	var stall_cl: float = cl_0 + cl_alpha * stall_rad * sign(aoa)
	var dropoff: float = 1.0 - (post_stall_aoa / 30.0)  # Drops to ~0 at 45° AoA
	dropoff = clamp(dropoff, 0.3, 1.0)

	return stall_cl * dropoff

func _apply_stability(_delta: float, up: Vector3, forward: Vector3, right: Vector3) -> void:
	# Weathervane stability (yaw into relative wind) - requires vertical tail
	if has_vertical_tail:
		var local_vel: Vector3 = get_local_velocity()
		if local_vel.length() > 5.0:
			# Sideslip angle
			var sideslip: float = atan2(local_vel.x, -local_vel.z)
			var yaw_correction: Vector3 = -up * sideslip * yaw_stability * mass
			apply_torque(yaw_correction)

	# Pitch stability - only at low pitch angles and low angular rate (trim tendency, not active damping)
	if has_horizontal_tail:
		var forward_horizontal: Vector3 = Vector3(forward.x, 0, forward.z).normalized()
		var pitch_angle: float = forward.angle_to(forward_horizontal) if forward_horizontal.length() > 0.01 else 0.0
		if forward.y < 0:
			pitch_angle = -pitch_angle

		# Only apply when controls centered AND not in a sustained maneuver
		if absf(elevator_input) < 0.1 and absf(angular_velocity.dot(right)) < 0.3:
			# Scale down at high pitch to avoid fighting climbs/dives
			var pitch_factor := clampf(1.0 - absf(pitch_angle) / 1.0, 0.0, 1.0)
			var pitch_correction: Vector3 = right * (-pitch_angle * pitch_stability * mass * 0.05 * pitch_factor)
			apply_torque(pitch_correction)

	# Roll stability (dihedral effect - tends to level wings) - reduced with wing damage
	var wing_factor: float = _get_wing_factor()
	var roll_angle: float = up.signed_angle_to(Vector3.UP, forward)
	if absf(aileron_input) < 0.1:
		var roll_correction: Vector3 = forward * (-roll_angle * roll_stability * mass * 0.05 * wing_factor)
		apply_torque(roll_correction)

func _calculate_ground_effect() -> float:
	# Ground effect increases lift when close to ground
	# Effect is strongest at ground level, diminishes with altitude
	if altitude_agl > ground_effect_height:
		return 0.0

	# Quadratic falloff - stronger near ground
	var effect_ratio: float = 1.0 - (altitude_agl / ground_effect_height)
	return ground_effect_max_bonus * effect_ratio * effect_ratio

func _update_wheel_colliders() -> void:
	# Enable/disable wheel colliders based on gear state, damage, and wing damage
	var gear_deployed: bool = gear_position >= 0.85
	if front_wheel_col:
		front_wheel_col.set_deferred("disabled", not (gear_deployed and has_front_gear))
	if left_wheel_col:
		left_wheel_col.set_deferred("disabled", not (gear_deployed and has_left_gear and has_left_wing))
	if right_wheel_col:
		right_wheel_col.set_deferred("disabled", not (gear_deployed and has_right_gear and has_right_wing))

func _apply_ground_forces(_delta: float) -> void:
	# Only apply when wheels are actually on the ground
	if gear_position < 0.85:
		return
	# Wheels extend ~1.5m below aircraft origin; no ground contact above that
	if altitude_agl > 2.0:
		return
	# If climbing away from ground, wheels have left the surface
	if linear_velocity.y > 1.5:
		return

	var forward := -global_transform.basis.z
	var right := global_transform.basis.x
	var max_grip_per_wheel: float = mass * 9.81 * 0.8 / 3.0

	# Wheel lateral friction - each wheel resists motion perpendicular to its rolling direction
	# Front wheel direction rotates with nosewheel steering, rear wheels stay fixed
	var steer_rad: float = rudder_input * deg_to_rad(nosewheel_steer_angle) if is_occupied else 0.0
	var front_lateral: Vector3 = right.rotated(Vector3.UP, steer_rad)
	var wheel_cols: Array = [front_wheel_col, left_wheel_col, right_wheel_col]
	var wheel_laterals: Array = [front_lateral, right, right]

	for i in 3:
		var col: CollisionShape3D = wheel_cols[i]
		if not col or col.disabled:
			continue
		var lat_dir: Vector3 = wheel_laterals[i]
		var lat_speed: float = lat_dir.dot(linear_velocity)
		if absf(lat_speed) > 0.05:
			var grip_force: float = minf(absf(lat_speed) * mass * 2.0 / 3.0, max_grip_per_wheel)
			var friction_vec: Vector3 = -lat_dir * sign(lat_speed) * grip_force
			var force_pos: Vector3 = col.global_position - global_position
			apply_force(friction_vec, force_pos)

	# Braking when throttle is zero
	if throttle < 0.01 and airspeed > 0.5:
		var forward_speed: float = linear_velocity.dot(forward)
		var brake_magnitude: float = brake_force * clamp(absf(forward_speed) / 5.0, 0.0, 1.0)
		var brake_vector: Vector3 = -forward * sign(forward_speed) * brake_magnitude
		apply_central_force(brake_vector)

func _on_debug_toggled() -> void:
	if debug_draw:
		debug_draw.visible = debug_enabled

func _animate_control_surfaces() -> void:
	var max_deflection: float = deg_to_rad(25.0)  # 25 degrees max deflection

	# Ailerons - opposite deflection for roll
	if left_aileron:
		left_aileron.rotation.x = -aileron_input * max_deflection
	if right_aileron:
		right_aileron.rotation.x = aileron_input * max_deflection

	# Elevators - same deflection for pitch
	var elevator_angle: float = elevator_input * max_deflection
	if left_elevator:
		left_elevator.rotation.x = elevator_angle
	if right_elevator:
		right_elevator.rotation.x = elevator_angle

	# Rudder - yaw control
	if rudder:
		rudder.rotation.y = rudder_input * max_deflection

	# Flaps - deploy based on flaps setting
	var flap_angle: float = flaps_input * deg_to_rad(40.0)  # 40 degrees max
	if left_flap:
		left_flap.rotation.x = flap_angle
	if right_flap:
		right_flap.rotation.x = flap_angle

func _break_next_part() -> void:
	if damage_index >= damage_sequence.size():
		print("All parts already destroyed!")
		return

	var part_to_break: String = damage_sequence[damage_index]
	damage_index += 1

	match part_to_break:
		"left_wing":
			_destroy_left_wing()
		"right_wing":
			_destroy_right_wing()
		"horizontal_tail":
			_destroy_horizontal_tail()
		"vertical_tail":
			_destroy_vertical_tail()

func _get_wing_factor() -> float:
	# Returns 0.0 to 1.0 based on wing damage
	var factor := 0.0
	if has_left_wing:
		factor += 0.5
	if has_right_wing:
		factor += 0.5
	return factor

func _get_roll_asymmetry() -> float:
	# Returns roll torque from asymmetric lift (missing one wing)
	if has_left_wing and not has_right_wing:
		return -1.0  # Roll right (missing right wing = less lift on right)
	elif has_right_wing and not has_left_wing:
		return 1.0   # Roll left (missing left wing = less lift on left)
	return 0.0

func _on_body_shape_entered(_body_rid: RID, body: Node, _body_shape_index: int, local_shape_index: int) -> void:
	# Debounce - one collision event per physics frame
	var current_frame := Engine.get_physics_frames()
	if current_frame == _last_damage_frame:
		return

	# Identify which of our shapes was hit
	var owner_id := shape_find_owner(local_shape_index)
	var shape_node: Node = shape_owner_get_owner(owner_id)

	# Wheel contacts: check for hard landing that breaks gear
	if shape_node == front_wheel_col or shape_node == left_wheel_col or shape_node == right_wheel_col:
		var sink_rate: float = absf(linear_velocity.y)
		if sink_rate > gear_break_speed:
			_last_damage_frame = current_frame
			print("Hard landing at %.1f m/s sink rate!" % sink_rate)
			if shape_node == front_wheel_col:
				_break_gear("front")
			elif shape_node == left_wheel_col:
				_break_gear("left")
			elif shape_node == right_wheel_col:
				_break_gear("right")
		return

	# Calculate impact speed
	var impact_speed: float
	if body is StaticBody3D:
		if altitude_agl > 5.0:
			impact_speed = linear_velocity.length()
		else:
			impact_speed = maxf(absf(linear_velocity.y), linear_velocity.length() * 0.4)
		# Landing gear absorbs impact when deployed
		if gear_down and gear_position > 0.85:
			impact_speed = maxf(0.0, impact_speed - 6.0)
	else:
		var relative_vel: Vector3 = linear_velocity
		if body is RigidBody3D:
			relative_vel = linear_velocity - body.linear_velocity
		impact_speed = relative_vel.length()

	if impact_speed <= impact_damage_threshold:
		return

	_last_damage_frame = current_frame
	print("Collision with %s at %.1f m/s impact" % [body.name, impact_speed])

	# If a destructible part was directly hit, destroy that part
	var hit_specific := false
	if shape_node == left_wing_collider and has_left_wing:
		_destroy_left_wing()
		hit_specific = true
	elif shape_node == right_wing_collider and has_right_wing:
		_destroy_right_wing()
		hit_specific = true
	elif shape_node == htail_collider and has_horizontal_tail:
		_destroy_horizontal_tail()
		hit_specific = true
	elif shape_node == vtail_collider and has_vertical_tail:
		_destroy_vertical_tail()
		hit_specific = true

	# Additional random damage for severe impacts or body hits
	var extra_rolls := 0
	if not hit_specific:
		extra_rolls = 1
	if impact_speed > impact_damage_threshold * 2:
		extra_rolls += 1
	if impact_speed > impact_damage_threshold * 3:
		extra_rolls += 1

	for i in extra_rolls:
		_apply_random_damage()

func _apply_random_damage() -> void:
	var intact: Array[String] = []
	if has_left_wing:
		intact.append("left_wing")
	if has_right_wing:
		intact.append("right_wing")
	if has_horizontal_tail:
		intact.append("horizontal_tail")
	if has_vertical_tail:
		intact.append("vertical_tail")
	if intact.is_empty():
		return
	match intact.pick_random():
		"left_wing":
			_destroy_left_wing()
		"right_wing":
			_destroy_right_wing()
		"horizontal_tail":
			_destroy_horizontal_tail()
		"vertical_tail":
			_destroy_vertical_tail()

func _destroy_left_wing() -> void:
	if not has_left_wing:
		return
	has_left_wing = false
	if left_wing_mesh:
		left_wing_mesh.visible = false
	if left_wing_collider:
		left_wing_collider.set_deferred("disabled", true)
	# Also destroy left landing gear
	if landing_gear:
		var left_gear: Node3D = landing_gear.get_node_or_null("LeftGear")
		if left_gear:
			left_gear.visible = false
	if left_wheel_col:
		left_wheel_col.set_deferred("disabled", true)
	print("Left wing destroyed!")

func _destroy_right_wing() -> void:
	if not has_right_wing:
		return
	has_right_wing = false
	if right_wing_mesh:
		right_wing_mesh.visible = false
	if right_wing_collider:
		right_wing_collider.set_deferred("disabled", true)
	# Also destroy right landing gear
	if landing_gear:
		var right_gear: Node3D = landing_gear.get_node_or_null("RightGear")
		if right_gear:
			right_gear.visible = false
	if right_wheel_col:
		right_wheel_col.set_deferred("disabled", true)
	print("Right wing destroyed!")

func _destroy_horizontal_tail() -> void:
	if not has_horizontal_tail:
		return
	has_horizontal_tail = false
	if horizontal_tail_mesh:
		horizontal_tail_mesh.visible = false
	if htail_collider:
		htail_collider.set_deferred("disabled", true)
	print("Horizontal tail destroyed!")

func _destroy_vertical_tail() -> void:
	if not has_vertical_tail:
		return
	has_vertical_tail = false
	if vertical_tail_mesh:
		vertical_tail_mesh.visible = false
	if vtail_collider:
		vtail_collider.set_deferred("disabled", true)
	print("Vertical tail destroyed!")

func _break_gear(which: String) -> void:
	var gear_node: Node3D = null
	if which == "front" and has_front_gear:
		has_front_gear = false
		if front_wheel_col:
			front_wheel_col.set_deferred("disabled", true)
		gear_node = landing_gear.get_node_or_null("FrontGear") if landing_gear else null
	elif which == "left" and has_left_gear:
		has_left_gear = false
		if left_wheel_col:
			left_wheel_col.set_deferred("disabled", true)
		gear_node = landing_gear.get_node_or_null("LeftGear") if landing_gear else null
	elif which == "right" and has_right_gear:
		has_right_gear = false
		if right_wheel_col:
			right_wheel_col.set_deferred("disabled", true)
		gear_node = landing_gear.get_node_or_null("RightGear") if landing_gear else null
	else:
		return
	if gear_node:
		gear_node.visible = false
	print("%s gear collapsed!" % which.capitalize())

# === MISSILES ===

func _spawn_missiles() -> void:
	for i in hardpoint_positions.size():
		var missile: Missile = MISSILE_SCENE.instantiate()
		missile.position = hardpoint_positions[i]
		missile.state = Missile.State.ATTACHED
		add_child(missile)
		missiles.append(missile)

func fire_missile() -> void:
	if missiles.is_empty():
		print("No missiles remaining!")
		return

	# Find next available missile, alternating sides
	var attempts := missiles.size()
	while attempts > 0:
		if next_missile_index >= missiles.size():
			next_missile_index = 0
		var missile: Missile = missiles[next_missile_index]
		next_missile_index += 1
		attempts -= 1

		if not is_instance_valid(missile) or missile.state != Missile.State.ATTACHED:
			continue

		# Check if the wing this missile is on still exists
		if missile.position.x < 0 and not has_left_wing:
			continue
		if missile.position.x > 0 and not has_right_wing:
			continue

		# Reparent to scene root so it's independent
		var global_pos := missile.global_position
		var global_rot := missile.global_transform.basis
		remove_child(missile)
		get_tree().current_scene.add_child(missile)
		missile.global_position = global_pos
		missile.global_transform.basis = global_rot

		# Launch with aircraft's current velocity, exclude self from collision
		missile.launch(linear_velocity, self)
		print("Missile fired!")
		return

	print("No missiles available!")
