extends Vehicle
class_name Jet

## Jet aircraft with high-thrust turbine engine and swept wing aerodynamics

# Wing properties
@export_group("Wing Configuration")
@export var wing_area: float = 20.0       # m² (larger for swept wings)
@export var wing_span: float = 9.0        # meters
@export var aspect_ratio: float = 4.0     # lower for swept wings

# Aerodynamic coefficients
@export_group("Aerodynamics")
@export var cl_0: float = 0.28            # Lift coefficient at zero AoA (wing incidence)
@export var cl_alpha: float = 2.5         # Lift curve slope (per radian) - lower for swept wings
@export var cl_max: float = 1.2           # Maximum lift coefficient
@export var stall_angle: float = 18.0     # degrees (higher for swept wings)
@export var cd_0: float = 0.035           # Parasitic drag (sleeker than prop)
@export var oswald_efficiency: float = 0.7

# Control surface authority
@export_group("Control Surfaces")
@export var elevator_authority: float = 22000.0   # Higher for jet
@export var aileron_authority: float = 14000.0
@export var rudder_authority: float = 4000.0

# Engine
@export_group("Engine")
@export var max_thrust: float = 26000.0    # Newtons dry (T/W ~0.88)
@export var afterburner_thrust: float = 38000.0  # With afterburner (T/W ~1.29)
@export var throttle_response: float = 1.2 # Jet spools up
@export var afterburner_active := false

# Stability
@export_group("Stability")
@export var pitch_stability: float = 0.2
@export var roll_stability: float = 0.2
@export var yaw_stability: float = 0.5
@export var angular_damping: float = 1.2

# Ground effect
@export_group("Ground Effect")
@export var ground_effect_height: float = 8.0
@export var ground_effect_max_bonus: float = 0.25  # 25% extra lift at ground level (realistic)

# Flaps
@export_group("Flaps")
@export var flaps_cl_bonus: float = 0.4
@export var flaps_cd_penalty: float = 0.12
@export var flaps_response: float = 0.5
var flaps_input: float = 0.0

# Landing gear
@export_group("Landing Gear")
@export var nosewheel_steer_angle: float = 40.0
@export var brake_force: float = 30000.0

# Damage
@export_group("Damage")
@export var impact_damage_threshold: float = 25.0
@export var gear_break_speed: float = 8.0          # m/s vertical speed to collapse gear

# State
var throttle: float = 0.0
var elevator_input: float = 0.0
var aileron_input: float = 0.0
var rudder_input: float = 0.0
var is_stalled := false
var current_cl: float = 0.0
var current_cd: float = 0.0
var ground_effect_factor: float = 0.0
var gear_down := true
var gear_position: float = 1.0
var nosewheel_current_angle: float = 0.0
var _last_damage_frame: int = -1

# Missiles
var missiles: Array[Missile] = []
var next_missile_index: int = 0
const MISSILE_SCENE := preload("res://scenes/vehicles/missile.tscn")
var hardpoint_positions: Array[Vector3] = [
	Vector3(-1.8, -0.3, 1.0),   # Left wing
	Vector3(1.8, -0.3, 1.0),    # Right wing
]

# Gun
var gun: AircraftGun
var gun_firing := false

# Damage state
var has_left_wing := true
var has_right_wing := true
var has_horizontal_tail := true
var has_vertical_tail := true
var has_front_gear := true
var has_left_gear := true
var has_right_gear := true
var damage_sequence := ["left_wing", "right_wing", "horizontal_tail", "vertical_tail"]
var damage_index := 0

const AIR_DENSITY: float = 1.225

@onready var exhaust: MeshInstance3D = $Exhaust
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
@onready var left_elevator: MeshInstance3D = $HorizontalTail/LeftElevator
@onready var right_elevator: MeshInstance3D = $HorizontalTail/RightElevator
@onready var rudder_mesh: MeshInstance3D = $VerticalTail/Rudder

func _ready() -> void:
	super._ready()
	mass = 3000.0  # heavier than prop plane
	requires_startup = true
	engine_running = false

	if landing_gear:
		for gear_node in landing_gear.get_children():
			gear_node.visible = true

	contact_monitor = true
	max_contacts_reported = 4
	body_shape_entered.connect(_on_body_shape_entered)

	# Spawn missiles at hardpoints
	_spawn_missiles()

	# Create nose gun
	gun = AircraftGun.new()
	gun.position = Vector3(0, -0.1, -10.5)  # Under nose
	add_child(gun)

func _input(event: InputEvent) -> void:
	if not is_occupied:
		return

	if event.is_action_pressed("toggle_gear"):
		if not gear_down and altitude_agl < 1.5 and gear_position < 0.5:
			print("Cannot extend gear - not enough ground clearance!")
		else:
			gear_down = not gear_down
			print("Gear toggled: ", gear_down)

	if event is InputEventKey and event.pressed and event.keycode == KEY_J:
		_break_next_part()

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
		elif event.keycode == KEY_B:
			afterburner_active = not afterburner_active
			print("Afterburner: ", "ON" if afterburner_active else "OFF")
	# Gun release
	if event is InputEventKey and not event.pressed:
		if event.keycode == KEY_G:
			gun_firing = false

func _physics_process(delta: float) -> void:
	_update_wheel_colliders()
	super._physics_process(delta)

func _process(delta: float) -> void:
	super._process(delta)
	# Animate exhaust glow based on throttle
	if exhaust:
		var exhaust_mat: StandardMaterial3D = exhaust.get_surface_override_material(0)
		if exhaust_mat:
			var intensity := throttle * 2.0
			if afterburner_active and throttle > 0.5:
				intensity *= 1.5
			exhaust_mat.emission_energy_multiplier = intensity

	# Gun firing
	if gun_firing and is_occupied and gun:
		var muzzle := gun.global_position
		var forward := -global_transform.basis.z
		gun.fire(muzzle, forward, linear_velocity)

	# Landing gear animation
	var target_gear: float = 1.0 if gear_down else 0.0
	gear_position = move_toward(gear_position, target_gear, delta * 0.5)
	_animate_landing_gear(delta)
	_animate_control_surfaces()

func _animate_landing_gear(delta: float) -> void:
	if not landing_gear:
		return

	var front_progress: float = clamp(gear_position * 1.2, 0.0, 1.0)
	var main_progress: float = gear_position

	var front_retract_angle: float = (1.0 - front_progress) * PI / 2.0
	var main_retract_angle: float = (1.0 - main_progress) * PI / 2.0

	var front_gear: Node3D = landing_gear.get_node_or_null("FrontGear")
	var left_gear: Node3D = landing_gear.get_node_or_null("LeftGear")
	var right_gear: Node3D = landing_gear.get_node_or_null("RightGear")

	if front_gear:
		var target_steer: float = 0.0
		if gear_position > 0.85 and is_occupied:
			target_steer = rudder_input * deg_to_rad(nosewheel_steer_angle)
		var steer_speed: float = 3.0
		nosewheel_current_angle = move_toward(nosewheel_current_angle, target_steer, steer_speed * delta)
		front_gear.rotation = Vector3(front_retract_angle, nosewheel_current_angle, 0.0)

	if left_gear:
		left_gear.rotation.x = -main_retract_angle
	if right_gear:
		right_gear.rotation.x = -main_retract_angle

func _process_inputs(delta: float) -> void:
	# Throttle (requires engine running)
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

	# Elevator (pitch): mouse Y + W/S keys
	elevator_input = -mouse_input.y
	if Input.is_action_pressed("collective_up"):
		elevator_input -= 0.6  # W = pitch down
	if Input.is_action_pressed("collective_down"):
		elevator_input += 0.6  # S = pitch up
	elevator_input = clamp(elevator_input, -1.0, 1.0)

	# Ailerons (roll): mouse X + A/D
	aileron_input = mouse_input.x
	aileron_input += Input.get_axis("move_left", "move_right") * 0.5
	aileron_input = clamp(aileron_input, -1.0, 1.0)

	# Rudder: Q/E — limit deflection at high speed
	var raw_rudder := -Input.get_axis("yaw_left", "yaw_right")
	var rudder_limit: float = clampf(lerpf(1.0, 0.15, airspeed / 100.0), 0.15, 1.0)
	rudder_input = raw_rudder * rudder_limit

	input_pitch = elevator_input
	input_roll = aileron_input
	input_yaw = rudder_input

func _apply_flight_physics(delta: float) -> void:
	clear_debug_forces()

	var forward := -global_transform.basis.z
	var up := global_transform.basis.y
	var right := global_transform.basis.x

	angle_of_attack = calculate_aoa()

	# === LIFT ===
	current_cl = _calculate_lift_coefficient(angle_of_attack)
	current_cl += flaps_input * flaps_cl_bonus

	var dynamic_pressure: float = 0.5 * AIR_DENSITY * airspeed * airspeed
	var lift_magnitude: float = dynamic_pressure * wing_area * current_cl

	var wing_factor: float = _get_wing_factor()
	lift_magnitude *= wing_factor

	ground_effect_factor = _calculate_ground_effect()
	lift_magnitude *= (1.0 + ground_effect_factor)

	var lift_direction: Vector3 = Vector3.UP
	if airspeed > 1.0:
		var velocity_dir: Vector3 = linear_velocity.normalized()
		lift_direction = velocity_dir.cross(right).normalized()
		if lift_direction.dot(up) < 0:
			lift_direction = -lift_direction

	var lift_force: Vector3 = lift_direction * lift_magnitude
	apply_central_force(lift_force)
	add_debug_force("lift", lift_force, Color.RED)

	# Asymmetric wing damage
	var roll_asymmetry: float = _get_roll_asymmetry()
	if absf(roll_asymmetry) > 0.01 and airspeed > 5.0:
		apply_torque(forward * roll_asymmetry * lift_magnitude * 0.8)
		apply_torque(up * roll_asymmetry * dynamic_pressure * 50.0)

	if ground_effect_factor > 0.01:
		add_debug_force("ground_fx", Vector3.UP * ground_effect_factor * 10000, Color.CYAN)

	# === DRAG ===
	var induced_drag_coef: float = (current_cl * current_cl) / (PI * oswald_efficiency * aspect_ratio)
	current_cd = cd_0 + induced_drag_coef
	current_cd += flaps_input * flaps_cd_penalty

	# High AoA form drag - wing presents more cross-section to airflow
	var aoa_rad_abs := deg_to_rad(absf(angle_of_attack))
	var form_drag := sin(aoa_rad_abs)
	current_cd += 0.25 * form_drag * form_drag

	# Post-stall drag penalty
	if is_stalled:
		current_cd += 0.15 * (absf(angle_of_attack) - stall_angle) / 10.0

	var drag_magnitude: float = dynamic_pressure * wing_area * current_cd
	var drag_force: Vector3 = Vector3.ZERO
	if airspeed > 0.1:
		drag_force = -linear_velocity.normalized() * drag_magnitude
	apply_central_force(drag_force)
	add_debug_force("drag", drag_force, Color.GREEN)

	# === THRUST ===
	var current_max_thrust: float = afterburner_thrust if afterburner_active else max_thrust
	var thrust_force: Vector3 = forward * current_max_thrust * throttle
	apply_central_force(thrust_force)
	add_debug_force("thrust", thrust_force, Color.BLUE)

	# === STALL PITCH-DOWN MOMENT ===
	var abs_aoa := absf(angle_of_attack)
	if abs_aoa > stall_angle and airspeed > 5.0:
		var stall_excess: float = clampf((abs_aoa - stall_angle) / 20.0, 0.0, 1.0)
		var pitch_down_torque: float = -signf(angle_of_attack) * stall_excess * dynamic_pressure * wing_area * 0.025
		apply_torque(right * pitch_down_torque)

	# === CONTROL SURFACES ===
	# Need ~55 m/s for full authority; very little control at low speed
	var control_effectiveness: float = clamp(dynamic_pressure / 2000.0, 0.08, 1.0)

	# Reduce control effectiveness in stall
	if abs_aoa > stall_angle:
		var stall_penalty: float = clamp((abs_aoa - stall_angle) / 25.0, 0.0, 0.4)
		control_effectiveness *= (1.0 - stall_penalty)

	if has_horizontal_tail:
		var pitch_torque: Vector3 = right * elevator_input * elevator_authority * control_effectiveness
		apply_torque(pitch_torque)

	var aileron_effectiveness: float = wing_factor
	var roll_torque: Vector3 = forward * aileron_input * aileron_authority * control_effectiveness * aileron_effectiveness
	apply_torque(roll_torque)

	if has_vertical_tail:
		var yaw_torque: Vector3 = up * rudder_input * rudder_authority * control_effectiveness
		apply_torque(yaw_torque)

	# === SIDESLIP SIDE FORCE ===
	var local_vel := get_local_velocity()
	if airspeed > 5.0:
		var sideslip := atan2(local_vel.x, -local_vel.z)
		var side_force := -right * sideslip * dynamic_pressure * wing_area * 0.15
		apply_central_force(side_force)

	# === MANEUVERING DRAG ===
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

	if airspeed > 1.0:
		add_debug_force("velocity", linear_velocity * 100, Color.YELLOW)

func _calculate_lift_coefficient(aoa: float) -> float:
	var aoa_rad := deg_to_rad(aoa)

	if absf(aoa) < stall_angle:
		is_stalled = false
		var cl := cl_0 + cl_alpha * aoa_rad
		return clamp(cl, -cl_max, cl_max)

	is_stalled = true
	var stall_rad: float = deg_to_rad(stall_angle)
	var post_stall_aoa: float = absf(aoa) - stall_angle
	var stall_cl: float = cl_0 + cl_alpha * stall_rad * sign(aoa)
	var dropoff: float = 1.0 - (post_stall_aoa / 30.0)
	dropoff = clamp(dropoff, 0.3, 1.0)
	return stall_cl * dropoff

func _apply_stability(_delta: float, up: Vector3, forward: Vector3, right: Vector3) -> void:
	if has_vertical_tail:
		var local_vel: Vector3 = get_local_velocity()
		if local_vel.length() > 5.0:
			var sideslip: float = atan2(local_vel.x, -local_vel.z)
			apply_torque(-up * sideslip * yaw_stability * mass)

	if has_horizontal_tail:
		var forward_horizontal: Vector3 = Vector3(forward.x, 0, forward.z).normalized()
		var pitch_angle: float = forward.angle_to(forward_horizontal) if forward_horizontal.length() > 0.01 else 0.0
		if forward.y < 0:
			pitch_angle = -pitch_angle
		# Only apply when controls centered AND not in a sustained maneuver
		if absf(elevator_input) < 0.1 and absf(angular_velocity.dot(right)) < 0.3:
			var pitch_factor := clampf(1.0 - absf(pitch_angle) / 1.0, 0.0, 1.0)
			apply_torque(right * (-pitch_angle * pitch_stability * mass * 0.05 * pitch_factor))

	var wing_factor: float = _get_wing_factor()
	var roll_angle: float = up.signed_angle_to(Vector3.UP, forward)
	if absf(aileron_input) < 0.1:
		apply_torque(forward * (-roll_angle * roll_stability * mass * 0.05 * wing_factor))

func _calculate_ground_effect() -> float:
	if altitude_agl > ground_effect_height:
		return 0.0
	var effect_ratio: float = 1.0 - (altitude_agl / ground_effect_height)
	return ground_effect_max_bonus * effect_ratio * effect_ratio

func _update_wheel_colliders() -> void:
	var gear_deployed: bool = gear_position >= 0.85
	if front_wheel_col:
		front_wheel_col.set_deferred("disabled", not (gear_deployed and has_front_gear))
	if left_wheel_col:
		left_wheel_col.set_deferred("disabled", not (gear_deployed and has_left_gear and has_left_wing))
	if right_wheel_col:
		right_wheel_col.set_deferred("disabled", not (gear_deployed and has_right_gear and has_right_wing))

func _apply_ground_forces(_delta: float) -> void:
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

	if throttle < 0.01 and airspeed > 0.5:
		var forward_speed: float = linear_velocity.dot(forward)
		var brake_magnitude: float = brake_force * clamp(absf(forward_speed) / 5.0, 0.0, 1.0)
		var brake_vector: Vector3 = -forward * sign(forward_speed) * brake_magnitude
		apply_central_force(brake_vector)

func _on_debug_toggled() -> void:
	if debug_draw:
		debug_draw.visible = debug_enabled

func _animate_control_surfaces() -> void:
	var max_deflection: float = deg_to_rad(25.0)

	if left_aileron:
		left_aileron.rotation.x = -aileron_input * max_deflection
	if right_aileron:
		right_aileron.rotation.x = aileron_input * max_deflection

	var elevator_angle: float = elevator_input * max_deflection
	if left_elevator:
		left_elevator.rotation.x = elevator_angle
	if right_elevator:
		right_elevator.rotation.x = elevator_angle

	if rudder_mesh:
		rudder_mesh.rotation.y = rudder_input * max_deflection

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
	var factor := 0.0
	if has_left_wing:
		factor += 0.5
	if has_right_wing:
		factor += 0.5
	return factor

func _get_roll_asymmetry() -> float:
	if has_left_wing and not has_right_wing:
		return -1.0
	elif has_right_wing and not has_left_wing:
		return 1.0
	return 0.0

func _on_body_shape_entered(_body_rid: RID, body: Node, _body_shape_index: int, local_shape_index: int) -> void:
	var current_frame := Engine.get_physics_frames()
	if current_frame == _last_damage_frame:
		return

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

	var attempts := missiles.size()
	while attempts > 0:
		if next_missile_index >= missiles.size():
			next_missile_index = 0
		var missile: Missile = missiles[next_missile_index]
		next_missile_index += 1
		attempts -= 1

		if not is_instance_valid(missile) or missile.state != Missile.State.ATTACHED:
			continue

		if missile.position.x < 0 and not has_left_wing:
			continue
		if missile.position.x > 0 and not has_right_wing:
			continue

		var global_pos := missile.global_position
		var global_rot := missile.global_transform.basis
		remove_child(missile)
		get_tree().current_scene.add_child(missile)
		missile.global_position = global_pos
		missile.global_transform.basis = global_rot

		missile.launch(linear_velocity, self)
		print("Missile fired!")
		return

	print("No missiles available!")
