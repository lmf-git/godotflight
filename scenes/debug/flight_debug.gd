extends Node3D
class_name FlightDebug

## Debug visualization system for flight physics
## Draws 3D force vectors and displays HUD with flight data

const VECTOR_SCALE := 0.0001  # Scale forces to reasonable arrow lengths
const MIN_ARROW_LENGTH := 0.5
const MAX_ARROW_LENGTH := 10.0

var vehicle: Vehicle
var force_arrows: Dictionary = {}  # name -> MeshInstance3D

# HUD elements
var data_label: Label
var controls_label: Label

func _ready() -> void:
	# Get parent vehicle
	vehicle = get_parent() as Vehicle
	if not vehicle:
		push_warning("FlightDebug must be child of a Vehicle")
		return

	# Create HUD
	_create_hud()

func _process(_delta: float) -> void:
	var should_show: bool = visible and is_visible_in_tree()

	# Sync HUD panel visibility - hide panels directly since CanvasLayer doesn't inherit 3D visibility
	var canvas := get_node_or_null("DebugHUD")
	if canvas:
		var left_panel := canvas.get_node_or_null("LeftPanel")
		var right_panel := canvas.get_node_or_null("RightPanel")
		if left_panel:
			left_panel.visible = should_show
		if right_panel:
			right_panel.visible = should_show

	if not vehicle or not should_show:
		return

	# Update force arrows
	_update_force_arrows()

	# Update HUD
	_update_hud()

func _create_hud() -> void:
	# Create CanvasLayer for HUD
	var canvas := CanvasLayer.new()
	canvas.name = "DebugHUD"
	add_child(canvas)

	# LEFT PANEL - Flight Data
	var left_panel := PanelContainer.new()
	left_panel.name = "LeftPanel"
	left_panel.anchor_left = 0.0
	left_panel.anchor_right = 0.0
	left_panel.anchor_top = 0.0
	left_panel.anchor_bottom = 0.0
	left_panel.offset_left = 20
	left_panel.offset_right = 320
	left_panel.offset_top = 20
	canvas.add_child(left_panel)

	var left_margin := MarginContainer.new()
	left_margin.add_theme_constant_override("margin_left", 15)
	left_margin.add_theme_constant_override("margin_right", 15)
	left_margin.add_theme_constant_override("margin_top", 10)
	left_margin.add_theme_constant_override("margin_bottom", 10)
	left_panel.add_child(left_margin)

	data_label = Label.new()
	data_label.name = "FlightData"
	data_label.add_theme_font_size_override("font_size", 18)
	left_margin.add_child(data_label)

	# RIGHT PANEL - Controls
	var right_panel := PanelContainer.new()
	right_panel.name = "RightPanel"
	right_panel.anchor_left = 1.0
	right_panel.anchor_right = 1.0
	right_panel.anchor_top = 0.0
	right_panel.anchor_bottom = 0.0
	right_panel.offset_left = -280
	right_panel.offset_right = -20
	right_panel.offset_top = 20
	canvas.add_child(right_panel)

	var right_margin := MarginContainer.new()
	right_margin.add_theme_constant_override("margin_left", 15)
	right_margin.add_theme_constant_override("margin_right", 15)
	right_margin.add_theme_constant_override("margin_top", 10)
	right_margin.add_theme_constant_override("margin_bottom", 10)
	right_panel.add_child(right_margin)

	controls_label = Label.new()
	controls_label.name = "Controls"
	controls_label.add_theme_font_size_override("font_size", 18)
	right_margin.add_child(controls_label)

func _update_hud() -> void:
	if not data_label or not controls_label:
		return

	var v := vehicle

	# LEFT PANEL - Flight Data
	var data_text := ""
	data_text += "=== FLIGHT DATA ===\n\n"
	data_text += "AIRSPEED:  %6.1f m/s\n" % v.airspeed
	data_text += "           %6.1f kts\n" % (v.airspeed * 1.944)
	data_text += "ALT AGL:   %6.1f m\n" % v.altitude_agl
	data_text += "ALT MSL:   %6.1f m\n" % v.altitude_msl
	data_text += "V/S:       %+6.1f m/s\n" % v.vertical_speed
	data_text += "HEADING:   %6.1f°\n" % v.heading
	data_text += "\n"
	data_text += "AoA:       %+5.1f°\n" % v.angle_of_attack
	data_text += "G-FORCE:   %+5.2f G\n" % v.g_force
	data_text += "\n"
	data_text += "=== INPUTS ===\n\n"
	data_text += "THROTTLE:  %5.0f%%\n" % (v.input_throttle * 100)
	data_text += "PITCH:     %+5.2f\n" % v.input_pitch
	data_text += "ROLL:      %+5.2f\n" % v.input_roll
	data_text += "YAW:       %+5.2f\n" % v.input_yaw

	# Vehicle-specific data
	if v is Helicopter:
		var heli := v as Helicopter
		data_text += "\n=== HELICOPTER ===\n\n"
		var hover_status: String = "PID @ %.0fm" % heli._hover_target_alt if heli._hover_hold_active else "manual"
		data_text += "COLLECTIVE: %5.0f%% (%s)\n" % [heli.collective * 100, hover_status]
		data_text += "ROTOR SPD:  %5.0f%%\n" % (heli.rotor_speed * 100)
		var ge: float = heli._calculate_ground_effect() * 100
		data_text += "GROUND FX:  %5.1f%%\n" % ge
		var hs: float = Vector2(heli.linear_velocity.x, heli.linear_velocity.z).length()
		var etl: float = clamp(hs / heli.translational_lift_speed, 0.0, 1.0) * 100
		data_text += "TRANS LIFT: %5.1f%%\n" % etl
		data_text += "\n=== DAMAGE ===\n"
		data_text += "TAIL ROTOR: %s\n" % ("OK" if heli.has_tail_rotor else "DESTROYED")
		data_text += "MAIN ROTOR: %s\n" % ("OK" if heli.has_main_rotor else "DESTROYED")
		data_text += "TAIL BOOM:  %s\n" % ("OK" if heli.has_tail_boom else "DESTROYED")

	elif v is FixedWing:
		var plane := v as FixedWing
		data_text += "\n=== AIRCRAFT ===\n\n"
		data_text += "CL:        %+5.3f\n" % plane.current_cl
		data_text += "CD:        %+5.4f\n" % plane.current_cd
		data_text += "GROUND FX: %5.1f%%\n" % (plane.ground_effect_factor * 100)
		data_text += "GEAR:      %s\n" % ("DOWN" if plane.gear_down else "UP")
		data_text += "FLAPS:     %d%%\n" % (plane.flaps_input * 100)
		data_text += "STALLED:   %s\n" % ("YES!" if plane.is_stalled else "NO")
		data_text += "\n=== DAMAGE ===\n"
		data_text += "LEFT WING:  %s\n" % ("OK" if plane.has_left_wing else "DESTROYED")
		data_text += "RIGHT WING: %s\n" % ("OK" if plane.has_right_wing else "DESTROYED")
		data_text += "H-TAIL:     %s\n" % ("OK" if plane.has_horizontal_tail else "DESTROYED")
		data_text += "V-TAIL:     %s\n" % ("OK" if plane.has_vertical_tail else "DESTROYED")

	elif v is Jet:
		var jet := v as Jet
		data_text += "\n=== JET ===\n\n"
		data_text += "CL:        %+5.3f\n" % jet.current_cl
		data_text += "CD:        %+5.4f\n" % jet.current_cd
		data_text += "GROUND FX: %5.1f%%\n" % (jet.ground_effect_factor * 100)
		data_text += "GEAR:      %s\n" % ("DOWN" if jet.gear_down else "UP")
		data_text += "FLAPS:     %d%%\n" % (jet.flaps_input * 100)
		data_text += "AFTERBURN: %s\n" % ("ON" if jet.afterburner_active else "OFF")
		data_text += "STALLED:   %s\n" % ("YES!" if jet.is_stalled else "NO")
		data_text += "\n=== DAMAGE ===\n"
		data_text += "LEFT WING:  %s\n" % ("OK" if jet.has_left_wing else "DESTROYED")
		data_text += "RIGHT WING: %s\n" % ("OK" if jet.has_right_wing else "DESTROYED")
		data_text += "H-TAIL:     %s\n" % ("OK" if jet.has_horizontal_tail else "DESTROYED")
		data_text += "V-TAIL:     %s\n" % ("OK" if jet.has_vertical_tail else "DESTROYED")

	elif v is Car:
		var car := v as Car
		data_text += "\n=== CAR ===\n\n"
		data_text += "STEER:     %+5.1f°\n" % car.current_steer
		data_text += "SPEED:     %5.1f m/s\n" % car.linear_velocity.length()
		data_text += "\n=== DAMAGE ===\n"
		data_text += "FL WHEEL: %s\n" % ("OK" if car.has_wheel_fl else "DESTROYED")
		data_text += "FR WHEEL: %s\n" % ("OK" if car.has_wheel_fr else "DESTROYED")
		data_text += "RL WHEEL: %s\n" % ("OK" if car.has_wheel_rl else "DESTROYED")
		data_text += "RR WHEEL: %s\n" % ("OK" if car.has_wheel_rr else "DESTROYED")

	data_text += "\n=== FORCES ===\n\n"
	for force_name in v.debug_forces:
		var force_data: Dictionary = v.debug_forces[force_name]
		var force: Vector3 = force_data.force
		data_text += "%s: %.0f N\n" % [force_name.to_upper(), force.length()]

	data_label.text = data_text

	# RIGHT PANEL - Controls
	var ctrl_text := ""
	ctrl_text += "=== CONTROLS ===\n\n"
	if v is Helicopter:
		ctrl_text += "SHIFT/Z:\n  Collective up/down\n\n"
		ctrl_text += "MOUSE:\n  Cyclic (pitch/roll)\n\n"
		ctrl_text += "W/S:\n  Pitch fwd/back\n\n"
		ctrl_text += "A/D:\n  Roll left/right\n\n"
		ctrl_text += "Q/E:\n  Pedals (yaw)\n\n"
		ctrl_text += "ALT:\n  Freelook\n\n"
		ctrl_text += "J:\n  Break part\n\n"
	elif v is FixedWing:
		ctrl_text += "SHIFT/Z:\n  Throttle up/down\n\n"
		ctrl_text += "MOUSE:\n  Pitch and Roll\n\n"
		ctrl_text += "W/S:\n  Pitch down/up\n\n"
		ctrl_text += "A/D:\n  Ailerons (roll)\n\n"
		ctrl_text += "Q/E:\n  Rudder (yaw)\n\n"
		ctrl_text += "F/V:\n  Flaps up/down\n\n"
		ctrl_text += "L:\n  Toggle landing gear\n\n"
		ctrl_text += "ALT:\n  Freelook\n\n"
		ctrl_text += "J:\n  Break part\n\n"
	elif v is Jet:
		ctrl_text += "SHIFT/Z:\n  Throttle up/down\n\n"
		ctrl_text += "MOUSE:\n  Pitch and Roll\n\n"
		ctrl_text += "W/S:\n  Pitch down/up\n\n"
		ctrl_text += "A/D:\n  Ailerons (roll)\n\n"
		ctrl_text += "Q/E:\n  Rudder (yaw)\n\n"
		ctrl_text += "B:\n  Toggle afterburner\n\n"
		ctrl_text += "F/V:\n  Flaps up/down\n\n"
		ctrl_text += "L:\n  Toggle landing gear\n\n"
		ctrl_text += "ALT:\n  Freelook\n\n"
		ctrl_text += "J:\n  Break part\n\n"
	elif v is Car:
		ctrl_text += "W:\n  Accelerate\n\n"
		ctrl_text += "S:\n  Brake\n\n"
		ctrl_text += "Q/E:\n  Steer left/right\n\n"
		ctrl_text += "J:\n  Break wheel\n\n"
	ctrl_text += "U:\n  Exit vehicle\n\n"
	ctrl_text += "O:\n  Toggle camera\n\n"
	ctrl_text += "[P] Toggle Debug"

	controls_label.text = ctrl_text

func _update_force_arrows() -> void:
	# Remove old arrows
	for arrow_name in force_arrows:
		if arrow_name not in vehicle.debug_forces:
			force_arrows[arrow_name].queue_free()
			force_arrows.erase(arrow_name)

	# Update/create arrows for each force
	for force_name in vehicle.debug_forces:
		var force_data: Dictionary = vehicle.debug_forces[force_name]
		var force: Vector3 = force_data.force
		var color: Color = force_data.color

		var arrow: Node3D
		if force_name in force_arrows:
			arrow = force_arrows[force_name]
		else:
			arrow = _create_arrow(color)
			arrow.name = "Arrow_" + force_name
			add_child(arrow)
			force_arrows[force_name] = arrow

		# Update arrow transform
		_orient_arrow(arrow, force, color)

func _create_arrow(color: Color) -> Node3D:
	var arrow := Node3D.new()

	# Shaft (cylinder)
	var shaft := MeshInstance3D.new()
	shaft.name = "Shaft"
	var shaft_mesh := CylinderMesh.new()
	shaft_mesh.top_radius = 0.05
	shaft_mesh.bottom_radius = 0.05
	shaft_mesh.height = 1.0
	shaft.mesh = shaft_mesh
	arrow.add_child(shaft)

	# Head (cone)
	var head := MeshInstance3D.new()
	head.name = "Head"
	var head_mesh := CylinderMesh.new()
	head_mesh.top_radius = 0.0
	head_mesh.bottom_radius = 0.15
	head_mesh.height = 0.3
	head.mesh = head_mesh
	arrow.add_child(head)

	# Material
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.5
	shaft.material_override = mat
	head.material_override = mat

	return arrow

func _orient_arrow(arrow: Node3D, force: Vector3, color: Color) -> void:
	# Skip if force is invalid or too small
	if not force.is_finite() or force.length() < 1.0:
		arrow.visible = false
		return

	var length: float = force.length() * VECTOR_SCALE
	length = clamp(length, MIN_ARROW_LENGTH, MAX_ARROW_LENGTH)

	if not is_finite(length) or length < MIN_ARROW_LENGTH:
		arrow.visible = false
		return

	arrow.visible = true

	# Point arrow in force direction
	var direction: Vector3 = force.normalized()
	if not direction.is_finite():
		arrow.visible = false
		return

	arrow.global_position = vehicle.global_position
	if not arrow.global_position.is_finite():
		arrow.visible = false
		return

	# Look at target (force direction)
	# Use a different up vector if direction is nearly parallel to UP
	var target: Vector3 = arrow.global_position + direction
	if target.is_equal_approx(arrow.global_position):
		arrow.visible = false
		return
	var up_vec: Vector3 = Vector3.UP
	if absf(direction.dot(Vector3.UP)) > 0.99:
		up_vec = Vector3.FORWARD
	arrow.look_at(target, up_vec)
	arrow.rotate_object_local(Vector3.RIGHT, PI/2)

	# Scale shaft
	var shaft := arrow.get_node("Shaft") as MeshInstance3D
	var head := arrow.get_node("Head") as MeshInstance3D

	shaft.position = Vector3(0, length / 2, 0)
	shaft.scale = Vector3(1, length, 1)

	head.position = Vector3(0, length + 0.15, 0)

	# Update color
	var mat := shaft.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color = color
		mat.emission = color
