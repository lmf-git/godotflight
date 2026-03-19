extends Vehicle
class_name Tank

## Armored tank with a mouse-aimed turret.
## Mouse X = turret yaw, Mouse Y = barrel pitch.
## LMB fires the cannon (hitscan, 3.5s cooldown).

# Ground physics
const ENGINE_POWER := 300000.0
const BRAKE_POWER  := 200000.0
const DRIVE_MAX_SPEED := 12.0  # m/s
const WHEELBASE    := 3.5      # m
const MAX_STEER    := 25.0     # degrees

const SPRING_K     := 120000.0
const DAMPING_C    := 10000.0
const SUSP_TRAVEL  := 0.2
const WHEEL_RADIUS := 0.45

# Turret
const TURRET_SENSITIVITY := 0.003
const BARREL_MAX_PITCH   := 0.35   # ~20° up
const BARREL_MIN_PITCH   := -0.08  # ~4.5° down
const CANNON_COOLDOWN    := 3.5
const CANNON_RANGE       := 3000.0

var _turret_yaw   := 0.0
var _barrel_pitch := 0.0
var _cannon_timer := 0.0
var _throttle     := 0.0
var _brake        := 0.0
var _cur_steer    := 0.0
var _prev_comp    := [0.0, 0.0, 0.0, 0.0]
var _is_driver    := true   # true = drives tank; false = aims turret and fires

@onready var turret_node  : Node3D   = $Turret
@onready var barrel_node  : Node3D   = $Turret/Barrel
@onready var muzzle_point : Marker3D = $Turret/Barrel/MuzzlePoint
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
	mass = 40000.0
	contact_monitor = true
	max_contacts_reported = 4
	collision_layer = 4
	collision_mask = 5
	_build_mesh()


func _build_mesh() -> void:
	var hull_mat := StandardMaterial3D.new()
	hull_mat.albedo_color = Color(0.28, 0.35, 0.15)
	hull_mat.roughness = 0.9

	# Hull body
	var hull_mi := MeshInstance3D.new()
	var hull_m := BoxMesh.new()
	hull_m.size = Vector3(3.8, 1.0, 7.0)
	hull_mi.mesh = hull_m
	hull_mi.material_override = hull_mat
	hull_mi.position = Vector3(0, 0.5, 0)
	add_child(hull_mi)

	# Tracks
	var track_mat := StandardMaterial3D.new()
	track_mat.albedo_color = Color(0.12, 0.12, 0.12)
	track_mat.roughness = 1.0
	for side in [-1, 1]:
		var track_mi := MeshInstance3D.new()
		var tm := BoxMesh.new()
		tm.size = Vector3(0.55, 0.55, 7.4)
		track_mi.mesh = tm
		track_mi.material_override = track_mat
		track_mi.position = Vector3(side * 2.2, 0.1, 0)
		add_child(track_mi)

	# Turret base disc
	var tb := MeshInstance3D.new()
	var tb_m := CylinderMesh.new()
	tb_m.top_radius = 1.3
	tb_m.bottom_radius = 1.3
	tb_m.height = 0.2
	tb.mesh = tb_m
	tb.material_override = hull_mat.duplicate()
	turret_node.add_child(tb)

	# Turret box
	var tt := MeshInstance3D.new()
	var tt_m := BoxMesh.new()
	tt_m.size = Vector3(2.4, 0.7, 2.6)
	tt.mesh = tt_m
	tt.material_override = hull_mat.duplicate()
	tt.position = Vector3(0, 0.45, 0)
	turret_node.add_child(tt)

	# Barrel
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = Color(0.18, 0.22, 0.1)
	bmat.roughness = 0.85
	var bmi := MeshInstance3D.new()
	var bm := CylinderMesh.new()
	bm.top_radius = 0.09
	bm.bottom_radius = 0.13
	bm.height = 3.0
	bmi.mesh = bm
	bmi.material_override = bmat
	bmi.rotation_degrees = Vector3(90, 0, 0)
	bmi.position = Vector3(0, 0, -1.5)
	barrel_node.add_child(bmi)


func _unhandled_input(event: InputEvent) -> void:
	super._unhandled_input(event)
	if not is_occupied:
		return
	if event is InputEventMouseMotion and not freelook_active:
		mouse_input = Vector2.ZERO  # prevent base class from accumulating for flight
		if not _is_driver:
			_turret_yaw -= event.relative.x * TURRET_SENSITIVITY
			_barrel_pitch -= event.relative.y * TURRET_SENSITIVITY
			_barrel_pitch = clampf(_barrel_pitch, BARREL_MIN_PITCH, BARREL_MAX_PITCH)


func _physics_process(delta: float) -> void:
	_apply_suspension(delta)
	super._physics_process(delta)
	_apply_ground_passive(delta)


func _process(delta: float) -> void:
	super._process(delta)
	if _cannon_timer > 0:
		_cannon_timer -= delta
	if turret_node:
		turret_node.rotation.y = _turret_yaw
	if barrel_node:
		barrel_node.rotation.x = _barrel_pitch


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
			_cur_steer = move_toward(_cur_steer, 0.0, 10.0 * MAX_STEER * get_physics_process_delta_time())
	else:
		# Gunner: aim turret and fire (steering/throttle stay zero)
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and _cannon_timer <= 0:
			_fire_cannon()


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
		apply_torque(up * diff * mass * 1.0)


func _apply_ground_passive(_delta: float) -> void:
	if not is_occupied:
		_throttle = 0.0
		_brake = 1.0
		if linear_velocity.length() > 0.1:
			apply_central_force(-linear_velocity.normalized() * BRAKE_POWER * 0.8)
		if angular_velocity.length() > 0.02:
			apply_torque(-angular_velocity * mass * 5.0)
	# Rolling resistance
	if linear_velocity.length() > 0.1:
		apply_central_force(-linear_velocity.normalized() * mass * 3.0)
	# Tracks resist lateral movement strongly
	var right := global_transform.basis.x
	var lat_vel := right.dot(linear_velocity)
	apply_central_force(-right * lat_vel * mass * 8.0)
	apply_torque(-angular_velocity * mass * 5.0)


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


func _fire_cannon() -> void:
	if not muzzle_point:
		return
	_cannon_timer = CANNON_COOLDOWN
	var mpos := muzzle_point.global_position
	var fdir := -muzzle_point.global_transform.basis.z

	_spawn_barrel_smoke(mpos)
	_spawn_muzzle_blast(mpos)

	var shell := RigidBody3D.new()
	shell.mass = 10.0
	shell.gravity_scale = 0.15
	shell.collision_layer = 8
	shell.collision_mask = 5
	shell.contact_monitor = true
	shell.max_contacts_reported = 1

	var smi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.12
	sm.height = 0.24
	sm.radial_segments = 6
	sm.rings = 3
	smi.mesh = sm
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.12, 0.10, 0.08)
	smat.roughness = 0.8
	smi.material_override = smat
	smi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.add_child(smi)

	var col := CollisionShape3D.new()
	var cshape := SphereShape3D.new()
	cshape.radius = 0.14
	col.shape = cshape
	shell.add_child(col)

	get_tree().current_scene.add_child(shell)
	shell.global_position = mpos + fdir * 0.5  # start just past muzzle
	shell.linear_velocity = linear_velocity + fdir * 400.0
	shell.add_collision_exception_with(self)

	shell.body_entered.connect(_on_shell_hit.bind(shell))

	var timer := Timer.new()
	timer.wait_time = 5.0
	timer.one_shot = true
	timer.timeout.connect(func(): if is_instance_valid(shell): shell.queue_free())
	shell.add_child(timer)
	timer.start()

func _on_shell_hit(body: Node, shell: RigidBody3D) -> void:
	if not is_instance_valid(shell):
		return
	var hit_pos := shell.global_position
	var hit: Node = body
	while hit:
		if hit.has_method("take_hit"):
			hit.take_hit(hit_pos)
			hit.take_hit(hit_pos)  # double hit from cannon round
			break
		hit = hit.get_parent() if hit.get_parent() is Node3D else null
	shell.queue_free()
	_spawn_explosion(hit_pos)

func _spawn_barrel_smoke(world_pos: Vector3) -> void:
	for i in 4:
		var s := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.2 + randf() * 0.15
		sm.height = sm.radius * 2.0
		sm.radial_segments = 6
		sm.rings = 3
		s.mesh = sm
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.65, 0.62, 0.6, 0.6)
		s.material_override = mat
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		get_tree().current_scene.add_child(s)
		s.global_position = world_pos + Vector3(
			randf_range(-0.25, 0.25),
			randf_range(0.0, 0.3),
			randf_range(-0.25, 0.25)
		)
		var tw := s.create_tween()
		tw.tween_property(s, "scale", Vector3(6, 6, 6), 1.5)
		tw.parallel().tween_method(
			func(a: float): mat.albedo_color.a = a,
			0.6, 0.0, 1.5
		)
		tw.tween_callback(s.queue_free)


func _spawn_explosion(world_pos: Vector3) -> void:
	var root := Node3D.new()
	get_tree().current_scene.add_child(root)
	root.global_position = world_pos
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.4, 0.05)
	mat.emission_energy_multiplier = 8.0
	mat.albedo_color = Color(1.0, 0.55, 0.1, 1.0)
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	var mi := MeshInstance3D.new()
	mi.mesh = sphere
	mi.material_override = mat
	root.add_child(mi)
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.6, 0.2)
	light.light_energy = 20.0
	light.omni_range = 25.0
	root.add_child(light)
	var tw := root.create_tween()
	tw.tween_property(root, "scale", Vector3(6, 6, 6), 0.5)
	tw.parallel().tween_method(
		func(a: float): mat.albedo_color.a = a; mat.emission_energy_multiplier = a * 8.0,
		1.0, 0.0, 0.5)
	tw.tween_callback(root.queue_free)


func _spawn_muzzle_blast(world_pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.9, 0.4)
	light.light_energy = 20.0
	light.omni_range = 25.0
	get_tree().current_scene.add_child(light)
	light.global_position = world_pos
	var tw := light.create_tween()
	tw.tween_property(light, "light_energy", 0.0, 0.12)
	tw.tween_callback(light.queue_free)
