class_name VikingDrone
extends Node
## The score's foundation: one low viking drone, synthesized once and
## shared. Five detuned partials over a 55 Hz root breathe against
## each other (slow amplitude beats, like a choir holding one syllable)
## over a whisper of filtered air. It swells up on the title screen and,
## because the node lives on the tree ROOT, it survives the scene
## change and carries into the island — where it eases down to its
## ambient level and keeps humming under the whole game.
##
## Title.gd spawns it; L_Main finds it (or starts it directly when the
## game is launched straight into the island) and calls to_ambient().

const TITLE_DB := -15.0    # present under the title screen (user: too loud)
const AMBIENT_DB := -21.0  # ducked under island gameplay
const SWELL_S := 2.4       # title swell time
const DUCK_S := 3.5        # ease into the island

## True when the drone should start straight at its ambient level
## (launched into the island without the title screen).
var start_ambient := false

var _player: AudioStreamPlayer
static var _stream: AudioStreamWAV = null


func _ready() -> void:
	add_to_group("music_drone")
	_player = AudioStreamPlayer.new()
	_player.stream = _make_stream()
	_player.volume_db = -60.0
	add_child(_player)
	_player.play()
	if start_ambient:
		_player.volume_db = AMBIENT_DB
	else:
		swell_in()


## Title screen: swell up from silence.
func swell_in() -> void:
	var tw := create_tween()
	tw.tween_property(_player, "volume_db", TITLE_DB, SWELL_S) \
			.set_ease(Tween.EASE_IN_OUT)


## The island: ease down to the ambient bed (seamless, no restart).
func to_ambient() -> void:
	var tw := create_tween()
	tw.tween_property(_player, "volume_db", AMBIENT_DB, DUCK_S) \
			.set_ease(Tween.EASE_IN_OUT)


## One seamless 8-second loop: a 55 Hz root with five inharmonically
## breathing partials + air. The slow beat frequencies are chosen so
## no amplitude LFO completes a whole cycle at the seam (the loop is
## fade-safe), and the partials are exact integer multiples so the
## fundamental phase wraps cleanly.
static func _make_stream() -> AudioStreamWAV:
	if _stream != null:
		return _stream
	var rate := 22050
	var t_len := 8.0
	var n := int(rate * t_len)
	var bytes := PackedByteArray()
	bytes.resize(n * 2)
	# Partials: (multiple, level, beat freq, beat depth, phase)
	var parts := [
		[1.0, 0.55, 0.11, 0.22, 0.0],
		[2.0, 0.30, 0.07, 0.30, 1.1],
		[3.0, 0.14, 0.13, 0.35, 2.3],
		[4.0, 0.10, 0.09, 0.40, 0.7],
		[6.0, 0.05, 0.05, 0.45, 3.9],
	]
	# A whisper of filtered air (integrated noise, normalized) for breath.
	var air := 0.0
	var peak := 0.0
	var smp := PackedFloat32Array()
	smp.resize(n)
	for i in n:
		var t := float(i) / rate
		var v := 0.0
		for p_v in parts:
			var p: Array = p_v
			var amp: float = p[1] * (1.0 + p[3]
					* sin(TAU * p[2] * t + p[4]))
			v += amp * sin(TAU * (55.0 * p[0]) * t)
		air += (randf() * 2.0 - 1.0 - air) * 0.02
		v += air * 0.55
		smp[i] = v
		peak = maxf(peak, absf(v))
	var norm := 0.82 / maxf(peak, 0.0001)
	for i in n:
		bytes.encode_s16(i * 2, int(clampf(smp[i] * norm, -1.0, 1.0)
				* 32000.0))
	var ws := AudioStreamWAV.new()
	ws.format = AudioStreamWAV.FORMAT_16_BITS
	ws.mix_rate = rate
	ws.stereo = false
	ws.loop_mode = AudioStreamWAV.LOOP_FORWARD
	ws.loop_begin = 0
	ws.loop_end = n
	ws.data = bytes
	_stream = ws
	return ws
