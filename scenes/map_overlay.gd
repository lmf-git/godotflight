extends CanvasLayer

## Orbit-camera map — press M to open/close.
## Shows the real 3D world from a satellite/orbital camera.
## Terrain chunks render at all altitudes at progressively lower LOD.
## Drag to orbit, scroll/pinch to zoom, Shift+click to place a waypoint beacon.

const PLANET_RADIUS := 100_000.0
const _SAVE_PATH    := "user://map_settings.cfg"
const ZOOM_STEP     := 1.14
const MIN_DIST      :=    300.0    # just above ground
const MAX_DIST      := 500_000.0   # orbital altitude (~500 km)

# Orbit state
var _orbit_camera:  Camera3D
var _prev_camera:   Camera3D
var _orbit_yaw:     float = 0.0
var _orbit_pitch:   float = 1.45   # radians from horizontal (~83° = near top-down, above player)
var _orbit_dist:    float = 4_000.0  # start 4 km above player
var _dragging:      bool  = false

# Map terrain anchor — invisible node placed at the orbit surface focus.
# terrain_generator checks for the "map_terrain_anchor" group so it loads
# chunks wherever the map camera is looking, not just around the player.
var _map_anchor: Node3D

# Objective markers
var _objective_markers: Array[Vector2] = []
var _objective_nodes:   Array[Node3D]  = []

# Noise — used only to place beacons at the correct terrain height
var _noise: FastNoiseLite
var _max_height    := 120.0
var _flat_rect     := Rect2(-80, -900, 160, 1800)
var _blend_margin  := 150.0

# UI
var _coords_label: Label
var _overlay:      Control


# ──────────────────────────────────────────────────────────────────────────────
#  Lifecycle
# ──────────────────────────────────────────────────────────────────────────────

func _ready() -> void:
	visible = false
	_load_settings()
	_setup_noise()
	_build_ui()
	add_to_group("map_overlay")


func _setup_noise() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = 42
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.0008
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4


func _build_ui() -> void:
	# Top bar
	var top_bg := ColorRect.new()
	top_bg.color = Color(0, 0, 0, 0.60)
	top_bg.set_anchors_preset(Control.PRESET_TOP_WIDE)
	top_bg.custom_minimum_size = Vector2(0, 44)
	add_child(top_bg)

	var hint := Label.new()
	hint.text = "SATELLITE MAP  |  Drag to orbit  •  Scroll/pinch to zoom (ground → orbit → space)  •  Shift+click to place waypoint  •  M to close"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	hint.set_anchors_preset(Control.PRESET_TOP_WIDE)
	hint.custom_minimum_size = Vector2(0, 44)
	hint.add_theme_font_size_override("font_size", 15)
	add_child(hint)

	# Bottom bar
	var bot_bg := ColorRect.new()
	bot_bg.color = Color(0, 0, 0, 0.60)
	bot_bg.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	bot_bg.custom_minimum_size = Vector2(0, 34)
	add_child(bot_bg)

	_coords_label = Label.new()
	_coords_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coords_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_coords_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_coords_label.custom_minimum_size = Vector2(0, 34)
	_coords_label.add_theme_font_size_override("font_size", 15)
	add_child(_coords_label)

	# Full-screen drawing overlay (player marker + objective dots)
	_overlay = _MarkerOverlay.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.map_ref = self
	add_child(_overlay)


# ──────────────────────────────────────────────────────────────────────────────
#  Toggle
# ──────────────────────────────────────────────────────────────────────────────

func toggle() -> void:
	if not visible:
		_open_map()
	else:
		_close_map()
	visible = not visible


func _open_map() -> void:
	# Remember which camera was active
	_prev_camera = get_viewport().get_camera_3d()

	# Create the orbit camera once and keep it; near/far set dynamically per frame.
	if not _orbit_camera or not is_instance_valid(_orbit_camera):
		_orbit_camera = Camera3D.new()
		_orbit_camera.fov = 55.0
		get_tree().current_scene.add_child(_orbit_camera)

	# Map terrain anchor — tells terrain_generator to load at the orbit focus.
	if not _map_anchor or not is_instance_valid(_map_anchor):
		_map_anchor = Node3D.new()
		_map_anchor.add_to_group("map_terrain_anchor")
		get_tree().current_scene.add_child(_map_anchor)

	_orbit_camera.current = true
	_update_orbit_camera()


func _close_map() -> void:
	_dragging = false
	if _orbit_camera and is_instance_valid(_orbit_camera):
		_orbit_camera.current = false
	if _prev_camera and is_instance_valid(_prev_camera):
		_prev_camera.current = true
	_prev_camera = null
	# Remove the terrain anchor so chunks load around the player again.
	if _map_anchor and is_instance_valid(_map_anchor):
		_map_anchor.queue_free()
		_map_anchor = null


# ──────────────────────────────────────────────────────────────────────────────
#  Input
# ──────────────────────────────────────────────────────────────────────────────

func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not visible:
		return

	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_orbit_dist = maxf(_orbit_dist / ZOOM_STEP, MIN_DIST)
					_save_settings()
					_update_orbit_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_orbit_dist = minf(_orbit_dist * ZOOM_STEP, MAX_DIST)
					_save_settings()
					_update_orbit_camera()
			MOUSE_BUTTON_LEFT:
				if event.pressed and event.shift_pressed:
					_try_place_waypoint(event.position)
				elif event.pressed:
					_dragging = true
				else:
					_dragging = false
		get_viewport().set_input_as_handled()

	if event is InputEventMouseMotion and _dragging:
		_orbit_yaw   -= event.relative.x * 0.005
		_orbit_pitch  = clampf(_orbit_pitch - event.relative.y * 0.005, -PI * 0.499, PI * 0.499)
		_update_orbit_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventMagnifyGesture:
		_orbit_dist = clampf(_orbit_dist / event.factor, MIN_DIST, MAX_DIST)
		_update_orbit_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventPanGesture:
		_orbit_yaw   -= event.delta.x * 0.012
		_orbit_pitch  = clampf(_orbit_pitch - event.delta.y * 0.012, -PI * 0.499, PI * 0.499)
		_update_orbit_camera()
		get_viewport().set_input_as_handled()


# ──────────────────────────────────────────────────────────────────────────────
#  Per-frame
# ──────────────────────────────────────────────────────────────────────────────

func _process(_delta: float) -> void:
	_update_objective_beacons()
	if not visible:
		return
	# Re-position orbit camera every frame so it stays centred on the player
	# even while the floating-origin system shifts the world around.
	_update_orbit_camera()
	_update_coords()
	_overlay.queue_redraw()


func _update_orbit_camera() -> void:
	if not _orbit_camera or not is_instance_valid(_orbit_camera):
		return

	# Dynamic near/far covering the full planet from any altitude.
	# near keeps depth precision; far covers the entire sphere silhouette.
	_orbit_camera.near = clampf(_orbit_dist * 0.005, 5.0, 5000.0)
	_orbit_camera.far  = PLANET_RADIUS * 3.0 + _orbit_dist * 5.0

	var p := _orbit_pitch
	var y := _orbit_yaw

	# Orbit direction (unit vector from planet centre toward the camera).
	var orbit_dir := Vector3(cos(p) * sin(y), sin(p), cos(p) * cos(y))

	# Planet centre is fixed at (0, -PLANET_RADIUS, 0) in scene space.
	# Camera sits at surface + orbit_dist along orbit_dir.
	var planet_center := Vector3(0.0, -PLANET_RADIUS, 0.0)
	_orbit_camera.global_position = planet_center + orbit_dir * (PLANET_RADIUS + _orbit_dist)

	# look_at needs an up vector not parallel to the view direction.
	# Near the poles orbit_dir ≈ ±Y, so switch to a side vector to avoid gimbal lock.
	var up_hint := Vector3.UP if abs(orbit_dir.y) < 0.98 else Vector3(1.0, 0.0, 0.0)
	_orbit_camera.look_at(planet_center, up_hint)

	# Move the map terrain anchor to the sphere surface below the orbit camera.
	# Terrain chunks only exist on the northern hemisphere (cube-sphere top face),
	# so clamp orbit_dir to positive-Y before computing the surface focus.
	if _map_anchor and is_instance_valid(_map_anchor):
		var terrain_dir := orbit_dir
		if terrain_dir.y < 0.05:
			# Looking at or below equator: snap anchor to equatorial ring in yaw direction.
			terrain_dir = Vector3(terrain_dir.x, 0.05, terrain_dir.z).normalized()
		_map_anchor.global_position = planet_center + terrain_dir * PLANET_RADIUS


func _get_player_scene_pos() -> Vector3:
	# Use the first terrain_anchor (player or occupied vehicle) if available,
	# otherwise fall back to scene origin (where the player always is anyway).
	var anchors := get_tree().get_nodes_in_group("terrain_anchor")
	if not anchors.is_empty():
		return (anchors[0] as Node3D).global_position
	return Vector3.ZERO


func _update_coords() -> void:
	if not _prev_camera or not is_instance_valid(_prev_camera):
		return
	var world_off := _get_world_offset()
	var world_pos := _prev_camera.global_position + world_off
	_coords_label.text = "X: %.0f  Z: %.0f  Alt: %.0f m  |  View radius: %.0f m" % [
		world_pos.x, world_pos.z, world_pos.y, _orbit_dist
	]


# ──────────────────────────────────────────────────────────────────────────────
#  Waypoint placement (physics raycast through the orbit camera)
# ──────────────────────────────────────────────────────────────────────────────

func _try_place_waypoint(screen_pos: Vector2) -> void:
	if not _orbit_camera or not is_instance_valid(_orbit_camera):
		return
	var space      := _orbit_camera.get_world_3d().direct_space_state
	var ray_origin := _orbit_camera.project_ray_origin(screen_pos)
	var ray_dir    := _orbit_camera.project_ray_normal(screen_pos)
	var query      := PhysicsRayQueryParameters3D.create(
		ray_origin,
		ray_origin + ray_dir * (PLANET_RADIUS * 2.5 + _orbit_dist),
		1  # world layer
	)
	var hit := space.intersect_ray(query)
	if hit:
		var world_off := _get_world_offset()
		var hit_world: Vector3 = hit["position"] + world_off
		_add_objective_marker(hit_world.x, hit_world.z)


# ──────────────────────────────────────────────────────────────────────────────
#  Helpers
# ──────────────────────────────────────────────────────────────────────────────

func _get_world_offset() -> Vector3:
	var terrain: Node = get_parent().get_node_or_null("ProceduralTerrain")
	if terrain:
		return terrain._world_offset
	return Vector3.ZERO


# ──────────────────────────────────────────────────────────────────────────────
#  Objective markers
# ──────────────────────────────────────────────────────────────────────────────

func _add_objective_marker(wx: float, wz: float) -> void:
	for node in _objective_nodes:
		if is_instance_valid(node):
			node.queue_free()
	_objective_nodes.clear()
	_objective_markers.clear()

	_objective_markers.append(Vector2(wx, wz))
	var beacon := _create_objective_beacon(wx, wz)
	_objective_nodes.append(beacon)
	get_tree().current_scene.add_child(beacon)


func _create_objective_beacon(wx: float, wz: float) -> Node3D:
	var root := Node3D.new()
	root.add_to_group("objective_markers")
	root.set_meta("world_x", wx)
	root.set_meta("world_z", wz)

	var mesh_inst := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(4.0, 300.0, 4.0)
	mesh_inst.mesh = box
	mesh_inst.position = Vector3(0, 150.0, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.8, 0.0, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.7, 0.0)
	mat.emission_energy_multiplier = 3.0
	mesh_inst.material_override = mat
	root.add_child(mesh_inst)

	var light := OmniLight3D.new()
	light.position = Vector3(0, 300.0, 0)
	light.light_color = Color(1.0, 0.8, 0.0)
	light.light_energy = 4.0
	light.omni_range = 600.0
	root.add_child(light)
	return root


func _update_objective_beacons() -> void:
	var world_off := _get_world_offset()
	for i in _objective_nodes.size():
		var node: Node3D = _objective_nodes[i]
		if not is_instance_valid(node):
			continue
		var wx: float = _objective_markers[i].x
		var wz: float = _objective_markers[i].y
		var wy: float = _sample_height(wx, wz)
		node.global_position = Vector3(wx - world_off.x, wy, wz - world_off.z)


# ──────────────────────────────────────────────────────────────────────────────
#  Noise (mirrors terrain_generator.gd — used for beacon placement height)
# ──────────────────────────────────────────────────────────────────────────────

func _sample_height(world_x: float, world_z: float) -> float:
	var h := _noise.get_noise_2d(world_x, world_z) * _max_height
	h *= _runway_blend(world_x, world_z)
	# Sphere-surface Y (matches terrain_generator logic)
	var dir := Vector3(world_x, PLANET_RADIUS, world_z).normalized()
	return (dir * (PLANET_RADIUS + h)).y - PLANET_RADIUS


func _runway_blend(world_x: float, world_z: float) -> float:
	var dx := 0.0
	if world_x < _flat_rect.position.x:
		dx = _flat_rect.position.x - world_x
	elif world_x > _flat_rect.end.x:
		dx = world_x - _flat_rect.end.x
	var dz := 0.0
	if world_z < _flat_rect.position.y:
		dz = _flat_rect.position.y - world_z
	elif world_z > _flat_rect.end.y:
		dz = world_z - _flat_rect.end.y
	var dist := sqrt(dx * dx + dz * dz)
	if dist <= 0.0:
		return 0.0
	if dist >= _blend_margin:
		return 1.0
	var t := dist / _blend_margin
	return t * t * (3.0 - 2.0 * t)


# ──────────────────────────────────────────────────────────────────────────────
#  Settings persistence
# ──────────────────────────────────────────────────────────────────────────────

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("map", "view_radius", _orbit_dist)
	cfg.save(_SAVE_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_SAVE_PATH) == OK:
		_orbit_dist = cfg.get_value("map", "view_radius", 4000.0)


# ──────────────────────────────────────────────────────────────────────────────
#  Inner class: draws player marker + objective dots over the 3D view
# ──────────────────────────────────────────────────────────────────────────────

class _MarkerOverlay extends Control:
	var map_ref  # outer CanvasLayer reference

	func _draw() -> void:
		if not map_ref:
			return
		var cam: Camera3D = map_ref._orbit_camera
		if not cam or not is_instance_valid(cam) or not cam.current:
			return

		var world_off := Vector3.ZERO
		var terrain: Node = map_ref.get_parent().get_node_or_null("ProceduralTerrain")
		if terrain:
			world_off = terrain._world_offset

		# Player marker
		var prev: Camera3D = map_ref._prev_camera
		if prev and is_instance_valid(prev):
			var ppos := prev.global_position
			if cam.is_position_in_frustum(ppos):
				var sp := cam.unproject_position(ppos)
				draw_circle(sp, 9.0, Color.WHITE)
				draw_circle(sp, 7.0, Color(1.0, 0.3, 0.2))
				# Heading line: project a point forward in the player's look direction
				var fwd := -prev.global_basis.z
				var ahead := ppos + fwd * maxf(map_ref._orbit_dist * 0.02, 80.0)
				if cam.is_position_in_frustum(ahead):
					draw_line(sp, cam.unproject_position(ahead), Color.WHITE, 2.5)

		# Objective markers
		for marker: Vector2 in map_ref._objective_markers:
			var wpos := Vector3(marker.x - world_off.x, 0.0, marker.y - world_off.z)
			if cam.is_position_in_frustum(wpos):
				var sp := cam.unproject_position(wpos)
				draw_circle(sp, 7.0, Color(1.0, 0.85, 0.0))
				draw_arc(sp, 13.0, 0.0, TAU, 20, Color(1.0, 1.0, 0.5), 2.0)
				var arm := 6.0; var gap := 14.0
				var c := Color(1.0, 0.85, 0.0)
				draw_line(sp + Vector2(-gap - arm, 0), sp + Vector2(-gap, 0), c, 2.0)
				draw_line(sp + Vector2( gap, 0),        sp + Vector2( gap + arm, 0), c, 2.0)
				draw_line(sp + Vector2(0, -gap - arm),  sp + Vector2(0, -gap), c, 2.0)
				draw_line(sp + Vector2(0,  gap),        sp + Vector2(0, gap + arm), c, 2.0)
