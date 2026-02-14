extends AudioStreamPlayer3D

## Procedural engine sound synthesizer.
## Auto-detects vehicle type from parent and generates appropriate waveform
## that responds to throttle/collective in real time.

const MIX_RATE := 22050
const BUFFER_LENGTH := 0.1

var _playback: AudioStreamGeneratorPlayback
var _phase: float = 0.0        # main oscillator phase
var _phase2: float = 0.0       # secondary oscillator
var _phase3: float = 0.0       # tertiary oscillator
var _vehicle: Vehicle
var _smoothed_power: float = 0.0


func _ready() -> void:
	_vehicle = get_parent() as Vehicle
	if not _vehicle:
		queue_free()
		return

	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = BUFFER_LENGTH
	stream = gen

	max_distance = 200.0
	unit_size = 15.0
	attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	volume_db = -6.0

	play()
	_playback = get_stream_playback()


func _physics_process(delta: float) -> void:
	if not _playback:
		return

	var power := _get_power()
	_smoothed_power = lerp(_smoothed_power, power, minf(8.0 * delta, 1.0))

	var frames := _playback.get_frames_available()
	if frames <= 0:
		return

	# Push silence when engine is off
	if _smoothed_power < 0.005:
		for i in range(frames):
			_playback.push_frame(Vector2.ZERO)
		return

	if _vehicle is Helicopter:
		_fill_rotor(frames)
	elif _vehicle is Jet:
		_fill_turbine(frames)
	elif _vehicle is FixedWing:
		_fill_propeller(frames)
	elif _vehicle is Car:
		_fill_car_engine(frames)


func _get_power() -> float:
	if not _vehicle.engine_running:
		return 0.0
	if _vehicle is Helicopter:
		return _vehicle.rotor_speed
	elif _vehicle is Car:
		return absf(_vehicle.throttle_input)
	elif "throttle" in _vehicle:
		# Idle power when engine running but throttle at zero
		return maxf(_vehicle.throttle, 0.1)
	return 0.0


# --- Propeller: sawtooth with harmonics for buzzy prop drone ---

func _fill_propeller(frames: int) -> void:
	var freq := lerpf(30.0, 85.0, _smoothed_power)
	var vol := lerpf(0.08, 0.45, _smoothed_power)
	var step := freq / MIX_RATE
	var step2 := freq * 2.0 / MIX_RATE  # 1st harmonic

	for i in range(frames):
		# Sawtooth fundamental
		var saw := _phase * 2.0 - 1.0
		# Softer octave harmonic
		var harm := _phase2 * 2.0 - 1.0
		var sample := (saw * 0.7 + harm * 0.15) * vol

		_playback.push_frame(Vector2(sample, sample))
		_phase = fmod(_phase + step, 1.0)
		_phase2 = fmod(_phase2 + step2, 1.0)


# --- Helicopter rotor: pulse wave at blade-pass frequency ---

func _fill_rotor(frames: int) -> void:
	var heli: Helicopter = _vehicle as Helicopter
	var blade_count := heli.blade_count
	# Blade-pass frequency = RPM/60 * blade_count, scaled by rotor_speed
	var bpf := (heli.rotor_rpm / 60.0) * blade_count * _smoothed_power
	var freq := clampf(bpf, 5.0, 120.0)
	var vol := lerpf(0.0, 0.5, _smoothed_power)
	var step := freq / MIX_RATE
	# Pulse width narrows at higher speed for sharper thwop
	var pulse_w := lerpf(0.5, 0.25, _smoothed_power)

	# Low rumble from turbine
	var turbine_freq := lerpf(80.0, 220.0, _smoothed_power)
	var turbine_step := turbine_freq / MIX_RATE
	var turbine_vol := lerpf(0.02, 0.15, _smoothed_power)

	for i in range(frames):
		# Pulse wave for blade thwop
		var pulse := 1.0 if _phase < pulse_w else -1.0
		# Add turbine whine underneath
		var turbine := sin(_phase2 * TAU) * turbine_vol
		var sample := pulse * vol * 0.6 + turbine

		_playback.push_frame(Vector2(sample, sample))
		_phase = fmod(_phase + step, 1.0)
		_phase2 = fmod(_phase2 + turbine_step, 1.0)


# --- Jet turbine: sine whine + filtered noise ---

func _fill_turbine(frames: int) -> void:
	var jet: Jet = _vehicle as Jet
	# Core turbine whine
	var freq := lerpf(60.0, 240.0, _smoothed_power)
	var vol := lerpf(0.06, 0.35, _smoothed_power)
	var step := freq / MIX_RATE

	# Second harmonic
	var step2 := freq * 1.5 / MIX_RATE
	var harm_vol := vol * 0.3

	# Noise rumble (more with afterburner)
	var noise_vol := lerpf(0.02, 0.12, _smoothed_power)
	if jet.afterburner_active:
		noise_vol *= 2.5
		vol *= 1.3

	for i in range(frames):
		var tone := sin(_phase * TAU) * vol
		var harm := sin(_phase2 * TAU) * harm_vol
		# Cheap filtered noise: smooth random
		var noise := (randf() * 2.0 - 1.0) * noise_vol
		var sample := tone + harm + noise

		_playback.push_frame(Vector2(sample, sample))
		_phase = fmod(_phase + step, 1.0)
		_phase2 = fmod(_phase2 + step2, 1.0)


# --- Car engine: layered sines at engine RPM harmonics ---

func _fill_car_engine(frames: int) -> void:
	# Simulate RPM from speed + throttle
	var car: Car = _vehicle as Car
	var speed_factor := clampf(car.airspeed / car.max_speed, 0.0, 1.0)
	var rpm_norm := clampf(_smoothed_power * 0.6 + speed_factor * 0.4, 0.05, 1.0)

	# Fundamental firing frequency
	var freq := lerpf(35.0, 110.0, rpm_norm)
	var vol := lerpf(0.08, 0.4, rpm_norm)
	var step := freq / MIX_RATE
	var step2 := freq * 2.0 / MIX_RATE  # 2nd harmonic
	var step3 := freq * 3.0 / MIX_RATE  # 3rd harmonic

	for i in range(frames):
		var f1 := sin(_phase * TAU)
		var f2 := sin(_phase2 * TAU) * 0.5
		var f3 := sin(_phase3 * TAU) * 0.25
		var sample := (f1 + f2 + f3) * vol * 0.57  # normalize

		_playback.push_frame(Vector2(sample, sample))
		_phase = fmod(_phase + step, 1.0)
		_phase2 = fmod(_phase2 + step2, 1.0)
		_phase3 = fmod(_phase3 + step3, 1.0)
