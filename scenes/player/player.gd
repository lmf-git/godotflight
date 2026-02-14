extends CharacterBody3D
class_name Player

## FPS Player Controller with vehicle interaction support

signal entered_vehicle(vehicle: Vehicle)
signal exited_vehicle()

const SPEED := 5.0
const SPRINT_SPEED := 8.0
const JUMP_VELOCITY := 4.5
const MOUSE_SENSITIVITY := 0.002
const INTERACTION_DISTANCE := 5.0

# Freelook
const FREELOOK_SENSITIVITY := 0.003
const FREELOOK_RETURN_SPEED := 5.0
const FREELOOK_MAX_PITCH := 1.4  # ~80 degrees
const FREELOOK_MAX_YAW := PI     # Full 180 degrees
const DOUBLE_TAP_TIME := 0.3

@onready var camera: Camera3D = $Camera3D
@onready var third_person_camera: Camera3D = $ThirdPersonCamera
@onready var interaction_ray: RayCast3D = $Camera3D/InteractionRay

var gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var current_vehicle: Vehicle = null
var is_in_vehicle := false
var interact_cooldown: float = 0.0
var use_third_person := false
var _base_pitch: float = 0.0  # Mouselook pitch stored separately from freelook

# Freelook state
var freelook_active := false
var freelook_locked := false
var freelook_yaw: float = 0.0
var freelook_pitch: float = 0.0
var _alt_was_pressed := false
var _alt_last_press_time: float = 0.0
var _tp_default_pos: Vector3

func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if third_person_camera:
		_tp_default_pos = third_person_camera.position

func _unhandled_input(event: InputEvent) -> void:
	# Escape to release mouse - always works
	if event.is_action_pressed("ui_cancel"):
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		else:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

	if is_in_vehicle:
		return

	# Toggle camera (O key)
	if event.is_action_pressed("toggle_camera"):
		_toggle_camera()

	# Freelook: Hold Alt = temporary look, Double-tap Alt = lock camera
	var alt_pressed := Input.is_key_pressed(KEY_ALT)
	if alt_pressed and not _alt_was_pressed:
		var now := Time.get_ticks_msec() / 1000.0
		if now - _alt_last_press_time < DOUBLE_TAP_TIME:
			freelook_locked = not freelook_locked
			_alt_last_press_time = 0.0
		else:
			_alt_last_press_time = now
	_alt_was_pressed = alt_pressed
	freelook_active = alt_pressed

	# Mouse input
	if event is InputEventMouseMotion:
		if freelook_active or freelook_locked:
			# Freelook: rotate camera independently
			freelook_yaw -= event.relative.x * FREELOOK_SENSITIVITY
			freelook_yaw = clamp(freelook_yaw, -FREELOOK_MAX_YAW, FREELOOK_MAX_YAW)
			freelook_pitch -= event.relative.y * FREELOOK_SENSITIVITY
			freelook_pitch = clamp(freelook_pitch, -FREELOOK_MAX_PITCH, FREELOOK_MAX_PITCH)
		else:
			# Normal mouselook: rotate player body
			rotate_y(-event.relative.x * MOUSE_SENSITIVITY)
			_base_pitch -= event.relative.y * MOUSE_SENSITIVITY
			_base_pitch = clamp(_base_pitch, -PI/2, PI/2)

func _process(delta: float) -> void:
	if is_in_vehicle:
		return

	# Return freelook to center when Alt released and not locked
	if not freelook_active and not freelook_locked:
		freelook_yaw = move_toward(freelook_yaw, 0.0, FREELOOK_RETURN_SPEED * delta)
		freelook_pitch = move_toward(freelook_pitch, 0.0, FREELOOK_RETURN_SPEED * delta)

	# Apply base pitch + freelook offset to cameras
	camera.rotation = Vector3(_base_pitch + freelook_pitch, freelook_yaw, 0.0)
	if third_person_camera:
		# Orbit around player center instead of rotating in place
		var pitch := _base_pitch * 0.5 + freelook_pitch
		var orbit_basis := Basis(Vector3.UP, freelook_yaw) * Basis(Vector3.RIGHT, pitch)
		third_person_camera.position = orbit_basis * _tp_default_pos
		third_person_camera.look_at(global_position + Vector3.UP * 0.9)

func _physics_process(delta: float) -> void:
	# Tick down cooldown
	if interact_cooldown > 0:
		interact_cooldown -= delta

	if is_in_vehicle:
		return

	# Gravity
	if not is_on_floor():
		velocity.y -= gravity * delta

	# Jump
	if Input.is_action_just_pressed("jump") and is_on_floor():
		velocity.y = JUMP_VELOCITY

	# Movement
	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	var direction := (transform.basis * Vector3(input_dir.x, 0, input_dir.y)).normalized()

	var speed := SPRINT_SPEED if Input.is_action_pressed("sprint") else SPEED

	if direction:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed
	else:
		velocity.x = move_toward(velocity.x, 0, speed)
		velocity.z = move_toward(velocity.z, 0, speed)

	move_and_slide()

	# Vehicle interaction
	if Input.is_action_just_pressed("interact") and interact_cooldown <= 0:
		_try_interact()

func _try_interact() -> void:
	if interaction_ray.is_colliding():
		var collider = interaction_ray.get_collider()
		if collider is Vehicle:
			enter_vehicle(collider)
	else:
		# Also check for nearby vehicles with area detection
		var nearby := _find_nearby_vehicle()
		if nearby:
			enter_vehicle(nearby)

func _find_nearby_vehicle() -> Vehicle:
	var space_state := get_world_3d().direct_space_state
	var query := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = INTERACTION_DISTANCE
	query.shape = sphere
	query.transform = global_transform
	query.collision_mask = 4  # Vehicles layer

	var results := space_state.intersect_shape(query, 10)
	for result in results:
		if result.collider is Vehicle:
			return result.collider
	return null

func enter_vehicle(vehicle: Vehicle) -> void:
	if vehicle.is_occupied:
		return

	current_vehicle = vehicle
	is_in_vehicle = true

	# Hide player, disable collision
	visible = false
	$CollisionShape3D.disabled = true

	# Disable player cameras
	camera.current = false
	if third_person_camera:
		third_person_camera.current = false

	# Mount the vehicle
	vehicle.mount(self)
	entered_vehicle.emit(vehicle)

func exit_vehicle() -> void:
	if not current_vehicle:
		return

	# Get exit position from vehicle
	var exit_pos: Vector3 = current_vehicle.get_exit_position()

	# Unmount
	current_vehicle.unmount()
	current_vehicle = null
	is_in_vehicle = false

	# Restore player
	visible = true
	$CollisionShape3D.disabled = false
	global_position = exit_pos
	velocity = Vector3.ZERO

	# Restore player camera
	_update_camera()

	# Prevent immediate re-entry
	interact_cooldown = 0.5

	exited_vehicle.emit()

func _toggle_camera() -> void:
	use_third_person = not use_third_person
	_update_camera()

func _update_camera() -> void:
	if use_third_person and third_person_camera:
		camera.current = false
		third_person_camera.current = true
	else:
		if third_person_camera:
			third_person_camera.current = false
		camera.current = true
