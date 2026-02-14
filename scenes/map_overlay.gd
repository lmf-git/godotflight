extends CanvasLayer

## Full-screen map overlay toggled with M key.
## Player-centered: regenerates around the player's true world position each time
## it's opened, accounting for floating origin shifts.
## Image generation runs on WorkerThreadPool to avoid main-thread hitches.

const MAP_SIZE := 256          # pixels (lower res, terrain is summarised)
const MIN_VIEW_RADIUS := 1500.0
const MAX_VIEW_RADIUS := 50000.0
const ZOOM_STEP := 1.3         # multiplier per scroll tick
const RUNWAY_HALF_W := 15.0
const RUNWAY_HALF_L := 750.0

var _view_radius := 12000.0    # current zoom level (meters from center to edge)
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


func _ready() -> void:
	visible = false
	_setup_noise()
	_build_ui()


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

	# Mac trackpad: two-finger scroll
	if event is InputEventPanGesture:
		if event.delta.y < -0.1:
			_zoom_in()
		elif event.delta.y > 0.1:
			_zoom_out()
		get_viewport().set_input_as_handled()

	# Mac trackpad: pinch to zoom
	if event is InputEventMagnifyGesture:
		if event.factor > 1.0:
			_zoom_in()
		elif event.factor < 1.0:
			_zoom_out()
		get_viewport().set_input_as_handled()


func _process(_delta: float) -> void:
	if not visible:
		return
	_update_marker()


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
	WorkerThreadPool.add_task(_build_map_image.bind(center.x, center.z, _view_radius))


func _build_map_image(cx: float, cz: float, radius: float) -> void:
	var img := Image.create(MAP_SIZE, MAP_SIZE, false, Image.FORMAT_RGB8)
	var extent := radius * 2.0
	for py in range(MAP_SIZE):
		var wz := cz + (float(py) / MAP_SIZE - 0.5) * extent
		for px in range(MAP_SIZE):
			var wx := cx + (float(px) / MAP_SIZE - 0.5) * extent

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
	_generate_map()


func _zoom_out() -> void:
	_view_radius = minf(_view_radius * ZOOM_STEP, MAX_VIEW_RADIUS)
	_generate_map()


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
	_marker.heading_angle = atan2(heading.x, heading.z)
	_marker.queue_redraw()

	var world_pos := _get_player_world_pos()
	_coords_label.text = "X: %.0f  Z: %.0f  Alt: %.0f m" % [world_pos.x, world_pos.z, world_pos.y]


# --- Inner class for the marker drawing ---

class _MarkerNode extends Control:
	const _MARKER_RADIUS := 6
	const _HEADING_LINE_LEN := 18
	var heading_angle: float = 0.0

	func _draw() -> void:
		draw_circle(Vector2.ZERO, _MARKER_RADIUS, Color.WHITE)
		draw_circle(Vector2.ZERO, _MARKER_RADIUS - 2, Color(1.0, 0.3, 0.2))
		var dir := Vector2(sin(heading_angle), cos(heading_angle))
		draw_line(Vector2.ZERO, dir * _HEADING_LINE_LEN, Color.WHITE, 2.0)
