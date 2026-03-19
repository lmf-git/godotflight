extends CanvasLayer

## Weapon HUD: weapon mode, radar scope, sensor-camera overlay, lock-on indicator.

const WEAPON_NAMES := ["GUNS", "MISSILES", "LASER", "BOMBS"]
const RADAR_RANGE := 15000.0

var _vehicle = null

# UI nodes
var _weapon_label: Label
var _ammo_label: Label
var _lock_label: Label
var _radar_panel: Control
var _sensor_overlay: Control   # full-screen overlay when laser camera is active
var _lock_rect: Control        # drawn around locked 3D target

var _radar_open := false
var _stall_warning: Control
var _missile_warning: Control
var _gun_sight: Control
var _hit_indicator: Control
var _hit_sound: AudioStreamPlayer
var _waypoint_hud: Control

func _ready() -> void:
	_build_ui()
	add_to_group("weapon_hud")

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.is_echo():
		if event.keycode == KEY_BRACKETLEFT:
			_radar_open = not _radar_open
			_radar_panel.visible = _radar_open
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_BRACKETRIGHT:
			for node in get_tree().get_nodes_in_group("map_overlay"):
				node.toggle()
			get_viewport().set_input_as_handled()

func _process(_delta: float) -> void:
	_find_vehicle()
	_update_weapon_label()
	_update_sensor_overlay()
	_update_lock_box()
	_update_stall_warning()
	_update_missile_warning()
	if _radar_open:
		_radar_panel.queue_redraw()
	_update_gun_sight()

# ── Vehicle polling ───────────────────────────────────────────────────────────

func _find_vehicle() -> void:
	for node in get_tree().get_nodes_in_group("aircraft"):
		if "is_occupied" in node and node.is_occupied:
			_vehicle = node
			return
	_vehicle = null

# ── Weapon label ─────────────────────────────────────────────────────────────

func _update_weapon_label() -> void:
	if not _vehicle or not ("current_weapon" in _vehicle):
		_weapon_label.visible = false
		_ammo_label.visible = false
		_lock_label.visible = false
		return

	var idx: int = _vehicle.current_weapon
	_weapon_label.text = "WPN: " + WEAPON_NAMES[idx]
	_weapon_label.visible = true

	match idx:
		0:  _ammo_label.text = "∞ ROUNDS"
		1:
			var cnt := 0
			if "missiles" in _vehicle:
				for m in _vehicle.missiles:
					if is_instance_valid(m) and m.state == Missile.State.ATTACHED:
						cnt += 1
			_ammo_label.text = "%d MSL" % cnt
		2:  _ammo_label.text = "LASER"
		3:  _ammo_label.text = "%d BOMBS" % (_vehicle.bombs_remaining if "bombs_remaining" in _vehicle else 0)
	_ammo_label.visible = true

	if "laser_target" in _vehicle and _vehicle.laser_target and is_instance_valid(_vehicle.laser_target):
		var dist: float = _vehicle.global_position.distance_to(_vehicle.laser_target.global_position)
		var ds := "%.0fm" % dist if dist < 1000 else "%.1fkm" % (dist / 1000.0)
		_lock_label.text = "LOCK: %s  %s" % [_vehicle.laser_target.name, ds]
		_lock_label.visible = true
	elif "laser_spot_active" in _vehicle and _vehicle.laser_spot_active:
		_lock_label.text = "LASER SPOT"
		_lock_label.visible = true
	else:
		_lock_label.visible = false

# ── Sensor camera overlay ─────────────────────────────────────────────────────

func _update_sensor_overlay() -> void:
	if _vehicle and "laser_camera_active" in _vehicle and _vehicle.laser_camera_active:
		_sensor_overlay.visible = true
		_sensor_overlay.queue_redraw()
	else:
		_sensor_overlay.visible = false

# ── Lock-on box ───────────────────────────────────────────────────────────────

func _update_lock_box() -> void:
	if not _vehicle or not ("laser_target" in _vehicle) or not _vehicle.laser_target \
			or not is_instance_valid(_vehicle.laser_target):
		_lock_rect.visible = false
		return
	var cam := get_viewport().get_camera_3d()
	if not cam:
		_lock_rect.visible = false
		return
	var world_pos: Vector3 = _vehicle.laser_target.global_position
	if not cam.is_position_in_frustum(world_pos):
		_lock_rect.visible = false
		return
	var screen_pos: Vector2 = cam.unproject_position(world_pos)
	var dist: float = _vehicle.global_position.distance_to(world_pos)
	# Scale box with distance: big when close, small when far
	var box_size: float = clamp(8000.0 / maxf(dist, 50.0), 40.0, 220.0)
	_lock_rect.position = screen_pos - Vector2(box_size * 0.5, box_size * 0.5)
	_lock_rect.size = Vector2(box_size, box_size)
	# Pass data to inner class for drawing
	var lb := _lock_rect as _LockBox
	lb.dist_m = dist
	lb.tgt_name = _vehicle.laser_target.name
	if "lock_progress" in _vehicle:
		lb.lock_progress = _vehicle.lock_progress
	_lock_rect.visible = true
	_lock_rect.queue_redraw()

# ── Stall warning ─────────────────────────────────────────────────────────────

func _update_stall_warning() -> void:
	if _vehicle and "is_stalled" in _vehicle and _vehicle.is_stalled:
		_stall_warning.visible = true
		_stall_warning.queue_redraw()
	else:
		_stall_warning.visible = false

# ── Missile warning ───────────────────────────────────────────────────────────

func _update_missile_warning() -> void:
	if not _vehicle:
		_missile_warning.visible = false
		return
	var incoming := 0
	for node in get_tree().get_nodes_in_group("missiles"):
		if not is_instance_valid(node):
			continue
		if "state" not in node or node.state != Missile.State.FIRING:
			continue
		if "homing_target" in node and node.homing_target == _vehicle:
			incoming += 1
	var warn := _missile_warning as _MissileWarning
	warn.incoming_count = incoming
	warn.vehicle = _vehicle
	_missile_warning.visible = incoming > 0
	if incoming > 0:
		_missile_warning.queue_redraw()

# ── Hit indicator ────────────────────────────────────────────────────────────

func register_hit() -> void:
	(_hit_indicator as _HitIndicator).flash()
	if _hit_sound and not _hit_sound.playing:
		_hit_sound.play()

func _build_hit_sound() -> AudioStreamWAV:
	const SAMPLE_RATE := 22050
	const DURATION := 0.12        # 120 ms ping
	const FREQ := 1200.0          # fundamental
	var n := int(SAMPLE_RATE * DURATION)
	var data := PackedByteArray()
	data.resize(n * 2)            # 16-bit mono → 2 bytes per sample
	for i in n:
		var t := float(i) / SAMPLE_RATE
		var env := exp(-t * 35.0) # fast exponential decay
		var s := sin(TAU * FREQ * t) * 0.75 \
				+ sin(TAU * FREQ * 2.0 * t) * 0.20 * env  # slight harmonic click
		var v := clampi(int(s * env * 32767.0), -32768, 32767)
		data[i * 2]     = v & 0xFF
		data[i * 2 + 1] = (v >> 8) & 0xFF
	var stream := AudioStreamWAV.new()
	stream.format = AudioStreamWAV.FORMAT_16_BITS
	stream.mix_rate = SAMPLE_RATE
	stream.stereo = false
	stream.data = data
	return stream

# ── Gun sight ────────────────────────────────────────────────────────────────

func _update_gun_sight() -> void:
	if _vehicle and "current_weapon" in _vehicle and _vehicle.current_weapon == 0 \
			and _vehicle.is_occupied:
		_gun_sight.visible = true
		_gun_sight.set_meta("vehicle", _vehicle)
		_gun_sight.queue_redraw()
	else:
		_gun_sight.visible = false

# ── UI construction ───────────────────────────────────────────────────────────

func _build_ui() -> void:
	var vp_size := Vector2(1920, 1080)

	_weapon_label = Label.new()
	_weapon_label.add_theme_color_override("font_color", Color(0.2, 1.0, 0.3))
	_weapon_label.add_theme_font_size_override("font_size", 22)
	_weapon_label.position = Vector2(40, vp_size.y - 100)
	_weapon_label.visible = false
	add_child(_weapon_label)

	_ammo_label = Label.new()
	_ammo_label.add_theme_color_override("font_color", Color(0.8, 1.0, 0.6))
	_ammo_label.add_theme_font_size_override("font_size", 18)
	_ammo_label.position = Vector2(40, vp_size.y - 72)
	_ammo_label.visible = false
	add_child(_ammo_label)

	_lock_label = Label.new()
	_lock_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_lock_label.add_theme_font_size_override("font_size", 20)
	_lock_label.position = Vector2(40, vp_size.y - 140)
	_lock_label.visible = false
	add_child(_lock_label)

	# Radar panel — bottom right
	_radar_panel = _RadarScope.new()
	_radar_panel.custom_minimum_size = Vector2(280, 280)
	_radar_panel.visible = false
	add_child(_radar_panel)

	# Sensor overlay — full screen, shown only when laser camera active
	_sensor_overlay = _SensorOverlay.new()
	_sensor_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_sensor_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_sensor_overlay.visible = false
	add_child(_sensor_overlay)

	# Lock-on box — positioned dynamically
	_lock_rect = _LockBox.new()
	_lock_rect.visible = false
	add_child(_lock_rect)

	# Hit indicator — brief flash at screen centre on confirmed hit
	_hit_indicator = _HitIndicator.new()
	_hit_indicator.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hit_indicator.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hit_indicator.visible = false
	add_child(_hit_indicator)

	# Gun sight — full screen overlay, drawn when GUNS weapon is active
	_gun_sight = _GunSight.new()
	_gun_sight.set_anchors_preset(Control.PRESET_FULL_RECT)
	_gun_sight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gun_sight.visible = false
	add_child(_gun_sight)

	# Stall warning — full screen, behind everything else readable
	_stall_warning = _StallWarning.new()
	_stall_warning.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stall_warning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stall_warning.visible = false
	add_child(_stall_warning)

	# Missile warning — top-centre, shown when a missile is homing on the player
	_missile_warning = _MissileWarning.new()
	_missile_warning.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_missile_warning.visible = false
	add_child(_missile_warning)

	# Waypoint indicator — always-on when an objective marker is set
	_waypoint_hud = _WaypointIndicator.new()
	_waypoint_hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	_waypoint_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_waypoint_hud)

	get_viewport().size_changed.connect(_on_viewport_resized)
	_on_viewport_resized()

	_hit_sound = AudioStreamPlayer.new()
	_hit_sound.stream = _build_hit_sound()
	_hit_sound.volume_db = -6.0
	_hit_sound.bus = "Master"
	add_child(_hit_sound)

func _on_viewport_resized() -> void:
	var vp := get_viewport().get_visible_rect().size
	_weapon_label.position = Vector2(40, vp.y - 100)
	_ammo_label.position = Vector2(40, vp.y - 72)
	_lock_label.position = Vector2(40, vp.y - 140)
	_radar_panel.position = Vector2(vp.x - 300, vp.y - 310)
	_radar_panel.size = Vector2(280, 280)
	_missile_warning.position = Vector2(vp.x * 0.5 - 180, 16)
	_missile_warning.size = Vector2(360, 90)

# ── Inner classes ─────────────────────────────────────────────────────────────

class _StallWarning extends Control:
	var _time: float = 0.0

	func _process(delta: float) -> void:
		_time += delta
		if visible:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var cx := w * 0.5
		var _cy := h * 0.5

		# Pulsing fast red border
		var pulse: float = (sin(_time * 8.0) + 1.0) * 0.5
		var alpha := 0.35 + pulse * 0.45
		var rc := Color(1.0, 0.08, 0.08, alpha)
		var bw := 10.0 + pulse * 6.0
		draw_rect(Rect2(0, 0, w, bw), rc)
		draw_rect(Rect2(0, h - bw, w, bw), rc)
		draw_rect(Rect2(0, 0, bw, h), rc)
		draw_rect(Rect2(w - bw, 0, bw, h), rc)

		# "STALL" text centre-top
		var font := ThemeDB.fallback_font
		var text_alpha := 0.6 + pulse * 0.4
		draw_string(font, Vector2(cx - 36, 56), "STALL",
				HORIZONTAL_ALIGNMENT_CENTER, 72, 38,
				Color(1.0, 0.15, 0.15, text_alpha))
		draw_string(font, Vector2(cx - 48, 90), "REDUCE AOA",
				HORIZONTAL_ALIGNMENT_CENTER, 96, 18,
				Color(1.0, 0.5, 0.5, text_alpha * 0.75))


class _RadarScope extends Control:
	func _draw() -> void:
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		var r: float = min(cx, cy) - 4.0

		draw_circle(Vector2(cx, cy), r, Color(0.0, 0.08, 0.0, 0.88))
		draw_arc(Vector2(cx, cy), r, 0, TAU, 64, Color(0.2, 0.8, 0.2), 2.0)
		draw_arc(Vector2(cx, cy), r * 0.33, 0, TAU, 48, Color(0.1, 0.4, 0.1), 1.0)
		draw_arc(Vector2(cx, cy), r * 0.66, 0, TAU, 48, Color(0.1, 0.4, 0.1), 1.0)
		draw_line(Vector2(cx - r, cy), Vector2(cx + r, cy), Color(0.1, 0.4, 0.1), 1.0)
		draw_line(Vector2(cx, cy - r), Vector2(cx, cy + r), Color(0.1, 0.4, 0.1), 1.0)
		draw_string(ThemeDB.fallback_font, Vector2(6, 14), "RADAR", HORIZONTAL_ALIGNMENT_LEFT,
				-1, 12, Color(0.3, 1.0, 0.3))

		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return

		var player_pos := Vector3.ZERO
		var player_heading := 0.0
		var laser_spot_active := false
		var laser_spot_pos := Vector3.ZERO
		var locked_target: Node3D = null

		for node in tree.get_nodes_in_group("aircraft"):
			if "is_occupied" in node and node.is_occupied:
				player_pos = node.global_position
				var fwd: Vector3 = -node.global_transform.basis.z
				player_heading = atan2(fwd.x, -fwd.z)
				if "laser_spot_active" in node:
					laser_spot_active = node.laser_spot_active
				if "laser_spot_pos" in node:
					laser_spot_pos = node.laser_spot_pos
				if "laser_target" in node:
					locked_target = node.laser_target
				break

		# Heading-up radar: rotate all deltas so player forward is always at top
		var cos_h := cos(player_heading)
		var sin_h := sin(player_heading)

		# Player marker — forward always points up in heading-up display
		draw_circle(Vector2(cx, cy), 5, Color(0.2, 1.0, 0.4))
		draw_line(Vector2(cx, cy), Vector2(cx, cy - 12), Color(0.2, 1.0, 0.4), 2.0)

		# AI aircraft blips
		for node in tree.get_nodes_in_group("ai_aircraft"):
			if not is_instance_valid(node):
				continue
			var delta: Vector3 = node.global_position - player_pos
			var rdx: float = delta.x * cos_h + delta.z * sin_h
			var rdz: float = -delta.x * sin_h + delta.z * cos_h
			var bx: float = cx + (rdx / RADAR_RANGE) * r
			var by: float = cy + (rdz / RADAR_RANGE) * r
			bx = clamp(bx, cx - r + 4, cx + r - 4)
			by = clamp(by, cy - r + 4, cy + r - 4)
			var blip_col := Color(1.0, 0.9, 0.1) if node == locked_target else Color(1.0, 0.3, 0.3)
			draw_circle(Vector2(bx, by), 5, blip_col)
			if node == locked_target:
				draw_arc(Vector2(bx, by), 9, 0, TAU, 16, Color(1.0, 0.9, 0.0), 2.0)

		# Missile blips — orange triangles, red if homing on player
		var player_node = null
		for node in tree.get_nodes_in_group("aircraft"):
			if "is_occupied" in node and node.is_occupied:
				player_node = node
				break
		for node in tree.get_nodes_in_group("missiles"):
			if not is_instance_valid(node):
				continue
			if "state" not in node or node.state != Missile.State.FIRING:
				continue
			var mdelta: Vector3 = node.global_position - player_pos
			var mrdx: float = mdelta.x * cos_h + mdelta.z * sin_h
			var mrdz: float = -mdelta.x * sin_h + mdelta.z * cos_h
			var mbx: float = cx + (mrdx / RADAR_RANGE) * r
			var mby: float = cy + (mrdz / RADAR_RANGE) * r
			mbx = clamp(mbx, cx - r + 4, cx + r - 4)
			mby = clamp(mby, cy - r + 4, cy + r - 4)
			var is_incoming: bool = "homing_target" in node and node.homing_target == player_node
			var mc := Color(1.0, 0.15, 0.15) if is_incoming else Color(1.0, 0.55, 0.1)
			# Direction of travel arrow (also rotated to heading-up)
			if "linear_velocity" in node and (node as RigidBody3D).linear_velocity.length() > 1.0:
				var vel_dir: Vector3 = (node as RigidBody3D).linear_velocity.normalized()
				var vdx: float = (vel_dir.x * cos_h + vel_dir.z * sin_h) * 12.0
				var vdz: float = (-vel_dir.x * sin_h + vel_dir.z * cos_h) * 12.0
				draw_line(Vector2(mbx, mby), Vector2(mbx + vdx, mby + vdz), mc, 1.5)
			# Triangle blip
			var ts := 5.0
			draw_colored_polygon([
				Vector2(mbx, mby - ts),
				Vector2(mbx - ts, mby + ts),
				Vector2(mbx + ts, mby + ts)
			], mc)
			if is_incoming:
				draw_arc(Vector2(mbx, mby), 10, 0, TAU, 16, Color(1.0, 0.2, 0.2, 0.7), 1.5)

		# Laser spot marker (diamond)
		if laser_spot_active:
			var delta: Vector3 = laser_spot_pos - player_pos
			var rdx: float = delta.x * cos_h + delta.z * sin_h
			var rdz: float = -delta.x * sin_h + delta.z * cos_h
			var bx: float = cx + (rdx / RADAR_RANGE) * r
			var by: float = cy + (rdz / RADAR_RANGE) * r
			bx = clamp(bx, cx - r + 4, cx + r - 4)
			by = clamp(by, cy - r + 4, cy + r - 4)
			var dp := Vector2(bx, by)
			var d := 6.0
			draw_line(dp + Vector2(0, -d), dp + Vector2(d, 0), Color(0.3, 0.8, 1.0), 2.0)
			draw_line(dp + Vector2(d, 0),  dp + Vector2(0, d), Color(0.3, 0.8, 1.0), 2.0)
			draw_line(dp + Vector2(0, d),  dp + Vector2(-d, 0), Color(0.3, 0.8, 1.0), 2.0)
			draw_line(dp + Vector2(-d, 0), dp + Vector2(0, -d), Color(0.3, 0.8, 1.0), 2.0)

		# Objective markers — yellow squares
		for map_node in tree.get_nodes_in_group("map_overlay"):
			if not ("_objective_markers" in map_node):
				break
			for marker: Vector2 in map_node._objective_markers:
				var mdelta := Vector3(marker.x - player_pos.x, 0.0, marker.y - player_pos.z)
				var mrdx: float = mdelta.x * cos_h + mdelta.z * sin_h
				var mrdz: float = -mdelta.x * sin_h + mdelta.z * cos_h
				var mbx: float = cx + (mrdx / RADAR_RANGE) * r
				var mby: float = cy + (mrdz / RADAR_RANGE) * r
				mbx = clamp(mbx, cx - r + 4, cx + r - 4)
				mby = clamp(mby, cy - r + 4, cy + r - 4)
				var oc := Color(1.0, 0.85, 0.0)
				var ts := 5.0
				draw_rect(Rect2(mbx - ts, mby - ts, ts * 2.0, ts * 2.0), oc, false, 2.0)
				draw_line(Vector2(mbx, mby - ts - 5), Vector2(mbx, mby - ts), oc, 2.0)
			break


class _SensorOverlay extends Control:
	var _time: float = 0.0

	func _process(delta: float) -> void:
		_time += delta
		if visible:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var h := size.y
		var cx := w * 0.5
		var cy := h * 0.5

		# Green tinted border vignette
		var border := 6.0
		var gc := Color(0.1, 0.9, 0.2, 0.55)
		draw_rect(Rect2(0, 0, w, border), gc)
		draw_rect(Rect2(0, h - border, w, border), gc)
		draw_rect(Rect2(0, 0, border, h), gc)
		draw_rect(Rect2(w - border, 0, border, h), gc)

		# Corner brackets
		var arm := 40.0
		draw_line(Vector2(0, 0), Vector2(arm, 0), gc, 3.0)
		draw_line(Vector2(0, 0), Vector2(0, arm), gc, 3.0)
		draw_line(Vector2(w, 0), Vector2(w - arm, 0), gc, 3.0)
		draw_line(Vector2(w, 0), Vector2(w, arm), gc, 3.0)
		draw_line(Vector2(0, h), Vector2(arm, h), gc, 3.0)
		draw_line(Vector2(0, h), Vector2(0, h - arm), gc, 3.0)
		draw_line(Vector2(w, h), Vector2(w - arm, h), gc, 3.0)
		draw_line(Vector2(w, h), Vector2(w, h - arm), gc, 3.0)

		# Center reticle
		var rc := Color(0.3, 1.0, 0.3, 0.85)
		var r1 := 18.0
		var r2 := 8.0
		draw_arc(Vector2(cx, cy), r1, 0, TAU, 32, rc, 1.5)
		draw_line(Vector2(cx - r1 - 8, cy), Vector2(cx - r2, cy), rc, 1.5)
		draw_line(Vector2(cx + r2, cy), Vector2(cx + r1 + 8, cy), rc, 1.5)
		draw_line(Vector2(cx, cy - r1 - 8), Vector2(cx, cy - r2), rc, 1.5)
		draw_line(Vector2(cx, cy + r2), Vector2(cx, cy + r1 + 8), rc, 1.5)

		# "SENSOR" label top-left
		draw_string(ThemeDB.fallback_font, Vector2(14, 28), "SENSOR VIEW",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 18, Color(0.2, 1.0, 0.3, 0.9))

		# Pulsing "REC" dot top-right
		var pulse_alpha: float = (sin(_time * 3.0) + 1.0) * 0.4 + 0.2
		draw_circle(Vector2(w - 30, 18), 6, Color(1.0, 0.2, 0.2, pulse_alpha))
		draw_string(ThemeDB.fallback_font, Vector2(w - 20, 26), "REC",
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.3, 0.3, pulse_alpha + 0.3))


class _LockBox extends Control:
	var dist_m: float = 0.0
	var tgt_name: String = ""
	var lock_progress: float = 0.0
	var _time: float = 0.0

	func _process(delta: float) -> void:
		_time += delta
		if visible:
			queue_redraw()

	func _draw() -> void:
		var s := size
		var pulse: float = (sin(_time * 5.0) + 1.0) * 0.5
		var cx := s.x * 0.5
		var cy := s.y * 0.5
		var lp := lock_progress

		# State-dependent color
		var state_str: String
		var state_col: Color
		if lp >= 1.0:
			state_str = "LOCKED"
			state_col = Color(1.0, 0.2, 0.2, 0.85 + pulse * 0.15)
		elif lp > 0.0:
			state_str = "LOCKING"
			state_col = Color(1.0, 0.75 + lp * 0.15, 0.1, 0.75 + pulse * 0.25)
		else:
			state_str = "SEEK"
			state_col = Color(0.7, 0.8, 0.7, 0.45)

		var ca := state_col
		var cd := Color(ca.r, ca.g, ca.b, 0.3)
		var corner := maxf(s.x * 0.3, 12.0)

		# Outer corner brackets
		draw_line(Vector2(0, 0),    Vector2(corner, 0),  ca, 2.5)
		draw_line(Vector2(0, 0),    Vector2(0, corner),  ca, 2.5)
		draw_line(Vector2(s.x, 0),  Vector2(s.x - corner, 0),  ca, 2.5)
		draw_line(Vector2(s.x, 0),  Vector2(s.x, corner),      ca, 2.5)
		draw_line(Vector2(0, s.y),  Vector2(corner, s.y),       ca, 2.5)
		draw_line(Vector2(0, s.y),  Vector2(0, s.y - corner),   ca, 2.5)
		draw_line(Vector2(s.x, s.y), Vector2(s.x - corner, s.y),    ca, 2.5)
		draw_line(Vector2(s.x, s.y), Vector2(s.x, s.y - corner),    ca, 2.5)

		# Center crosshair
		draw_line(Vector2(cx - 8, cy), Vector2(cx + 8, cy), cd, 1.0)
		draw_line(Vector2(cx, cy - 8), Vector2(cx, cy + 8), cd, 1.0)

		# Lock progress arc — starts at top, sweeps clockwise
		if lp > 0.0:
			var arc_r := minf(cx, cy) * 0.55
			var arc_pts := maxi(int(lp * 48), 4)
			draw_arc(Vector2(cx, cy), arc_r,
					-PI * 0.5, -PI * 0.5 + TAU * lp,
					arc_pts, state_col, 2.5)

		var font := ThemeDB.fallback_font

		# State label above box
		draw_string(font, Vector2(cx - 30, -6), state_str,
				HORIZONTAL_ALIGNMENT_CENTER, 60, 13, ca)

		# Distance text below box
		var dist_text := "%.0fm" % dist_m if dist_m < 1000.0 else "%.1fkm" % (dist_m / 1000.0)
		draw_string(font, Vector2(cx - 32, s.y + 17), dist_text,
				HORIZONTAL_ALIGNMENT_CENTER, 64, 14, ca)
		draw_string(font, Vector2(cx - 40, s.y + 33), tgt_name,
				HORIZONTAL_ALIGNMENT_CENTER, 80, 12, Color(1.0, 0.7, 0.3, 0.75))


class _MissileWarning extends Control:
	var incoming_count: int = 0
	var vehicle = null
	var _time: float = 0.0

	func _process(delta: float) -> void:
		_time += delta
		if visible:
			queue_redraw()

	func _draw() -> void:
		var w := size.x
		var cx := w * 0.5
		var pulse: float = (sin(_time * 7.0) + 1.0) * 0.5
		var alpha := 0.65 + pulse * 0.35
		var col := Color(1.0, 0.1, 0.1, alpha)
		var font := ThemeDB.fallback_font

		# Background bar
		draw_rect(Rect2(0, 0, w, 44), Color(0.15, 0.0, 0.0, 0.7))
		draw_rect(Rect2(0, 0, w, 2), col)
		draw_rect(Rect2(0, 42, w, 2), col)

		# "MISSILE" warning text
		var label := "  MISSILE INBOUND  "
		if incoming_count > 1:
			label = "  %d MISSILES INBOUND  " % incoming_count
		draw_string(font, Vector2(cx - 130, 30), label,
				HORIZONTAL_ALIGNMENT_CENTER, 260, 26, col)

		# Find nearest inbound missile and draw bearing indicator
		var tree := Engine.get_main_loop() as SceneTree
		if not tree or not vehicle:
			return
		var player_pos: Vector3 = vehicle.global_position
		var fwd: Vector3 = -vehicle.global_transform.basis.z
		var player_heading := atan2(fwd.x, -fwd.z)
		var nearest_dist := INF
		var nearest_bearing := 0.0
		for node in tree.get_nodes_in_group("missiles"):
			if not is_instance_valid(node):
				continue
			if "state" not in node or node.state != Missile.State.FIRING:
				continue
			if "homing_target" not in node or node.homing_target != vehicle:
				continue
			var d := player_pos.distance_to(node.global_position)
			if d < nearest_dist:
				nearest_dist = d
				var to_m: Vector3 = node.global_position - player_pos
				nearest_bearing = atan2(to_m.x, -to_m.z) - player_heading
		if nearest_dist == INF:
			return
		# Bearing circle with arrow
		var arrow_cx := cx
		var arrow_cy := 66.0
		var ar := 14.0
		draw_circle(Vector2(arrow_cx, arrow_cy), ar + 3, Color(0.2, 0.0, 0.0, 0.6))
		draw_arc(Vector2(arrow_cx, arrow_cy), ar + 3, 0, TAU, 32, Color(1.0, 0.3, 0.3, 0.6), 1.5)
		var ax := sin(nearest_bearing) * ar
		var ay := -cos(nearest_bearing) * ar
		var tip := Vector2(arrow_cx + ax, arrow_cy + ay)
		var bl := Vector2(arrow_cx - ay * 0.45, arrow_cy - ax * 0.45) - Vector2(ax, ay) * 0.45
		var br := Vector2(arrow_cx + ay * 0.45, arrow_cy + ax * 0.45) - Vector2(ax, ay) * 0.45
		draw_colored_polygon([tip, bl, br], col)
		# Distance
		var ds := "%.0fm" % nearest_dist if nearest_dist < 1000 else "%.1fkm" % (nearest_dist / 1000.0)
		draw_string(font, Vector2(arrow_cx + ar + 8, arrow_cy + 5), ds,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color(1.0, 0.6, 0.6, alpha))


class _HitIndicator extends Control:
	const DURATION := 1.2
	var _timer: float = 0.0

	func flash() -> void:
		_timer = DURATION
		visible = true
		queue_redraw()

	func _process(delta: float) -> void:
		if _timer > 0.0:
			_timer -= delta
			queue_redraw()
			if _timer <= 0.0:
				visible = false

	func _draw() -> void:
		if _timer <= 0.0:
			return
		var cx := size.x * 0.5
		var cy := size.y * 0.5
		# Bright on hit, fades over the last 0.6 s
		var fade := clampf(_timer / 0.6, 0.0, 1.0)
		var col := Color(1.0, 0.15, 0.15, fade)
		var inner := 16.0
		var outer := 30.0
		# Four diagonal ticks (classic hit marker)
		for i in 4:
			var angle := PI * 0.25 + i * PI * 0.5
			var s := sin(angle)
			var c := cos(angle)
			draw_line(Vector2(cx + s * inner, cy + c * inner),
					Vector2(cx + s * outer, cy + c * outer), col, 3.5)


class _GunSight extends Control:
	const BULLET_SPEED := 900.0  # matches AircraftGun.TRACER_SPEED

	func _draw() -> void:
		var vehicle = get_meta("vehicle", null)
		if not vehicle or not is_instance_valid(vehicle):
			return
		var cam := get_viewport().get_camera_3d()
		if not cam:
			return

		# Gun reticle: project a point far ahead along the nose
		var aim_world: Vector3 = vehicle.global_position + (-vehicle.global_transform.basis.z) * 800.0
		var reticle_pos: Vector2
		if cam.is_position_in_frustum(aim_world):
			reticle_pos = cam.unproject_position(aim_world)
		else:
			reticle_pos = size * 0.5  # fallback: screen centre
		_draw_reticle(reticle_pos)

		# Lead indicator: only when a target is locked
		if not ("laser_target" in vehicle) or not vehicle.laser_target \
				or not is_instance_valid(vehicle.laser_target):
			return
		var target := vehicle.laser_target as Node3D
		var to_target: Vector3 = target.global_position - vehicle.global_position
		var dist: float = to_target.length()
		var dir: Vector3 = to_target / maxf(dist, 0.001)
		var tgt_vel := Vector3.ZERO
		if target is RigidBody3D:
			tgt_vel = (target as RigidBody3D).linear_velocity
		var player_vel := Vector3.ZERO
		if vehicle is RigidBody3D:
			player_vel = (vehicle as RigidBody3D).linear_velocity
		# Closing rate = bullet speed + player's approach speed - target's approach speed
		var closing_rate: float = BULLET_SPEED + player_vel.dot(dir) - tgt_vel.dot(dir)
		closing_rate = maxf(closing_rate, 50.0)
		var tof: float = dist / closing_rate
		var lead_world: Vector3 = target.global_position + tgt_vel * tof
		if not cam.is_position_in_frustum(lead_world):
			return
		var lead_pos := cam.unproject_position(lead_world)
		_draw_lead(lead_pos, dist)

	func _draw_reticle(pos: Vector2) -> void:
		var col := Color(0.25, 1.0, 0.35, 0.9)
		var r := 20.0
		var gap := 6.0
		draw_arc(pos, r, 0, TAU, 40, col, 1.5)
		draw_line(pos + Vector2(-(r + gap), 0), pos + Vector2(-(r - gap * 0.5), 0), col, 1.5)
		draw_line(pos + Vector2(r - gap * 0.5, 0),  pos + Vector2(r + gap, 0),  col, 1.5)
		draw_line(pos + Vector2(0, -(r + gap)), pos + Vector2(0, -(r - gap * 0.5)), col, 1.5)
		draw_line(pos + Vector2(0, r - gap * 0.5),  pos + Vector2(0, r + gap),  col, 1.5)
		draw_circle(pos, 2.0, col)

	func _draw_lead(pos: Vector2, dist: float) -> void:
		var col := Color(1.0, 0.6, 0.1, 0.95)
		var r := 9.0
		draw_arc(pos, r, 0, TAU, 24, col, 2.0)
		var d := 5.0
		draw_line(pos + Vector2(-d, 0), pos + Vector2(d, 0), col, 1.5)
		draw_line(pos + Vector2(0, -d), pos + Vector2(0, d), col, 1.5)
		var font := ThemeDB.fallback_font
		var ds := "%.0fm" % dist if dist < 1000.0 else "%.1fkm" % (dist / 1000.0)
		draw_string(font, pos + Vector2(r + 4, 5), ds,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 12, col)


class _WaypointIndicator extends Control:
	func _process(_delta: float) -> void:
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return
		visible = not tree.get_nodes_in_group("objective_markers").is_empty()
		if visible:
			queue_redraw()

	func _draw() -> void:
		var tree := Engine.get_main_loop() as SceneTree
		if not tree:
			return
		var markers := tree.get_nodes_in_group("objective_markers")
		if markers.is_empty():
			return
		var beacon := markers[0] as Node3D
		if not is_instance_valid(beacon):
			return
		var cam := get_viewport().get_camera_3d()
		if not cam:
			return

		var vehicle_pos := Vector3.ZERO
		for node in tree.get_nodes_in_group("aircraft"):
			if "is_occupied" in node and node.is_occupied:
				vehicle_pos = node.global_position
				break

		# Use midpoint of beacon for screen projection
		var target_pos: Vector3 = beacon.global_position + Vector3(0, 150.0, 0)
		var dist_m: float = vehicle_pos.distance_to(beacon.global_position)
		var dist_str: String = "%.0fm" % dist_m if dist_m < 1000.0 else "%.1fkm" % (dist_m / 1000.0)

		var cx := size.x * 0.5
		var cy := size.y * 0.5
		var margin := 70.0
		var font := ThemeDB.fallback_font
		var oc := Color(1.0, 0.85, 0.0)

		var cam_fwd: Vector3 = -cam.global_transform.basis.z
		var to_target: Vector3 = (target_pos - cam.global_position).normalized()
		var in_front := cam_fwd.dot(to_target) > 0.05

		if in_front and cam.is_position_in_frustum(target_pos):
			# On-screen diamond indicator
			var sp := cam.unproject_position(target_pos)
			var d := 14.0
			draw_line(sp + Vector2(0, -d), sp + Vector2(d, 0), oc, 2.0)
			draw_line(sp + Vector2(d, 0),  sp + Vector2(0, d),  oc, 2.0)
			draw_line(sp + Vector2(0, d),  sp + Vector2(-d, 0), oc, 2.0)
			draw_line(sp + Vector2(-d, 0), sp + Vector2(0, -d), oc, 2.0)
			draw_string(font, sp + Vector2(-28, d + 16), "OBJ  " + dist_str,
					HORIZONTAL_ALIGNMENT_LEFT, -1, 14, oc)
		else:
			# Off-screen: draw arrow at screen edge
			var sp := cam.unproject_position(target_pos)
			var screen_dir := (sp - Vector2(cx, cy))
			if not in_front:
				screen_dir = -screen_dir
			if screen_dir.length() < 1.0:
				screen_dir = Vector2(0, -1)
			screen_dir = screen_dir.normalized()
			var edge := _edge_pos(screen_dir, cx, cy, margin)
			var as_ := 12.0
			var perp := Vector2(-screen_dir.y, screen_dir.x)
			draw_colored_polygon([
				edge + screen_dir * as_,
				edge - screen_dir * 4.0 + perp * as_ * 0.5,
				edge - screen_dir * 4.0 - perp * as_ * 0.5,
			], oc)
			draw_string(font, edge + screen_dir * (as_ + 6) + Vector2(-24, 6),
					dist_str, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, oc)

	func _edge_pos(dir: Vector2, cx: float, cy: float, margin: float) -> Vector2:
		var w := cx - margin
		var h := cy - margin
		if abs(dir.x) < 0.001:
			return Vector2(cx, cy + sign(dir.y) * h)
		if abs(dir.y) < 0.001:
			return Vector2(cx + sign(dir.x) * w, cy)
		var tx: float = w / abs(dir.x)
		var ty: float = h / abs(dir.y)
		if tx < ty:
			return Vector2(cx + sign(dir.x) * w, cy + dir.y * tx)
		return Vector2(cx + dir.x * ty, cy + sign(dir.y) * h)
