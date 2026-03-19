extends Node3D

## Manages AI aircraft spawning: one every 30 seconds until 3 are alive.
## Respawns replacements when planes are destroyed.

const AIAircraftScript = preload("res://scenes/vehicles/ai_aircraft.gd")
const MAX_AI_PLANES  := 3
const SPAWN_INTERVAL := 600.0

# Spread-out starting positions at altitude
const SPAWN_POSITIONS := [
	Vector3(500.0, 600.0, 500.0),
	Vector3(-800.0, 550.0, 200.0),
	Vector3(200.0, 700.0, -600.0),
]

var _spawn_timer: float = SPAWN_INTERVAL
var _spawn_idx: int = 0


func _process(delta: float) -> void:
	var alive := get_tree().get_nodes_in_group("ai_aircraft").size()
	if alive < MAX_AI_PLANES:
		_spawn_timer -= delta
		if _spawn_timer <= 0.0:
			_spawn_plane()
			_spawn_timer = SPAWN_INTERVAL


func _spawn_plane() -> void:
	var plane := RigidBody3D.new()
	plane.set_script(AIAircraftScript)
	add_child(plane)
	var base: Vector3 = SPAWN_POSITIONS[_spawn_idx % SPAWN_POSITIONS.size()]
	_spawn_idx += 1
	plane.global_position = base + Vector3(
		randf_range(-150.0, 150.0), 0.0, randf_range(-150.0, 150.0))
