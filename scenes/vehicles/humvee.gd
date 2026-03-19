extends Vehicle
class_name Humvee

## Military humvee with a roof-mounted machine gun.
## Drives like the car (W/S/A/D).
## Mouse X = turret yaw, Mouse Y = gun pitch.
## LMB fires the machine gun.

# Ground physics
const ENGINE_POWER := 22000.0
const BRAKE_POWER  := 28000.0
const DRIVE_MAX_SPEED := 25.0  # m/s (~90 km/h)
const WHEELBASE    := 2.8      # m
const MAX_STEER    := 32.0     # degrees

const SPRING_K     := 40000.0
const DAMPING_C    := 5000.0
const SUSP_TRAVEL  := 0.25
const WHEEL_RADIUS := 0.40

# Turret
const TURRET_SENSITIVITY := 0.003
const GUN_MAX_PITCH   := 0.55   # ~31° up
const GUN_MIN_PITCH   := -0.15  # ~8° down

var _turret_yaw  := 0.0
var _gun_pitch   := 0.0
var _throttle    := 0.0
var _brake       := 0.0
var _cur_steer   := 0.0
var _prev_comp   := [0.0, 0.0, 0.0, 0.0]
var _is_driver   := true   # true = drives; false = aims roof gun and fires

@onready var turret_node  : Node3D   = $Turret
@onready var gun_pivot    : Node3D   = $Turret/GunPivot
@onready var gun_node     : AircraftGun = $Turret/GunPivot/MachineGun
@onready var muzzle_point : Marker3D = $Turret/GunPivot/MachineGun/MuzzlePoint
@onready var susp_ray_fl  : RayCast3D = $SuspensionRayFL
@onready var susp_ray_fr  : RayCast3D = $SuspensionRayFR
@onready var susp_ray_rl  : RayCast3D = $SuspensionRayRL
@onready var susp_ray_rr  : RayCast3D = $SuspensionRayRR


func get_entry_hint(player_pos: Vector3) -> String:
	var to_player := player_pos - global_position
	if to_player.dot(global_transform.basis.x) >= 0.0:
		return "DRIVER"
	else:
		return "GUNNER"

func mount(player: Player) -> void:
	var to_player := player.global_position - global_position
	_is_driver = to_player.dot(global_transform.basis.x) >= 0.0
	super.mount(player)

func _ready() -> void:
	super._ready()
	mass = 2500.0
	contact_monitor = true
	max_contacts_reported = 4
	collision_layer = 4
	collision_mask = 5
	_build_mesh()


func _build_mesh() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.55, 0.52, 0.38)  # desert tan
	body_mat.roughness = 0.85

	# Body
	var body_mi := MeshInstance3D.new()
	var body_m := BoxMesh.new()
	body_m.size = Vector3(2.1, 0.7, 4.5)
	body_mi.mesh = body_m
	body_mi.material_override = body_mat
	body_mi.position = Vector3(0, 0.35, 0)
	add_child(body_mi)

	# Cabin
	var cabin_mi := MeshInstance3D.new()
	var cabin_m := BoxMesh.new()
	cabin_m.size = Vector3(1.9, 0.7, 2.6)
	cabin_mi.mesh = cabin_m
	cabin_mi.material_override = body_mat.duplicate()
	cabin_mi.position = Vector3(0, 1.05, 0.0)
	add_child(cabin_mi)

	# Roof ring for turret
	var ring_mi := MeshInstance3D.new()
	var ring_m := CylinderMesh.new()
	ring_m.top_radius = 0.45
	ring_m.bottom_radius = 0.45
	ring_m.height = 0.1
	ring_mi.mesh = ring_m
	ring_mi.material_override = body_mat.duplicate()
	turret_node.add_child(ring_mi)

	# Gun barrel
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.15, 0.15, 0.15)
	var barrel_mi := MeshInstance3D.new()
	var barrel_m := CylinderMesh.new()
	barrel_m.top_radius = 0.04
	barrel_m.bottom_radius = 0.05
	barrel_m.height = 1.8
	barrel_mi.mesh = barrel_m
	barrel_mi.material_override = bmat
	barrel_mi.rotation_degrees = Vector3(90, 0, 0)
	barrel_mi.position = Vector3(0, 0, -0.9)
	gun_pivot.add_child(barrel_mi)

	# Wheels (4 simple cylinders)
	var wheel_mat := StandardMaterial3D.new()
	wheel_mat.albedo_color = Color(0.1, 0.1, 0.1)
	wheel_mat.roughness = 0.95
	var wheel_positions := [
		Vector3(-1.1, 0.0, -1.4),
		Vector3( 1.1, 0.0, -1.4),
		Vector3(-1.1, 0.0,  1.4),
		Vector3( 1.1, 0.0,  1.4),
	]
	for wpos in wheel_positions:
		var wmi := MeshInstance3D.new()
		var wm := CylinderMesh.new()
		wm.top_radius = WHEEL_RADIUS
		wm.bottom_radius = WHEEL_RADIUS
		wm.height = 0.22
		wmi.mesh = wm
		wmi.material_override = wheel_mat.duplicate()
		wmi.rotation_degrees = Vector3(0, 0, 90)
		wmi.position = wpos
		add_child(wmi)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if not is_occupied:
		return
	if event is InputEventMouseMotion and not freelook_active:
		mouse_input = Vector2.ZERO
		if not _is_driver:
			_turret_yaw -= event.relative.x * TURRET_SENSITIVITY
			_gun_pitch   -= event.relative.y * TURRET_SENSITIVITY
			_gun_pitch = clampf(_gun_pitch, GUN_MIN_PITCH, GUN_MAX_PITCH)


func _physics_process(delta: float) -> void:
	_apply_suspension(delta)
	super._physics_process(delta)
	_apply_ground_passive(delta)


func _process(delta: float) -> void:
	super._process(delta)
	if turret_node:
		turret_node.rotation.y = _turret_yaw
	if gun_pivot:
		gun_pivot.rotation.x = _gun_pitch


func _process_inputs(_delta: float) -> void:
	mouse_input = Vector2.ZERO
	_throttle = 0.0
	_brake = 0.0
	if _is_driver:
		var fwd_spd := (-global_transform.basis.z).dot(linear_velocity)
		if Input.is_action_pressed("collective_up"):
			if fwd_spd < -1.0:
				_brake = 1.0
			else:
				_throttle = 1.0
		if Input.is_action_pressed("collective_down"):
			if fwd_spd > 1.0:
				_brake = 1.0
			else:
				_throttle = -1.0
		var steer := clampf(
			Input.get_axis("pedal_right", "pedal_left") + Input.get_axis("move_right", "move_left"),
			-1.0, 1.0)
		var tgt := steer * MAX_STEER
		if absf(steer) > 0.1:
			_cur_steer = move_toward(_cur_steer, tgt, 5.0 * MAX_STEER * get_physics_process_delta_time())
		else:
			_cur_steer = move_toward(_cur_steer, 0.0, 8.0 * MAX_STEER * get_physics_process_delta_time())
	else:
		# Gunner: aim roof gun and fire
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and gun_node and muzzle_point:
			gun_node.fire(muzzle_point.global_position,
					-muzzle_point.global_transform.basis.z, linear_velocity)


func _apply_flight_physics(_delta: float) -> void:
	var fwd := -global_transform.basis.z
	var up  := global_transform.basis.y
	var fwd_spd := fwd.dot(linear_velocity)
	if _throttle != 0 and absf(fwd_spd) < DRIVE_MAX_SPEED:
		apply_central_force(fwd * ENGINE_POWER * _throttle)
	if _brake > 0 and linear_velocity.length() > 0.5:
		apply_central_force(-linear_velocity.normalized() * BRAKE_POWER)
	if absf(_cur_steer) > 0.5 and absf(fwd_spd) > 0.5:
		var steer_rad := deg_to_rad(_cur_steer)
		var diff := fwd_spd * tan(steer_rad) / WHEELBASE - angular_velocity.dot(up)
		apply_torque(up * diff * mass * 1.2)


func _apply_ground_passive(_delta: float) -> void:
	if not is_occupied:
		_throttle = 0.0
		_brake = 1.0
		if linear_velocity.length() > 0.1:
			apply_central_force(-linear_velocity.normalized() * BRAKE_POWER * 0.6)
		if angular_velocity.length() > 0.02:
			apply_torque(-angular_velocity * mass * 5.0)
	# Rolling resistance
	if linear_velocity.length() > 0.1:
		apply_central_force(-linear_velocity.normalized() * mass * 2.0)
	# Lateral tire friction
	var right := global_transform.basis.x
	var lat_vel := right.dot(linear_velocity)
	apply_central_force(-right * lat_vel * mass * 4.0)
	# Speed-dependent drag
	var speed := linear_velocity.length()
	apply_central_force(-linear_velocity * speed * 0.3)
	apply_torque(-angular_velocity * mass * 3.0)


func _apply_suspension(delta: float) -> void:
	var rays := [susp_ray_fl, susp_ray_fr, susp_ray_rl, susp_ray_rr]
	var ray_len := SUSP_TRAVEL + WHEEL_RADIUS
	for i in 4:
		if not rays[i] or not rays[i].is_colliding():
			_prev_comp[i] = 0.0
			continue
		var ray := rays[i] as RayCast3D
		var dist: float = ray.global_position.distance_to(ray.get_collision_point())
		var comp: float = clampf(ray_len - dist, 0.0, SUSP_TRAVEL)
		var cv: float = (comp - (_prev_comp[i] as float)) / delta
		_prev_comp[i] = comp
		var fmag: float = maxf(comp * SPRING_K + cv * DAMPING_C, 0.0)
		apply_force(ray.get_collision_normal() * fmag,
				ray.global_position - global_position)
