extends CanvasLayer

## Full-planet globe view — press G to toggle.
## Generates a low-detail sphere mesh using the same noise and biome colours as the
## terrain generator.  Equator = runway latitude (wz = 0); poles = |wz| >> 0.
## Orbit controls: drag to rotate, scroll / pinch to zoom.

const PLANET_RADIUS  := 600_000.0
const DISPLAY_RADIUS := 1500.0   # metres in the SubViewport scene
const HEIGHT_SCALE   := 150.0    # terrain height exaggeration on the globe
const N_THETA        := 72       # latitude  divisions (pole to pole)
const N_PHI          := 72       # longitude divisions

# Noise — must match terrain_generator.gd and map_overlay.gd seeds exactly
const TERRAIN_SEED   := 42

# Flat zone (must match terrain_generator.gd defaults)
const FLAT_RECT      := Rect2(-80, -900, 160, 1800)
const BLEND_MARGIN   := 150.0
const MAX_HEIGHT     := 120.0

var _viewport: SubViewport
var _camera: Camera3D
var _globe_inst: MeshInstance3D
var _label: Label

var _orbit_yaw:   float = 0.2
var _orbit_pitch: float = 0.0
var _orbit_dist:  float = 3800.0
var _dragging:    bool  = false
var _building:    bool  = false
var _built:       bool  = false   # rebuild only once per session

var _noise:    FastNoiseLite
var _detail:   FastNoiseLite
var _moisture: FastNoiseLite


func _ready() -> void:
	visible = false
	layer = 15
	_setup_noise()
	_build_ui()


func _setup_noise() -> void:
	_noise = FastNoiseLite.new()
	_noise.seed = TERRAIN_SEED
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.0008
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 4
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5

	_detail = FastNoiseLite.new()
	_detail.seed = TERRAIN_SEED + 7
	_detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail.frequency = 0.004
	_detail.fractal_octaves = 2

	_moisture = FastNoiseLite.new()
	_moisture.seed = TERRAIN_SEED + 31
	_moisture.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture.frequency = 0.00012
	_moisture.fractal_octaves = 3


func _build_ui() -> void:
	# Dark space background
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.02, 0.06, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# SubViewport for the 3D globe
	var container := SubViewportContainer.new()
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	container.stretch = true
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.size = Vector2i(1920, 1080)
	_viewport.transparent_bg = true
	_viewport.handle_input_locally = false
	container.add_child(_viewport)

	# Ambient + directional lighting
	var env := Environment.new()
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.40, 0.55)
	env.ambient_light_energy = 0.8
	var we := WorldEnvironment.new()
	we.environment = env
	_viewport.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.rotation = Vector3(-0.6, 0.8, 0.0)
	_viewport.add_child(sun)

	# Camera
	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.near = 1.0
	_camera.far = 50000.0
	_viewport.add_child(_camera)

	# Globe mesh placeholder
	_globe_inst = MeshInstance3D.new()
	_viewport.add_child(_globe_inst)

	# HUD label
	_label = Label.new()
	_label.text = "GLOBE VIEW  —  building…"
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", 18)
	_label.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_label.position.y -= 50.0
	add_child(_label)

	_update_camera()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_globe"):
		visible = not visible
		if visible and not _built:
			_start_build()
		if visible:
			_label.text = "GLOBE VIEW  |  Drag to orbit  •  Scroll / pinch to zoom  •  G to exit"
		get_viewport().set_input_as_handled()
		return

	if not visible:
		return

	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				_dragging = event.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_orbit_dist = maxf(_orbit_dist / 1.12, DISPLAY_RADIUS * 1.4)
					_update_camera()
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_orbit_dist = minf(_orbit_dist * 1.12, DISPLAY_RADIUS * 14.0)
					_update_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventMouseMotion and _dragging:
		_orbit_yaw   -= event.relative.x * 0.005
		_orbit_pitch  = clampf(_orbit_pitch - event.relative.y * 0.005, -1.50, 1.50)
		_update_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventMagnifyGesture:
		_orbit_dist = clampf(
			_orbit_dist / event.factor,
			DISPLAY_RADIUS * 1.4, DISPLAY_RADIUS * 14.0)
		_update_camera()
		get_viewport().set_input_as_handled()

	if event is InputEventPanGesture:
		_orbit_yaw   -= event.delta.x * 0.012
		_orbit_pitch  = clampf(_orbit_pitch - event.delta.y * 0.012, -1.50, 1.50)
		_update_camera()
		get_viewport().set_input_as_handled()


func _update_camera() -> void:
	if not _camera:
		return
	var x := _orbit_dist * cos(_orbit_pitch) * sin(_orbit_yaw)
	var y := _orbit_dist * sin(_orbit_pitch)
	var z := _orbit_dist * cos(_orbit_pitch) * cos(_orbit_yaw)
	_camera.global_position = Vector3(x, y, z)
	if _camera.global_position.length() > 0.01:
		var up := Vector3.UP
		if absf(_camera.global_position.normalized().dot(up)) > 0.98:
			up = Vector3.FORWARD
		_camera.look_at(Vector3.ZERO, up)


# --- Globe mesh generation (worker thread) ---

func _start_build() -> void:
	if _building:
		return
	_building = true
	_label.text = "GLOBE VIEW  —  building…"
	WorkerThreadPool.add_task(_build_globe_mesh)


func _build_globe_mesh() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Precompute per-vertex position and colour on the unit sphere grid
	# theta: 0 (north pole, wz=+PR) → PI (south pole, wz=-PR)
	# phi:   0 → TAU around the equator
	# World coords: wx = PR*sin(θ)*cos(ψ)   wz = PR*cos(θ)

	var verts := []    # Array of Vector3
	var colors := []   # Array of Color
	var n1 := N_THETA + 1
	var n2 := N_PHI + 1

	for i_t in range(n1):
		var theta := float(i_t) / N_THETA * PI
		for i_p in range(n2):
			var phi := float(i_p) / N_PHI * TAU
			var wx := PLANET_RADIUS * sin(theta) * cos(phi)
			var wz := PLANET_RADIUS * cos(theta)
			var h   := _sample_h(wx, wz)
			var r   := DISPLAY_RADIUS + h * (DISPLAY_RADIUS / PLANET_RADIUS) * HEIGHT_SCALE
			var dir := Vector3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi))
			verts.append(dir * r)
			colors.append(_biome_color(h, wx, wz))

	# Build triangle strip quads
	for i_t in range(N_THETA):
		for i_p in range(N_PHI):
			var i00 := i_t * n2 + i_p
			var i10 := (i_t + 1) * n2 + i_p
			var i01 := i_t * n2 + (i_p + 1)
			var i11 := (i_t + 1) * n2 + (i_p + 1)
			for idx in [i00, i10, i01,  i10, i11, i01]:
				var v: Vector3 = verts[idx]
				st.set_color(colors[idx])
				st.set_normal(v.normalized())
				st.add_vertex(v)

	_apply_mesh.call_deferred(st.commit())


func _apply_mesh(mesh: ArrayMesh) -> void:
	_building = false
	_built = true
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	_globe_inst.mesh = mesh
	_globe_inst.material_override = mat
	_label.text = "GLOBE VIEW  |  Drag to orbit  •  Scroll / pinch to zoom  •  G to exit"


# --- Noise helpers (mirrors terrain_generator.gd / map_overlay.gd) ---

func _sample_h(wx: float, wz: float) -> float:
	var h := _noise.get_noise_2d(wx, wz) * MAX_HEIGHT
	h += _detail.get_noise_2d(wx, wz) * MAX_HEIGHT * 0.15
	return h * _runway_blend(wx, wz)


func _runway_blend(wx: float, wz: float) -> float:
	var dx := 0.0
	if wx < FLAT_RECT.position.x:
		dx = FLAT_RECT.position.x - wx
	elif wx > FLAT_RECT.end.x:
		dx = wx - FLAT_RECT.end.x
	var dz := 0.0
	if wz < FLAT_RECT.position.y:
		dz = FLAT_RECT.position.y - wz
	elif wz > FLAT_RECT.end.y:
		dz = wz - FLAT_RECT.end.y
	var dist := sqrt(dx * dx + dz * dz)
	if dist <= 0.0:
		return 0.0
	if dist >= BLEND_MARGIN:
		return 1.0
	var t := dist / BLEND_MARGIN
	return t * t * (3.0 - 2.0 * t)


func _biome_color(h: float, wx: float, wz: float) -> Color:
	if _runway_blend(wx, wz) < 0.1:
		return Color(0.35, 0.52, 0.25)

	var norm_h := clampf(h / MAX_HEIGHT, -1.0, 1.0)

	# Water
	if norm_h < -0.25:
		return Color(0.04, 0.12, 0.42).lerp(Color(0.10, 0.30, 0.60),
				clampf((norm_h + 1.0) / 0.75, 0.0, 1.0))
	if norm_h < -0.05:
		return Color(0.10, 0.30, 0.60).lerp(Color(0.20, 0.55, 0.65),
				clampf((norm_h + 0.25) / 0.20, 0.0, 1.0))
	if norm_h < 0.02:
		return Color(0.78, 0.72, 0.50)

	# Temperature driven by latitude (|wz| distance from equator) and elevation
	var lat_t := clampf(absf(wz) / 50000.0, 0.0, 1.0)
	var temp  := clampf(1.0 - lat_t * 1.5 - norm_h * 0.35, 0.0, 1.0)
	var moist := clampf(_moisture.get_noise_2d(wx, wz) * 0.5 + 0.5, 0.0, 1.0)

	if norm_h > 0.65:
		var t := clampf((norm_h - 0.65) / 0.25, 0.0, 1.0)
		return Color(0.45, 0.40, 0.35).lerp(Color(0.93, 0.95, 0.98), t)

	if temp < 0.15:
		return Color(0.87, 0.92, 0.98)
	if temp < 0.32:
		return Color(0.87, 0.92, 0.98).lerp(Color(0.55, 0.60, 0.45), (temp - 0.15) / 0.17)

	if norm_h > 0.45:
		return Color(0.42, 0.35, 0.22).lerp(Color(0.45, 0.40, 0.35), (norm_h - 0.45) / 0.20)

	if moist < 0.22:
		return Color(0.78, 0.62, 0.30) if temp > 0.65 else Color(0.62, 0.57, 0.36)
	elif moist < 0.45:
		return Color(0.58, 0.58, 0.22) if temp > 0.60 else Color(0.40, 0.52, 0.22)
	elif moist < 0.70:
		return Color(0.24, 0.42, 0.16) if temp > 0.55 else Color(0.18, 0.32, 0.18)
	else:
		return Color(0.08, 0.22, 0.08) if temp > 0.55 else Color(0.12, 0.26, 0.14)
