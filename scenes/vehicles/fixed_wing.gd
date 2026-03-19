extends Vehicle
class_name FixedWing

## Fixed-wing aircraft with realistic aerodynamic flight model
## Features: lift/drag curves, stall, control surfaces, engine thrust

# Wing properties
@export_group("Wing Configuration")
@export var wing_area: float = 20.0       # m²
@export var wing_span: float = 10.0       # meters
@export var aspect_ratio: float = 6.25    # span² / area

# Aerodynamic coefficients
@export_group("Aerodynamics")
@export var cl_0: float = 0.45            # Lift coefficient at zero AoA
@export var cl_alpha: float = 3.4         # Lift curve slope (per radian) - finite wing correction
@export var cl_max: float = 1.8           # Maximum lift coefficient (clean wing)
@export var stall_angle: float = 15.0     # degrees
@export var cd_0: float = 0.05            # Parasitic drag coefficient (increased)
@export var oswald_efficiency: float = 0.75 # Oswald span efficiency

# Control surface authority
@export_group("Control Surfaces")
@export var elevator_authority: float = 26000.0  # Pitch torque
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
var _last_damage_time: float = -1.0
var _part_damage_time: Dictionary = {}  # shape node -> last hit time
const BODY_DAMAGE_COOLDOWN := 0.15      # seconds between body collision events
const PART_DAMAGE_COOLDOWN := 0.3       # seconds before the same part can be hit again
const PART_IMPACT_THRESHOLD := 6.0     # m/s to destroy a wing/tail (much lower than body threshold)

# Missiles
var missiles: Array[Missile] = []
var next_missile_index: int = 0
const MISSILE_SCENE := preload("res://scenes/vehicles/missile.tscn")
var hardpoint_positions: Array[Vector3] = [
	Vector3(-1.5, -0.3, 0.2),   # Left inner
	Vector3(1.5, -0.3, 0.2),    # Right inner
	Vector3(-3.0, -0.3, 0.5),   # Left mid
	Vector3(3.0, -0.3, 0.5),    # Right mid
	Vector3(-4.2, -0.3, 0.9),   # Left outer
	Vector3(4.2, -0.3, 0.9),    # Right outer
]

# Gun
var gun: AircraftGun
var gun_firing := false

# Weapon system
enum WeaponMode { GUNS, MISSILES, LASER, BOMBS }
var current_weapon: WeaponMode = WeaponMode.MISSILES
var bombs_remaining: int = 4
var countermeasures: int = 30
var laser_target: Node3D = null
var lock_progress: float = 0.0   # 0 = no lock, 1.0 = full lock
var laser_spot_pos: Vector3 = Vector3.ZERO
var laser_spot_active := false
var laser_camera_active := false
var laser_camera_node: Camera3D = null   # direct child, belly-mounted FLIR
var _laser_cam_yaw: float = 0.0
var _laser_cam_pitch: float = 0.0

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

	# Register as aircraft for HUD polling
	add_to_group("aircraft")

	# Set up laser/FLIR belly camera
	_setup_laser_camera()

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

	# Flaps: scroll wheel (no modifier — Ctrl+scroll is eaten by macOS system zoom)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			flaps_input = clamp(flaps_input + 0.25, 0.0, 1.0)
			print("Flaps: %.0f%%" % (flaps_input * 100))
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			flaps_input = clamp(flaps_input - 0.25, 0.0, 1.0)
			print("Flaps: %.0f%%" % (flaps_input * 100))
			get_viewport().set_input_as_handled()

	# Left click: fire current weapon (all views)
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.alt_pressed:
		if event.pressed:
			var _cockpit := get_node_or_null("Cockpit")
			if _cockpit and _cockpit.handle_cockpit_click():
				get_viewport().set_input_as_handled()
				return
			match current_weapon:
				WeaponMode.MISSILES:
					if lock_progress >= 1.0:
						fire_missile()
					else:
						print("Not locked! (%.0f%%)" % (lock_progress * 100))
				WeaponMode.BOMBS:
					_drop_bomb()
				WeaponMode.LASER:
					_laser_designate()
				WeaponMode.GUNS:
					gun_firing = true
		else:
			gun_firing = false
		get_viewport().set_input_as_handled()

	# Laser camera: Ctrl + Right-click → toggle sensor view
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT \
			and event.pressed and event.ctrl_pressed:
		if laser_camera_active:
			_deactivate_laser_view()
		else:
			_activate_laser_view()
		get_viewport().set_input_as_handled()

	# Laser camera aiming: mouse drag while sensor view is active
	if event is InputEventMouseMotion and laser_camera_active:
		const LASER_CAM_SENSITIVITY := 0.004
		_laser_cam_yaw -= event.relative.x * LASER_CAM_SENSITIVITY
		_laser_cam_pitch -= event.relative.y * LASER_CAM_SENSITIVITY
		_laser_cam_yaw = clampf(_laser_cam_yaw, -PI * 0.45, PI * 0.45)
		_laser_cam_pitch = clampf(_laser_cam_pitch, -PI * 0.35, PI * 0.35)
		if laser_camera_node:
			laser_camera_node.rotation = Vector3(-PI / 2.0 + _laser_cam_pitch, _laser_cam_yaw, 0.0)
		get_viewport().set_input_as_handled()

	if event is InputEventKey and event.pressed and not event.is_echo():
		match event.keycode:
			KEY_F:
				_cycle_weapon()
			KEY_R:
				_cycle_target()
			KEY_T:
				if event.alt_pressed:
					_lock_nearest_target()
				else:
					_laser_designate()
			KEY_C:
				_deploy_countermeasures()

func _physics_process(delta: float) -> void:
	_update_wheel_colliders()
	super._physics_process(delta)

func _process(delta: float) -> void:
	super._process(delta)

	# Progressive missile lock-on: target must stay near nose cone
	if laser_target and is_instance_valid(laser_target):
		var to_tgt := (laser_target.global_position - global_position).normalized()
		var in_cone := (-global_transform.basis.z).dot(to_tgt) > 0.5   # ~60° half-angle
		var in_range := global_position.distance_to(laser_target.global_position) < 15000.0
		if in_cone and in_range:
			lock_progress = minf(lock_progress + 0.18 * delta, 1.0)  # ~5.5 sec to full lock
		else:
			lock_progress = maxf(lock_progress - 0.5 * delta, 0.0)
	else:
		laser_target = null
		lock_progress = maxf(lock_progress - 0.5 * delta, 0.0)

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
	if not has_left_wing and not has_right_wing \
			and not has_horizontal_tail and not has_vertical_tail:
		# Still damp rotation so the fuselage tumbles realistically; leave linear alone
		apply_torque(-angular_velocity * angular_damping * mass)
		return

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
	# Full lift magnitude — wing damage is handled per-wing below, not by pre-scaling
	var lift_magnitude: float = dynamic_pressure * wing_area * current_cl

	# Ground effect - increases lift when close to ground
	ground_effect_factor = _calculate_ground_effect()
	lift_magnitude *= (1.0 + ground_effect_factor)

	var wing_factor: float = _get_wing_factor()  # still needed for aileron effectiveness

	# Lift acts perpendicular to velocity, in the plane of the wing
	var lift_direction: Vector3 = Vector3.UP
	if airspeed > 1.0:
		var velocity_dir: Vector3 = linear_velocity.normalized()
		lift_direction = velocity_dir.cross(right).normalized()
		if lift_direction.dot(up) < 0:
			lift_direction = -lift_direction

	# Per-wing lift: each intact wing contributes half.
	# Aileron down (rolling right) increases that wing's effective camber → more lift on right, less on left.
	const FLAPERON_CL: float = 0.06
	var lift_left: float = lift_magnitude * 0.5 * (1.0 - aileron_input * FLAPERON_CL) if has_left_wing else 0.0
	var lift_right: float = lift_magnitude * 0.5 * (1.0 + aileron_input * FLAPERON_CL) if has_right_wing else 0.0
	apply_central_force(lift_direction * (lift_left + lift_right))
	add_debug_force("lift_l", lift_direction * lift_left, Color(1.0, 0.2, 0.2))
	add_debug_force("lift_r", lift_direction * lift_right, Color(1.0, 0.55, 0.1))

	# Roll torque from asymmetry: surviving wing lifts that side
	# -Z torque with positive net_asymmetry (right dominant) → left goes up → bank right
	var half_span: float = wing_span * 0.06  # reduced so one-wing roll is heavy but survivable
	if has_left_wing != has_right_wing and airspeed > 5.0:
		var net_asymmetry: float = lift_right - lift_left  # +ve = right wing dominant
		apply_torque(-global_transform.basis.z * net_asymmetry * half_span)
		# Asymmetric induced drag yaws toward the remaining wing
		var yaw_sign := 1.0 if has_right_wing else -1.0
		apply_torque(up * yaw_sign * dynamic_pressure * 12.0)

	if ground_effect_factor > 0.01:
		add_debug_force("ground_fx", Vector3.UP * ground_effect_factor * 10000, Color.CYAN)

	# === DRAG ===
	# Parasitic + Induced drag
	var induced_drag_coef: float = (current_cl * current_cl) / (PI * oswald_efficiency * aspect_ratio)
	current_cd = cd_0 + induced_drag_coef

	# Flaps add drag
	current_cd += flaps_input * flaps_cd_penalty
	# Landing gear drag
	if gear_down and gear_position > 0.5:
		current_cd += 0.12 * gear_position

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
		var pitch_down_torque: float = -signf(angle_of_attack) * stall_excess * dynamic_pressure * wing_area * 0.25
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
	# Back off pitch/roll stability when actively maneuvering — prevents fighting aerobatics
	var ang_rate: float = angular_velocity.length()
	var maneuver_scale: float = clampf(1.0 - ang_rate / 1.2, 0.0, 1.0)

	# Tails provide full stability; fuselage/CG provides 20% residual when tail is gone
	var vtail_factor: float = 1.0 if has_vertical_tail else 0.2
	var htail_factor: float = 1.0 if has_horizontal_tail else 0.2

	# Weathervane stability — suppressed only while rudder is actively pressed
	var local_vel: Vector3 = get_local_velocity()
	if local_vel.length() > 5.0:
		var sideslip: float = atan2(local_vel.x, -local_vel.z)
		var yaw_scale := clampf(1.0 - absf(rudder_input) / 0.15, 0.0, 1.0)
		apply_torque(-up * sideslip * yaw_stability * mass * yaw_scale * vtail_factor)

	# Pitch stability — only when near-level and controls centred
	var forward_horizontal: Vector3 = Vector3(forward.x, 0, forward.z).normalized()
	var pitch_angle: float = forward.angle_to(forward_horizontal) if forward_horizontal.length() > 0.01 else 0.0
	if forward.y < 0:
		pitch_angle = -pitch_angle
	if absf(elevator_input) < 0.1 and absf(angular_velocity.dot(right)) < 0.3:
		var pitch_factor := clampf(1.0 - absf(pitch_angle) / 1.0, 0.0, 1.0)
		apply_torque(right * (-pitch_angle * pitch_stability * mass * 0.05 * pitch_factor * maneuver_scale * htail_factor))

	# Roll stability — back off as roll rate increases to allow smooth barrel rolls
	var wing_factor: float = _get_wing_factor()
	var roll_rate: float = absf(angular_velocity.dot(forward))
	var roll_damp: float = clampf(1.0 - roll_rate / 0.8, 0.0, 1.0)
	if absf(aileron_input) < 0.1:
		var roll_angle: float = up.signed_angle_to(Vector3.UP, forward)
		apply_torque(forward * (-roll_angle * roll_stability * mass * 0.05 * wing_factor * roll_damp))

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

	var fwd := -global_transform.basis.z
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
		var forward_speed: float = linear_velocity.dot(fwd)
		var brake_magnitude: float = brake_force * clamp(absf(forward_speed) / 5.0, 0.0, 1.0)
		var brake_vector: Vector3 = -fwd * sign(forward_speed) * brake_magnitude
		apply_central_force(brake_vector)

func _on_debug_toggled() -> void:
	if debug_draw:
		debug_draw.visible = debug_enabled

func _animate_control_surfaces() -> void:
	var max_deflection: float = deg_to_rad(25.0)  # 25 degrees max deflection

	# Flaperons: ailerons deflect for roll AND droop down symmetrically with flap input
	var flaperon_droop: float = flaps_input * deg_to_rad(15.0)
	if left_aileron:
		left_aileron.rotation.x = (-aileron_input * max_deflection) + flaperon_droop
	if right_aileron:
		right_aileron.rotation.x = (aileron_input * max_deflection) + flaperon_droop

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
	var now := Time.get_ticks_msec() / 1000.0

	var owner_id := shape_find_owner(local_shape_index)
	var shape_node: Node = shape_owner_get_owner(owner_id)

	# Wheel contacts: check for hard landing that breaks gear
	if shape_node == front_wheel_col or shape_node == left_wheel_col or shape_node == right_wheel_col:
		var sink_rate: float = absf(linear_velocity.y)
		if sink_rate > gear_break_speed:
			print("Hard landing at %.1f m/s sink rate!" % sink_rate)
			if shape_node == front_wheel_col:
				_break_gear("front")
			elif shape_node == left_wheel_col:
				_break_gear("left")
			elif shape_node == right_wheel_col:
				_break_gear("right")
		return

	# Part colliders (wings, tails) — per-shape cooldown, full velocity, low threshold
	var is_part := shape_node == left_wing_collider or shape_node == right_wing_collider \
		or shape_node == htail_collider or shape_node == vtail_collider
	if is_part:
		var last_hit: float = _part_damage_time.get(shape_node, -1.0)
		if now - last_hit < PART_DAMAGE_COOLDOWN:
			return
		# Use full velocity regardless of altitude — clipping a wingtip at any speed counts
		var rel_speed := linear_velocity.length()
		if body is RigidBody3D:
			rel_speed = (linear_velocity - body.linear_velocity).length()
		if rel_speed < PART_IMPACT_THRESHOLD:
			return
		_part_damage_time[shape_node] = now
		print("Part hit: %s at %.1f m/s" % [shape_node.name, rel_speed])
		if shape_node == left_wing_collider and has_left_wing:
			_destroy_left_wing()
		elif shape_node == right_wing_collider and has_right_wing:
			_destroy_right_wing()
		elif shape_node == htail_collider and has_horizontal_tail:
			_destroy_horizontal_tail()
		elif shape_node == vtail_collider and has_vertical_tail:
			_destroy_vertical_tail()
		return

	# Body collision — global cooldown
	if now - _last_damage_time < BODY_DAMAGE_COOLDOWN:
		return

	var impact_speed: float
	if body is StaticBody3D:
		if altitude_agl > 5.0:
			impact_speed = linear_velocity.length()
		else:
			impact_speed = maxf(absf(linear_velocity.y), linear_velocity.length() * 0.4)
		if gear_down and gear_position > 0.85:
			impact_speed = maxf(0.0, impact_speed - 6.0)
	else:
		var relative_vel: Vector3 = linear_velocity
		if body is RigidBody3D:
			relative_vel = linear_velocity - body.linear_velocity
		impact_speed = relative_vel.length()

	if impact_speed <= impact_damage_threshold:
		return

	_last_damage_time = now
	print("Collision with %s at %.1f m/s impact" % [body.name, impact_speed])

	var extra_rolls := 1
	if impact_speed > impact_damage_threshold * 2:
		extra_rolls += 1
	if impact_speed > impact_damage_threshold * 3:
		extra_rolls += 1

	for i in extra_rolls:
		_apply_random_damage()

func take_hit(_blast_pos: Vector3 = Vector3.ZERO) -> void:
	_apply_random_damage()

func take_missile_damage(blast_pos: Vector3) -> void:
	var b := global_transform.basis
	var c := global_position
	var parts := [
		["left_wing",       c + b.x * -2.5],
		["right_wing",      c + b.x * 2.5],
		["horizontal_tail", c + b.z * 3.5],
		["vertical_tail",   c + b.z * 3.5 + b.y * 0.5],
	]
	# Sort by proximity to blast so closest parts go first
	parts.sort_custom(func(a, bb): return (a[1] as Vector3).distance_to(blast_pos) < (bb[1] as Vector3).distance_to(blast_pos))
	var destroyed := 0
	for entry in parts:
		if destroyed >= 2:
			break
		var dist: float = (entry[1] as Vector3).distance_to(blast_pos)
		if destroyed == 0 or dist < 12.0:
			match entry[0]:
				"left_wing":       _destroy_left_wing()
				"right_wing":      _destroy_right_wing()
				"horizontal_tail": _destroy_horizontal_tail()
				"vertical_tail":   _destroy_vertical_tail()
			destroyed += 1

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
		for m in missiles:
			if is_instance_valid(m) and m.get_parent() == left_wing_mesh \
					and m.state == Missile.State.ATTACHED:
				m.visible = false
		spawn_debris(left_wing_mesh, 100.0)
		left_wing_mesh = null
	if left_wing_collider:
		left_wing_collider.set_deferred("disabled", true)
	if landing_gear:
		var left_gear: Node3D = landing_gear.get_node_or_null("LeftGear")
		if left_gear:
			spawn_debris(left_gear, 20.0)
	if left_wheel_col:
		left_wheel_col.set_deferred("disabled", true)
	print("Left wing destroyed!")

func _destroy_right_wing() -> void:
	if not has_right_wing:
		return
	has_right_wing = false
	if right_wing_mesh:
		for m in missiles:
			if is_instance_valid(m) and m.get_parent() == right_wing_mesh \
					and m.state == Missile.State.ATTACHED:
				m.visible = false
		spawn_debris(right_wing_mesh, 100.0)
		right_wing_mesh = null
	if right_wing_collider:
		right_wing_collider.set_deferred("disabled", true)
	if landing_gear:
		var right_gear: Node3D = landing_gear.get_node_or_null("RightGear")
		if right_gear:
			spawn_debris(right_gear, 20.0)
	if right_wheel_col:
		right_wheel_col.set_deferred("disabled", true)
	print("Right wing destroyed!")

func _destroy_horizontal_tail() -> void:
	if not has_horizontal_tail:
		return
	has_horizontal_tail = false
	if horizontal_tail_mesh:
		spawn_debris(horizontal_tail_mesh, 40.0)
		horizontal_tail_mesh = null
	if htail_collider:
		htail_collider.set_deferred("disabled", true)
	print("Horizontal tail destroyed!")

func _destroy_vertical_tail() -> void:
	if not has_vertical_tail:
		return
	has_vertical_tail = false
	if vertical_tail_mesh:
		spawn_debris(vertical_tail_mesh, 30.0)
		vertical_tail_mesh = null
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
		spawn_debris(gear_node, 15.0)
	print("%s gear collapsed!" % which.capitalize())

# === MISSILES ===

func _spawn_missiles() -> void:
	for i in hardpoint_positions.size():
		var missile: Missile = MISSILE_SCENE.instantiate()
		var hp: Vector3 = hardpoint_positions[i]
		missile.state = Missile.State.ATTACHED
		if hp.x <= 0.0 and left_wing_mesh:
			missile.position = left_wing_mesh.to_local(to_global(hp))
			missile.set_meta("wing_side", "left")
			left_wing_mesh.add_child(missile)
		elif hp.x > 0.0 and right_wing_mesh:
			missile.position = right_wing_mesh.to_local(to_global(hp))
			missile.set_meta("wing_side", "right")
			right_wing_mesh.add_child(missile)
		else:
			missile.position = hp
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
		var wing_side: String = missile.get_meta("wing_side", "")
		if wing_side == "left" and not has_left_wing:
			continue
		if wing_side == "right" and not has_right_wing:
			continue

		# Reparent to scene root so it's independent
		var global_pos := missile.global_position
		var global_rot := missile.global_transform.basis
		missile.get_parent().remove_child(missile)
		get_tree().current_scene.add_child(missile)
		missile.global_position = global_pos
		missile.global_transform.basis = global_rot

		# Eject downward from the wing before ignition
		var eject_vel := linear_velocity - global_transform.basis.y * 8.0
		missile.launch(eject_vel, self)
		# Assign homing target if locked
		if laser_target and is_instance_valid(laser_target):
			missile.homing_target = laser_target
		print("Missile fired!")
		return

	print("No missiles available!")

# === WEAPON SYSTEM ===

func _setup_laser_camera() -> void:
	laser_camera_node = Camera3D.new()
	laser_camera_node.name = "LaserCamera"
	# Belly-mounted FLIR: below gear struts, looking straight down
	laser_camera_node.position = Vector3(0, -4.0, 0)
	laser_camera_node.rotation_degrees = Vector3(-90, 0, 0)  # -90 = look down (-Y)
	laser_camera_node.near = 0.5
	laser_camera_node.fov = 25.0
	laser_camera_node.far = 20000.0
	laser_camera_node.current = false
	add_child(laser_camera_node)

func _activate_laser_view() -> void:
	_laser_cam_yaw = 0.0
	_laser_cam_pitch = 0.0
	if laser_camera_node:
		laser_camera_node.rotation = Vector3(-PI / 2.0, 0.0, 0.0)
	laser_camera_active = true
	if cockpit_camera:
		cockpit_camera.current = false
	if third_person_camera:
		third_person_camera.current = false
	if laser_camera_node:
		laser_camera_node.current = true

func _deactivate_laser_view() -> void:
	laser_camera_active = false
	if laser_camera_node:
		laser_camera_node.current = false
	_update_active_camera()  # restore cockpit or third-person view

func _cycle_weapon() -> void:
	current_weapon = ((current_weapon as int) + 1) % 4 as WeaponMode
	var names := ["GUNS", "MISSILES", "LASER", "BOMBS"]
	print("Weapon: " + names[current_weapon as int])

func _drop_bomb() -> void:
	if bombs_remaining <= 0:
		print("No bombs remaining!")
		return
	bombs_remaining -= 1

	var bomb := RigidBody3D.new()
	bomb.mass = 50.0
	bomb.gravity_scale = 1.0
	bomb.collision_layer = 8
	bomb.collision_mask = 5
	bomb.contact_monitor = true
	bomb.max_contacts_reported = 1

	var mesh_inst := MeshInstance3D.new()
	var sphere_mesh := SphereMesh.new()
	sphere_mesh.radius = 0.25
	sphere_mesh.height = 0.8
	mesh_inst.mesh = sphere_mesh
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.15, 0.15, 0.15)
	mesh_inst.material_override = bmat
	bomb.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var bshape := SphereShape3D.new()
	bshape.radius = 0.25
	col.shape = bshape
	bomb.add_child(col)

	get_tree().current_scene.add_child(bomb)
	bomb.global_position = global_position + Vector3(0, -0.8, 0)
	bomb.linear_velocity = linear_velocity
	bomb.add_collision_exception_with(self)
	bomb.body_entered.connect(_on_bomb_hit.bind(bomb))
	print("Bomb dropped!")

func _on_bomb_hit(_body: Node, bomb: RigidBody3D) -> void:
	if not is_instance_valid(bomb):
		return
	var boom_pos := bomb.global_position
	bomb.queue_free()
	_spawn_explosion(boom_pos, 8.0, 30.0)
	# Damage nearby AI aircraft and notify HUD
	var hit_enemy := false
	for node in get_tree().get_nodes_in_group("ai_aircraft"):
		if is_instance_valid(node) and boom_pos.distance_to(node.global_position) <= 30.0:
			if node.has_method("take_hit"):
				node.take_hit(boom_pos)
				hit_enemy = true
	if hit_enemy:
		for hud in get_tree().get_nodes_in_group("weapon_hud"):
			hud.register_hit()

func _spawn_explosion(pos: Vector3, radius: float, light_range: float) -> void:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.5, 0.1, 1.0)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 6.0

	var sphere := SphereMesh.new()
	sphere.radius = radius * 0.1
	sphere.height = radius * 0.2
	var exp_mesh := MeshInstance3D.new()
	exp_mesh.mesh = sphere
	exp_mesh.material_override = mat
	get_tree().current_scene.add_child(exp_mesh)
	exp_mesh.global_position = pos

	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 12.0
	light.omni_range = light_range
	get_tree().current_scene.add_child(light)
	light.global_position = pos

	var tw := get_tree().create_tween()
	tw.tween_property(exp_mesh, "scale", Vector3(radius, radius, radius), 0.7)
	tw.tween_callback(func(): exp_mesh.queue_free(); light.queue_free())

func _cycle_target() -> void:
	var ai_planes: Array = get_tree().get_nodes_in_group("ai_aircraft")
	ai_planes = ai_planes.filter(func(n): return is_instance_valid(n))
	if ai_planes.is_empty():
		laser_target = null
		return
	if not laser_target or not is_instance_valid(laser_target):
		laser_target = ai_planes[0]
	else:
		var idx: int = ai_planes.find(laser_target)
		laser_target = ai_planes[(idx + 1) % ai_planes.size()]
	print("Target: " + laser_target.name)

func _laser_designate() -> void:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return
	var space := get_world_3d().direct_space_state
	var cam_fwd := -cam.global_transform.basis.z
	var query := PhysicsRayQueryParameters3D.create(
		cam.global_position,
		cam.global_position + cam_fwd * 20000.0,
		1
	)
	query.exclude = [get_rid()]
	var result := space.intersect_ray(query)
	if result:
		laser_spot_pos = result.position
		laser_spot_active = true
		print("Laser spot: ", laser_spot_pos)
	else:
		laser_spot_active = false

func _lock_nearest_target() -> void:
	var best_dist := 15000.0
	var best: Node3D = null
	for node in get_tree().get_nodes_in_group("ai_aircraft"):
		if not is_instance_valid(node):
			continue
		var d := global_position.distance_to(node.global_position)
		if d < best_dist:
			best_dist = d
			best = node
	if best:
		laser_target = best
		print("Locked: %s at %.0fm" % [best.name, best_dist])
	else:
		laser_target = null
		print("No target in range")

func _deploy_countermeasures() -> void:
	if countermeasures <= 0:
		print("No countermeasures remaining!")
		return
	countermeasures -= 1
	_spawn_flare()
	_spawn_flare()
	print("Countermeasures: %d remaining" % countermeasures)

func _spawn_flare() -> void:
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
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.85, 0.3)
	light.light_energy = 8.0
	light.omni_range = 60.0
	flare.add_child(light)
	flare.add_to_group("flares")
	get_tree().current_scene.add_child(flare)
	var side := global_transform.basis.x * (1.0 if randf() > 0.5 else -1.0)
	var backward := global_transform.basis.z  # +Z is rearward in Godot
	flare.global_position = global_position + side * 2.0 + backward * 2.0
	flare.linear_velocity = linear_velocity + side * 40.0 + backward * 30.0 + Vector3.DOWN * 15.0
	var tw := flare.create_tween()
	tw.tween_interval(2.5)
	tw.tween_method(func(e: float): mat.emission_energy_multiplier = e; light.light_energy = e,
		8.0, 0.0, 1.5)
	tw.tween_callback(flare.queue_free)
