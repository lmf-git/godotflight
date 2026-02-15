extends RigidBody3D
class_name Vehicle

## Base class for all flyable vehicles
## Handles mounting/unmounting, camera switching, and common flight data

signal pilot_mounted(player: Player)
signal pilot_unmounted()

# Flight data for debug display
var airspeed: float = 0.0          # m/s
var altitude_agl: float = 0.0      # Above ground level
var altitude_msl: float = 0.0      # Mean sea level (y position)
var vertical_speed: float = 0.0    # m/s
var angle_of_attack: float = 0.0   # degrees
var g_force: float = 1.0
var heading: float = 0.0           # degrees

# Control inputs (normalized -1 to 1)
var input_pitch: float = 0.0
var input_roll: float = 0.0
var input_yaw: float = 0.0
var input_throttle: float = 0.0

# Vehicle state
var is_occupied := false
var current_pilot: Player = null
var engine_running := false
var requires_startup := false  # If true, engine must be manually started (cockpit button)

# Debug visualization
var debug_forces: Dictionary = {}  # name -> Vector3 (world space force)
var debug_enabled := true  # Start with debug on, press P to toggle

# Turbulence
var _turb_force := Vector3.ZERO
var _turb_torque := Vector3.ZERO
const TURBULENCE_INTENSITY := 0.002  # Very subtle

# Mouse input accumulator
var mouse_input := Vector2.ZERO
const MOUSE_SENSITIVITY := 0.003
const MOUSE_RETURN_SPEED := 3.0

# Camera state
var use_third_person := false
var freelook_active := false
var freelook_locked := false       # Double-tap Alt toggles camera lock
var freelook_yaw: float = 0.0
var freelook_pitch: float = 0.0
var _alt_was_pressed := false
var _alt_last_press_time: float = 0.0
const FREELOOK_SENSITIVITY := 0.003
const FREELOOK_RETURN_SPEED := 5.0
const FREELOOK_MAX_PITCH := 1.4  # ~80 degrees
const DOUBLE_TAP_TIME := 0.3      # seconds

@onready var cockpit_camera: Camera3D = $CockpitCamera
@onready var third_person_camera: Camera3D = $ThirdPersonCamera
@onready var exit_position: Marker3D = $ExitPosition
var _tp_default_pos: Vector3  # stored on ready for orbit calculations

func _ready() -> void:
	# Set up physics
	collision_layer = 4  # Vehicles layer
	collision_mask = 5   # World + Vehicles layers

	# Disable cameras initially
	if cockpit_camera:
		cockpit_camera.current = false
	if third_person_camera:
		third_person_camera.current = false
		_tp_default_pos = third_person_camera.position

	# Set initial debug visibility
	_on_debug_toggled()

func _unhandled_input(event: InputEvent) -> void:
	if not is_occupied:
		return

	# Toggle debug - only for the vehicle we're in
	if event.is_action_pressed("toggle_debug"):
		debug_enabled = not debug_enabled
		_on_debug_toggled()

	# Freelook: Hold Alt = temporary look (snaps back), Double-tap Alt = lock camera
	var alt_pressed := Input.is_key_pressed(KEY_ALT)

	# Detect Alt press edge for double-tap
	if alt_pressed and not _alt_was_pressed:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _alt_last_press_time < DOUBLE_TAP_TIME:
			freelook_locked = not freelook_locked
			_alt_last_press_time = 0.0
		else:
			_alt_last_press_time = now
	_alt_was_pressed = alt_pressed

	freelook_active = alt_pressed

	# Mouse input: Alt held = camera, otherwise = flight controls
	if event is InputEventMouseMotion:
		if freelook_active:
			freelook_yaw -= event.relative.x * FREELOOK_SENSITIVITY
			freelook_pitch -= event.relative.y * FREELOOK_SENSITIVITY
			freelook_pitch = clamp(freelook_pitch, -FREELOOK_MAX_PITCH, FREELOOK_MAX_PITCH)
		else:
			mouse_input.x += event.relative.x * MOUSE_SENSITIVITY
			mouse_input.y += event.relative.y * MOUSE_SENSITIVITY
			mouse_input.x = clamp(mouse_input.x, -1.0, 1.0)
			mouse_input.y = clamp(mouse_input.y, -1.0, 1.0)

	# Exit vehicle
	if event.is_action_pressed("interact"):
		if current_pilot:
			current_pilot.exit_vehicle()

	# Toggle camera (O key)
	if event.is_action_pressed("toggle_camera"):
		_toggle_camera()

const MAX_SPEED := 1000.0          # m/s hard cap (~Mach 3)
const ORIGIN_SHIFT_THRESHOLD := 3000.0  # meters from origin before shifting
const MAX_ALTITUDE := 20000.0      # meters above/below origin before clamping

func _physics_process(delta: float) -> void:
	# Sanity: clamp velocity to prevent physics explosion
	if not linear_velocity.is_finite() or linear_velocity.length_squared() > MAX_SPEED * MAX_SPEED:
		linear_velocity = linear_velocity.normalized() * MAX_SPEED if linear_velocity.is_finite() else Vector3.ZERO
	if not angular_velocity.is_finite():
		angular_velocity = Vector3.ZERO

	# Sanity: clamp position to prevent physics explosion (Y included)
	if not global_position.is_finite():
		global_position = Vector3.ZERO
		linear_velocity = Vector3.ZERO
	elif absf(global_position.y) > MAX_ALTITUDE:
		global_position.y = signf(global_position.y) * MAX_ALTITUDE
		linear_velocity.y = 0.0

	_update_flight_data()

	if is_occupied:
		_process_inputs(delta)
		_apply_flight_physics(delta)
		_apply_turbulence(delta)

		# Floating origin: shift world back to keep precision (XZ distance only)
		var xz_dist_sq := global_position.x * global_position.x + global_position.z * global_position.z
		if xz_dist_sq > ORIGIN_SHIFT_THRESHOLD * ORIGIN_SHIFT_THRESHOLD:
			_shift_world_origin()

	# Return mouse to center when not moving
	mouse_input = mouse_input.move_toward(Vector2.ZERO, MOUSE_RETURN_SPEED * delta)

func _shift_world_origin() -> void:
	var offset := Vector3(global_position.x, 0.0, global_position.z)
	if offset.length_squared() < 1.0:
		return
	var scene_root := get_tree().current_scene
	for child in scene_root.get_children():
		if child is RigidBody3D:
			# RigidBody3D: must use PhysicsServer to teleport reliably
			var xform: Transform3D = child.global_transform
			xform.origin -= offset
			PhysicsServer3D.body_set_state(child.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xform)
			child.global_transform = xform
		elif child is Node3D:
			# StaticBody3D, CharacterBody3D, and all other Node3D
			child.global_position -= offset
			if child.has_method("notify_origin_shift"):
				child.notify_origin_shift(offset)

func _process(delta: float) -> void:
	# Return camera to center when Alt released AND not locked
	if not freelook_active and not freelook_locked:
		freelook_yaw = move_toward(freelook_yaw, 0.0, FREELOOK_RETURN_SPEED * delta)
		freelook_pitch = move_toward(freelook_pitch, 0.0, FREELOOK_RETURN_SPEED * delta)

	# Apply freelook to active camera
	if cockpit_camera and not use_third_person:
		cockpit_camera.rotation = Vector3(freelook_pitch, freelook_yaw, 0.0)
	if third_person_camera and use_third_person:
		# Orbit around vehicle center instead of rotating in place
		var orbit_basis := Basis(Vector3.UP, freelook_yaw) * Basis(Vector3.RIGHT, freelook_pitch)
		third_person_camera.position = orbit_basis * _tp_default_pos
		third_person_camera.look_at(global_position)

func _process_inputs(_delta: float) -> void:
	# Override in subclasses for specific control schemes
	input_pitch = mouse_input.y
	input_roll = mouse_input.x

func _apply_flight_physics(_delta: float) -> void:
	# Override in subclasses
	pass

func _update_flight_data() -> void:
	# Airspeed (magnitude of velocity)
	airspeed = linear_velocity.length()

	# Altitude MSL is just Y position
	altitude_msl = global_position.y

	# Altitude AGL - raycast down
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsRayQueryParameters3D.create(
		global_position,
		global_position + Vector3.DOWN * 10000,
		1  # World layer
	)
	query.exclude = [get_rid()]
	var result := space_state.intersect_ray(query)
	if result:
		altitude_agl = global_position.y - result.position.y
	else:
		altitude_agl = altitude_msl

	# Vertical speed
	vertical_speed = linear_velocity.y

	# Heading
	var forward := -global_transform.basis.z
	heading = rad_to_deg(atan2(forward.x, forward.z))
	if heading < 0:
		heading += 360

	# G-force (simplified)
	# Compare actual acceleration to gravity
	var dt: float = get_physics_process_delta_time()
	var accel: Vector3 = (linear_velocity - _prev_velocity) / dt if dt > 0 else Vector3.ZERO
	var local_accel: Vector3 = global_transform.basis.inverse() * accel
	g_force = 1.0 + local_accel.y / 9.81
	_prev_velocity = linear_velocity

var _prev_velocity := Vector3.ZERO

func mount(player: Player) -> void:
	is_occupied = true
	current_pilot = player
	if not requires_startup:
		engine_running = true

	# Activate appropriate camera based on preference
	_update_active_camera()

	# Show debug display if enabled
	_on_debug_toggled()

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	pilot_mounted.emit(player)

func unmount() -> void:
	# Store pilot reference before clearing
	var pilot := current_pilot

	is_occupied = false
	current_pilot = null
	engine_running = false

	# Deactivate both cameras
	if cockpit_camera:
		cockpit_camera.current = false
	if third_person_camera:
		third_person_camera.current = false

	# Hide debug display when exiting
	var debug_node: Node3D = get_node_or_null("DebugDraw")
	if debug_node:
		debug_node.visible = false

	# Return camera to player
	if pilot and pilot.camera:
		pilot.camera.current = true

	pilot_unmounted.emit()

func _toggle_camera() -> void:
	use_third_person = not use_third_person
	_update_active_camera()

func _update_active_camera() -> void:
	if use_third_person and third_person_camera:
		if cockpit_camera:
			cockpit_camera.current = false
		third_person_camera.current = true
	elif cockpit_camera:
		if third_person_camera:
			third_person_camera.current = false
		cockpit_camera.current = true

func get_exit_position() -> Vector3:
	if exit_position:
		return exit_position.global_position
	return global_position + Vector3(3, 0, 0)

func _on_debug_toggled() -> void:
	# Show/hide debug visualization
	var debug_node: Node3D = get_node_or_null("DebugDraw")
	if debug_node:
		debug_node.visible = debug_enabled

# Helper to add debug force vector
func add_debug_force(force_name: String, force: Vector3, color: Color = Color.WHITE) -> void:
	debug_forces[force_name] = {"force": force, "color": color}

func clear_debug_forces() -> void:
	debug_forces.clear()

# Get local forward velocity (for AoA calculation)
func get_local_velocity() -> Vector3:
	return global_transform.basis.inverse() * linear_velocity

# Calculate angle of attack (in the aircraft's symmetry plane, ignoring sideslip)
func calculate_aoa() -> float:
	var local_vel: Vector3 = get_local_velocity()
	# Use only the longitudinal plane (Y and Z) — sideslip (X) doesn't affect AoA
	var forward_speed: float = -local_vel.z
	var vert_speed: float = -local_vel.y
	if forward_speed < 0.5 and absf(vert_speed) < 0.5:
		return 0.0  # Too slow to have meaningful AoA
	return rad_to_deg(atan2(vert_speed, maxf(forward_speed, 0.5)))

## Spawn a destroyed part as a free-flying RigidBody3D debris piece.
## Takes a mesh node (or Node3D with mesh children), detaches it, and flings it.
func spawn_debris(part_node: Node3D, part_mass: float = 50.0) -> void:
	if not part_node or not is_instance_valid(part_node):
		return

	var scene_root := get_tree().current_scene
	if not scene_root:
		part_node.visible = false
		return

	# Capture world transform before reparenting
	var world_xform := part_node.global_transform

	# Remove from vehicle
	part_node.get_parent().remove_child(part_node)

	# Create a RigidBody3D wrapper
	var debris := RigidBody3D.new()
	debris.mass = part_mass
	debris.gravity_scale = 1.0
	debris.collision_layer = 4  # Vehicle layer
	debris.collision_mask = 1   # World only

	# Add the mesh node as child of debris
	part_node.transform = Transform3D.IDENTITY
	debris.add_child(part_node)
	part_node.visible = true

	# Add a simple collision shape based on the part's AABB
	var aabb := _get_node_aabb(part_node)
	if aabb.size.length() > 0.01:
		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = aabb.size
		col.shape = box
		col.position = aabb.get_center()
		debris.add_child(col)

	# Place in world
	scene_root.add_child(debris)
	debris.global_transform = world_xform

	# Give it the vehicle's velocity plus a random fling
	debris.linear_velocity = linear_velocity + Vector3(
		randf_range(-5, 5),
		randf_range(2, 8),
		randf_range(-5, 5)
	)
	debris.angular_velocity = Vector3(
		randf_range(-3, 3),
		randf_range(-3, 3),
		randf_range(-3, 3)
	)

	# Auto-despawn after 10 seconds
	var timer := Timer.new()
	timer.wait_time = 10.0
	timer.one_shot = true
	timer.timeout.connect(func(): debris.queue_free())
	debris.add_child(timer)
	timer.start()

## Get combined AABB of a node and its mesh children
func _get_node_aabb(node: Node3D) -> AABB:
	var result := AABB()
	if node is MeshInstance3D and node.mesh:
		result = node.mesh.get_aabb()
	for child in node.get_children():
		if child is MeshInstance3D and child.mesh:
			var child_aabb: AABB = child.mesh.get_aabb()
			child_aabb.position += child.position
			if result.size.length() < 0.01:
				result = child_aabb
			else:
				result = result.merge(child_aabb)
	return result

func _apply_turbulence(delta: float) -> void:
	if airspeed < 5.0:
		return
	# Smoothed random perturbations that scale with dynamic pressure
	var dynamic_pressure := 0.5 * 1.225 * airspeed * airspeed
	var force_scale := dynamic_pressure * TURBULENCE_INTENSITY
	# Smooth noise: lerp toward new random target each frame
	var target_force := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * force_scale
	_turb_force = _turb_force.lerp(target_force, 3.0 * delta)
	apply_central_force(_turb_force)
	# Small torque perturbations
	var torque_scale := force_scale * 0.05
	var target_torque := Vector3(
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0),
		randf_range(-1.0, 1.0)
	) * torque_scale
	_turb_torque = _turb_torque.lerp(target_torque, 3.0 * delta)
	apply_torque(_turb_torque)
