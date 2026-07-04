## Notification.gd
## A single HUD notification label that floats up and fades out.
## Instantiated by HUD._show_notification().
##
extends Label

func show_text(text: String, color: Color = Color.WHITE, duration: float = 2.5) -> void:
	self.text = text
	add_theme_color_override("font_color", color)
	modulate.a = 1.0

	var tween := create_tween().set_parallel()
	tween.tween_property(self, "position:y", position.y - 20.0, duration * 0.6)
	tween.tween_property(self, "modulate:a", 0.0, duration * 0.4) \
		.set_delay(duration * 0.6)
	tween.chain().tween_callback(queue_free)
