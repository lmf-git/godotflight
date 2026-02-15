extends Node3D

## Cockpit interior controller
## Animates joystick, throttle lever, updates instruments, and handles click+drag interaction

var vehicle: Vehicle

@onready var joystick: Node3D = get_node_or_null("Joystick")
@onready var throttle_lever: Node3D = get_node_or_null("ThrottleLever")

# Instrument labels
@onready var airspeed_label: Label3D = $Instruments/AirspeedLabel
@onready var altimeter_label: Label3D = $Instruments/AltimeterLabel
@onready var heading_label: Label3D = $Instruments/HeadingLabel
@onready var vsi_label: Label3D = $Instruments/VSILabel
@onready var aoa_label: Label3D = $Instruments/AoALabel
@onready var throttle_label: Label3D = $Instruments/ThrottleLabel
@onready var gear_label: Label3D = $Instruments/GearLabel
@onready var flaps_label: Label3D = $Instruments/FlapsLabel
@onready var stall_warning: Label3D = $Instruments/StallWarning

const JOYSTICK_MAX_ANGLE := 25.0  # degrees max deflection
const THROTTLE_TRAVEL := 0.12     # meters of lever travel
const DRAG_SENSITIVITY := 0.004   # mouse pixels to control input

# Artificial Horizon
var ah_mesh: MeshInstance3D
var ah_material: ShaderMaterial

# Interaction state
enum DragTarget { NONE, JOYSTICK, THROTTLE }
var _drag_target: DragTarget = DragTarget.NONE
var _drag_pitch: float = 0.0   # joystick drag override
var _drag_roll: float = 0.0    # joystick drag override
var _drag_throttle: float = 0.0  # throttle drag value

# Engine start button (created dynamically for vehicles that need it)
var _start_button_mesh: MeshInstance3D
var _start_button_label: Label3D
var _start_button_last_state := false

func _ready() -> void:
	vehicle = get_parent() as Vehicle
	if stall_warning:
		stall_warning.visible = false
	_create_artificial_horizon()
	# Deferred: vehicle subclass _ready() hasn't run yet (children ready before parent)
	_deferred_setup.call_deferred()


func _deferred_setup() -> void:
	if vehicle and vehicle.requires_startup:
		_create_start_button()

func _unhandled_input(event: InputEvent) -> void:
	if not vehicle or not vehicle.is_occupied:
		return
	if vehicle.use_third_person:
		return  # No interaction in third person
	if vehicle.freelook_active:
		return  # No interaction while freelooking

	# Mouse click to start dragging a control
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_try_start_drag()
			else:
				_stop_drag()

	# Mouse motion while dragging - consume the event so vehicle flight controls don't also react
	if event is InputEventMouseMotion and _drag_target != DragTarget.NONE:
		_handle_drag(event.relative)
		get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	if not vehicle or not vehicle.is_occupied:
		return

	_animate_controls()
	_update_instruments()
	_update_artificial_horizon()
	if _start_button_label:
		_update_start_button()

func _animate_controls() -> void:
	# Joystick rotates with pitch (X) and roll (Z) inputs
	if joystick:
		var pitch_angle := -vehicle.input_pitch * deg_to_rad(JOYSTICK_MAX_ANGLE)
		var roll_angle := vehicle.input_roll * deg_to_rad(JOYSTICK_MAX_ANGLE)
		joystick.rotation = Vector3(pitch_angle, 0.0, roll_angle)

	# Throttle lever slides forward with throttle
	if throttle_lever:
		throttle_lever.position.z = -vehicle.input_throttle * THROTTLE_TRAVEL

func _update_instruments() -> void:
	if airspeed_label:
		var kts := vehicle.airspeed * 1.944
		airspeed_label.text = "%3.0f KTS" % kts

	if altimeter_label:
		altimeter_label.text = "%5.0f FT" % (vehicle.altitude_msl * 3.281)

	if heading_label:
		heading_label.text = "HDG %03.0f" % vehicle.heading

	if vsi_label:
		var fpm := vehicle.vertical_speed * 196.85
		vsi_label.text = "VS %+.0f" % fpm

	if aoa_label:
		aoa_label.text = "AOA %+.1f" % vehicle.angle_of_attack

	if throttle_label:
		var prefix := "COL" if vehicle is Helicopter else "THR"
		throttle_label.text = "%s %3.0f%%" % [prefix, vehicle.input_throttle * 100.0]

	# Gear, flaps, stall work on both FixedWing and Jet via duck typing
	if gear_label:
		if "gear_down" in vehicle:
			gear_label.text = "GEAR DN" if vehicle.gear_down else "GEAR UP"
			gear_label.modulate = Color.GREEN if vehicle.gear_down else Color.RED

	if flaps_label:
		if "flaps_input" in vehicle:
			flaps_label.text = "FLAP %2.0f" % (vehicle.flaps_input * 100.0)

	if stall_warning:
		if "is_stalled" in vehicle:
			stall_warning.visible = vehicle.is_stalled

# === CLICK + DRAG INTERACTION ===

func _try_start_drag() -> void:
	# Raycast from the cockpit camera into the scene
	var camera: Camera3D = vehicle.cockpit_camera
	if not camera or not camera.current:
		return

	var viewport := get_viewport()
	var mouse_pos := viewport.get_mouse_position()
	var ray_origin := camera.project_ray_origin(mouse_pos)
	var ray_dir := camera.project_ray_normal(mouse_pos)

	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		ray_origin, ray_origin + ray_dir * 2.0,
		0xFFFFFFFF  # All layers
	)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var result := space_state.intersect_ray(query)

	if result.is_empty():
		return

	var hit_node: Node = result.collider
	# Walk up to find if it's a joystick, throttle, or start button area
	while hit_node:
		if hit_node.name == "JoystickArea":
			_drag_target = DragTarget.JOYSTICK
			_drag_pitch = vehicle.input_pitch
			_drag_roll = vehicle.input_roll
			return
		elif hit_node.name == "ThrottleArea":
			_drag_target = DragTarget.THROTTLE
			_drag_throttle = vehicle.throttle if "throttle" in vehicle else vehicle.input_throttle
			return
		elif hit_node.name == "StartButtonArea":
			vehicle.engine_running = not vehicle.engine_running
			_update_start_button()
			return
		hit_node = hit_node.get_parent()

func _stop_drag() -> void:
	_drag_target = DragTarget.NONE

func _handle_drag(relative: Vector2) -> void:
	if _drag_target == DragTarget.JOYSTICK:
		_drag_pitch = clamp(_drag_pitch + relative.y * DRAG_SENSITIVITY, -1.0, 1.0)
		_drag_roll = clamp(_drag_roll + relative.x * DRAG_SENSITIVITY, -1.0, 1.0)
		# Override the vehicle's mouse input so the drag controls the plane
		vehicle.mouse_input.y = _drag_pitch
		vehicle.mouse_input.x = _drag_roll

	elif _drag_target == DragTarget.THROTTLE:
		_drag_throttle = clamp(_drag_throttle - relative.y * DRAG_SENSITIVITY, 0.0, 1.0)
		if "throttle" in vehicle:
			vehicle.throttle = _drag_throttle

# === ARTIFICIAL HORIZON ===

func _create_artificial_horizon() -> void:
	var shader := load("res://scenes/debug/artificial_horizon.gdshader") as Shader
	if not shader:
		return

	ah_material = ShaderMaterial.new()
	ah_material.shader = shader

	var quad := QuadMesh.new()
	quad.size = Vector2(0.15, 0.15)

	ah_mesh = MeshInstance3D.new()
	ah_mesh.mesh = quad
	ah_mesh.material_override = ah_material

	var instruments := get_node_or_null("Instruments")
	if instruments:
		# Match z depth of existing instrument labels
		var dash_z := -0.74
		if airspeed_label:
			dash_z = airspeed_label.position.z - 0.001  # Slightly in front
		ah_mesh.position = Vector3(0.0, -0.02, dash_z)
		instruments.add_child(ah_mesh)
	else:
		ah_mesh.position = Vector3(0.0, -0.02, -0.74)
		add_child(ah_mesh)

func _update_artificial_horizon() -> void:
	if not ah_material or not vehicle:
		return

	# Calculate pitch and roll from aircraft orientation
	var forward := -vehicle.global_transform.basis.z
	var up := vehicle.global_transform.basis.y
	var right := vehicle.global_transform.basis.x

	# Pitch: asin is stable at all attitudes (no singularity at ±90°)
	var pitch_angle := asin(clamp(forward.y, -1.0, 1.0))

	# Roll: atan2 is stable everywhere, no gimbal lock
	var roll_angle := atan2(-right.y, up.y)

	ah_material.set_shader_parameter("pitch", pitch_angle)
	ah_material.set_shader_parameter("roll", roll_angle)

	# Flight Path Vector: where the velocity vector points relative to aircraft nose
	var vel_local := vehicle.get_local_velocity()
	if vel_local.length() > 5.0:
		var fpv_pitch := atan2(-vel_local.y, -vel_local.z)
		var fpv_yaw := atan2(vel_local.x, -vel_local.z)
		# Offset from aircraft nose (subtract aircraft pitch/roll contribution)
		ah_material.set_shader_parameter("fpv_x", clamp(fpv_yaw * 2.0, -1.0, 1.0))
		ah_material.set_shader_parameter("fpv_y", clamp((fpv_pitch - pitch_angle) * 2.0, -1.0, 1.0))
	else:
		ah_material.set_shader_parameter("fpv_x", 0.0)
		ah_material.set_shader_parameter("fpv_y", 0.0)


# === ENGINE START BUTTON ===

func _create_start_button() -> void:
	# Place on the dashboard, right of center instruments
	var instruments := get_node_or_null("Instruments")
	var dash_z := -0.74
	if instruments and instruments.get_child_count() > 0:
		dash_z = instruments.get_child(0).position.z - 0.005

	var btn_root := Node3D.new()
	btn_root.name = "StartButton"
	btn_root.position = Vector3(0.32, -0.15, dash_z)
	add_child(btn_root)

	# Button housing (dark box behind the button)
	var housing_mesh := BoxMesh.new()
	housing_mesh.size = Vector3(0.1, 0.06, 0.02)
	var housing := MeshInstance3D.new()
	housing.mesh = housing_mesh
	var housing_mat := StandardMaterial3D.new()
	housing_mat.albedo_color = Color(0.08, 0.08, 0.08)
	housing.material_override = housing_mat
	btn_root.add_child(housing)

	# Button cap - large and visible
	var cap_mesh := CylinderMesh.new()
	cap_mesh.top_radius = 0.035
	cap_mesh.bottom_radius = 0.035
	cap_mesh.height = 0.02
	_start_button_mesh = MeshInstance3D.new()
	_start_button_mesh.mesh = cap_mesh
	_start_button_mesh.position = Vector3(0, 0, 0.015)
	# Rotate so the flat face points toward the pilot (+Z)
	_start_button_mesh.rotation = Vector3(PI / 2.0, 0, 0)
	btn_root.add_child(_start_button_mesh)

	# Click area
	var area := Area3D.new()
	area.name = "StartButtonArea"
	area.position = Vector3(0, 0, 0.01)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.12, 0.08, 0.04)
	col.shape = shape
	area.add_child(col)
	btn_root.add_child(area)

	# Label above button
	_start_button_label = Label3D.new()
	_start_button_label.pixel_size = 0.002
	_start_button_label.font_size = 14
	_start_button_label.outline_size = 4
	_start_button_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_start_button_label.position = Vector3(0, 0.055, 0.01)
	btn_root.add_child(_start_button_label)

	_start_button_last_state = not vehicle.engine_running  # force first update
	_update_start_button()


func _update_start_button() -> void:
	if not vehicle:
		return
	var running := vehicle.engine_running
	if running == _start_button_last_state:
		return
	_start_button_last_state = running
	if _start_button_mesh:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.1, 0.8, 0.2) if running else Color(0.8, 0.1, 0.1)
		mat.emission_enabled = true
		mat.emission = mat.albedo_color * 0.5
		_start_button_mesh.material_override = mat
	if _start_button_label:
		_start_button_label.text = "ENG ON" if running else "ENG OFF"
		_start_button_label.modulate = Color(0.3, 1, 0.3) if running else Color(1, 0.3, 0.3)
		_start_button_label.outline_modulate = Color(0, 0.1, 0) if running else Color(0.2, 0, 0)
