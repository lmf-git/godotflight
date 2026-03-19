extends CanvasLayer

## Full-screen map overlay toggled with M key.
## Player-centered: regenerates around the player's true world position each time
## it's opened, accounting for floating origin shifts.
## Image generation runs on WorkerThreadPool to avoid main-thread hitches.

const MAP_SIZE := 256          # pixels (lower res, terrain is summarised)
const MIN_VIEW_RADIUS := 1500.0
const MAX_VIEW_RADIUS := 50000.0
const ZOOM_STEP := 1.12        # multiplier per scroll tick
const RUNWAY_HALF_W := 15.0
const RUNWAY_HALF_L := 750.0
const _SAVE_PATH := "user://map_settings.cfg"

var _view_radius := 12000.0    # current zoom level (meters from center to edge)
var _pan_accum := 0.0          # accumulated trackpad pan delta
var _terrain_tex: ImageTexture
var _noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _max_height := 120.0
var _flat_rect := Rect2(-80, -900, 160, 1800)
var _blend_margin := 150.0
var _generating := false

var _bg: ColorRect
var _map_rect: TextureRect
var _marker: Control
var _coords_label: Label
var _objective_overlay: Control

var _objective_markers: Array[Vector2] = []   # world (X, Z) per marker
var _objective_nodes: Array[Node3D] = []      # 3D beacon per marker
var _map_center_x: float = 0.0
var _map_center_z: float = 0.0


func _ready() -> void:
	visible = false
	_load_settings()
	_setup_noise()
	_build_ui()
	add_to_group("map_overlay")

func toggle() -> void:
	visible = not visible
	if visible:
		_generate_map()
	else:
		_free_map_texture()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		visible = not visible
		if visible:
			_generate_map()
		else:
			_free_map_texture()
		get_viewport().set_input_as_handled()
		return

	if not visible:
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_in()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_out()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed and event.shift_pressed:
			var local_pos := _map_rect.get_local_mouse_position()
			var u := local_pos.x / _map_rect.size.x
			var v := local_pos.y / _map_rect.size.y
			if u >= 0.0 and u <= 1.0 and v >= 0.0 and v <= 1.0:
				var extent := _view_radius * 2.0
				var wx := _map_center_x - (u - 0.5) * extent
				var wz := _map_center_z + (0.5 - v) * extent
				_add_objective_marker(wx, wz)
			get_viewport().set_input_as_handled()

	# Mac trackpad: two-finger scroll — accumulate to avoid over-sensitivity
	if event is InputEventPanGesture:
		_pan_accum += event.delta.y
		if _pan_accum < -8.0:
			_zoom_in()
			_pan_accum = 0.0
		elif _pan_accum > 8.0:
			_zoom_out()
			_pan_accum = 0.0
		get_viewport().set_input_as_handled()

	# Mac trackpad: pinch to zoom
	if event is InputEventMagnifyGesture:
		if event.factor > 1.0:
			_zoom_in()
		elif event.factor < 1.0:
			_zoom_out()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	_update_objective_beacons()
	if not visible:
		return
	_update_marker()
	if _objective_overlay:
		_objective_overlay.queue_redraw()


func _get_world_offset() -> Vector3:
	var terrain := get_parent().get_node_or_null("ProceduralTerrain")
	if terrain:
		return terrain._world_offset
	return Vector3.ZERO


func _get_player_world_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return Vector3.ZERO
	return cam.global_position + _get_world_offset()


# --- Noise setup (mirrors terrain_generator.gd) ---

func _setup_noise() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = 42
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.0008
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = 42 + 7
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.frequency = 0.004
	_detail_noise.fractal_octaves = 2


# --- UI construction ---

func _build_ui() -> void:
	_bg = ColorRect.new()
	_bg.color = Color(0, 0, 0, 0.75)
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)

	_map_rect = TextureRect.new()
	_map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_map_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_bg.add_child(_map_rect)

	_marker = _MarkerNode.new()
	_map_rect.add_child(_marker)

	var obj_overlay := _ObjectiveOverlay.new()
	obj_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	obj_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	obj_overlay.map_ref = self
	_map_rect.add_child(obj_overlay)
	_objective_overlay = obj_overlay

	_coords_label = Label.new()
	_coords_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_coords_label.add_theme_font_size_override("font_size", 18)
	_bg.add_child(_coords_label)

	get_viewport().size_changed.connect(_layout)
	_layout.call_deferred()


func _layout() -> void:
	var vp_size := get_viewport().get_visible_rect().size
	var map_px := int(vp_size.y * 0.80)
	_map_rect.custom_minimum_size = Vector2(map_px, map_px)
	_map_rect.size = Vector2(map_px, map_px)
	_map_rect.position = Vector2((vp_size.x - map_px) * 0.5, (vp_size.y - map_px) * 0.5)

	_coords_label.size = Vector2(vp_size.x, 30)
	_coords_label.position = Vector2(0, _map_rect.position.y + map_px + 8)


# --- Map image generation (threaded, centered on player) ---

func _generate_map() -> void:
	if _generating:
		return
	_generating = true
	var center := _get_player_world_pos()
	_map_center_x = center.x
	_map_center_z = center.z
	WorkerThreadPool.add_task(_build_map_image.bind(center.x, center.z, _view_radius))


func _build_map_image(cx: float, cz: float, radius: float) -> void:
	var img := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8)
	var extent := radius * 2.0
	for py in range(MAP_SIZE):
		var wz := cz + (0.5 - float(py) / MAP_SIZE) * extent
		for px in range(MAP_SIZE):
			var wx := cx - (float(px) / MAP_SIZE - 0.5) * extent

			if abs(wx) <= RUNWAY_HALF_W and abs(wz) <= RUNWAY_HALF_L:
				img.set_pixel(px, py, Color(0.25, 0.25, 0.25))
				continue

			var h := _sample_height(wx, wz)
			img.set_pixel(px, py, _height_color(h, wx, wz))

	_apply_map_image.call_deferred(img)


func _apply_map_image(img: Image) -> void:
	_generating = false
	_terrain_tex = ImageTexture.create_from_image(img)
	_map_rect.texture = _terrain_tex


func _free_map_texture() -> void:
	_map_rect.texture = null
	_terrain_tex = null


func _zoom_in() -> void:
	_view_radius = maxf(_view_radius / ZOOM_STEP, MIN_VIEW_RADIUS)
	_save_settings()
	_generate_map()


func _zoom_out() -> void:
	_view_radius = minf(_view_radius * ZOOM_STEP, MAX_VIEW_RADIUS)
	_save_settings()
	_generate_map()


func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("map", "view_radius", _view_radius)
	cfg.save(_SAVE_PATH)


func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(_SAVE_PATH) == OK:
		_view_radius = cfg.get_value("map", "view_radius", 12000.0)


func _sample_height(world_x: float, world_z: float) -> float:
	var h := _noise.get_noise_2d(world_x, world_z) * _max_height
	h += _detail_noise.get_noise_2d(world_x, world_z) * _max_height * 0.15
	return h * _runway_blend(world_x, world_z)


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


func _height_color(h: float, world_x: float, world_z: float) -> Color:
	if _runway_blend(world_x, world_z) < 0.1:
		return Color(0.35, 0.52, 0.25)
	var base_green := Color(0.3, 0.48, 0.2)
	var dark_green := Color(0.2, 0.35, 0.12)
	var brown := Color(0.4, 0.32, 0.18)
	var rock := Color(0.45, 0.42, 0.38)
	var norm_h := clampf(h / _max_height, -1.0, 1.0)
	if norm_h < 0.0:
		return dark_green.lerp(base_green, norm_h + 1.0)
	elif norm_h < 0.5:
		return base_green.lerp(brown, norm_h * 2.0)
	else:
		return brown.lerp(rock, (norm_h - 0.5) * 2.0)


# --- Player marker (always centered) ---

func _update_marker() -> void:
	var cam := get_viewport().get_camera_3d()
	if not cam:
		return

	var map_px := _map_rect.size.x
	_marker.position = Vector2(map_px * 0.5, map_px * 0.5)

	var heading := -cam.global_basis.z
	_marker.heading_angle = atan2(heading.x, -heading.z)
	_marker.queue_redraw()

	var world_pos := _get_player_world_pos()
	_coords_label.text = "X: %.0f  Z: %.0f  Alt: %.0f m" % [world_pos.x, world_pos.z, world_pos.y]


# --- Objective markers ---

func _world_to_map_pixel(wx: float, wz: float) -> Vector2:
	var extent := _view_radius * 2.0
	var u := 0.5 - (wx - _map_center_x) / extent
	var v := 0.5 - (wz - _map_center_z) / extent
	return Vector2(u * _map_rect.size.x, v * _map_rect.size.y)


func _add_objective_marker(wx: float, wz: float) -> void:
	# Clear existing marker first
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
		node.global_position = Vector3(wx - world_off.x, 0.0, wz - world_off.z)


# --- Inner class for map objective overlay ---

class _ObjectiveOverlay extends Control:
	var map_ref  # reference to the map_overlay node

	func _draw() -> void:
		if not map_ref or map_ref._objective_markers.is_empty():
			return
		for marker: Vector2 in map_ref._objective_markers:
			var px: Vector2 = map_ref._world_to_map_pixel(marker.x, marker.y)
			if px.x < -16 or px.x > size.x + 16 or px.y < -16 or px.y > size.y + 16:
				continue
			var c := Color(1.0, 0.85, 0.0)
			draw_circle(px, 6.0, c)
			draw_arc(px, 11.0, 0, TAU, 20, Color(1.0, 1.0, 0.5), 2.0)
			var arm := 6.0
			var gap := 12.0
			draw_line(px + Vector2(-gap - arm, 0), px + Vector2(-gap, 0), c, 2.0)
			draw_line(px + Vector2(gap, 0), px + Vector2(gap + arm, 0), c, 2.0)
			draw_line(px + Vector2(0, -gap - arm), px + Vector2(0, -gap), c, 2.0)
			draw_line(px + Vector2(0, gap), px + Vector2(0, gap + arm), c, 2.0)


# --- Inner class for the marker drawing ---

class _MarkerNode extends Control:
	const _MARKER_RADIUS := 6
	const _HEADING_LINE_LEN := 18
	var heading_angle: float = 0.0

	func _draw() -> void:
		draw_circle(Vector2.ZERO, _MARKER_RADIUS, Color.WHITE)
		draw_circle(Vector2.ZERO, _MARKER_RADIUS - 2, Color(1.0, 0.3, 0.2))
		var dir := Vector2(-sin(heading_angle), cos(heading_angle))
		draw_line(Vector2.ZERO, dir * _HEADING_LINE_LEN, Color.WHITE, 2.0)
