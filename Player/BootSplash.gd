extends CanvasLayer
## The boot splash, stage two. The engine's native splash cuts to the
## first rendered frame the moment the scene loads — no hold, no fade.
## This overlay (spawned by Boot.gd on real windowed launches) shows the
## SAME art on a top canvas layer, holds it so the poster is always on
## screen at least HOLD_S after launch, then dissolves it over the now
## live title menu and island and frees itself. Loading slower than the
## hold? The overlay simply stays until its fade — the native splash
## below it shows identical pixels, so the swap is invisible.

const ART := "res://imports/sleblerskersload_cover_small.png"
const HOLD_S := 2.5
const FADE_S := 0.9


func _ready() -> void:
	layer = 100
	# The art, edge to edge (the image is a 16:9 black-canvas composite,
	# so covered-stretch is exact on 16:9 windows and safe on others).
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var art := TextureRect.new()
	art.texture = load(ART)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)
	# Hold, then dissolve everything (layer children fade, not the
	# CanvasLayer — it has no modulate of its own).
	var tw := create_tween()
	tw.tween_interval(HOLD_S)
	tw.tween_property(bg, "modulate:a", 0.0, FADE_S)
	tw.parallel().tween_property(art, "modulate:a", 0.0, FADE_S)
	tw.tween_callback(queue_free)
