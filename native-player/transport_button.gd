extends Button
var glyph := "play":
	set(value):
		glyph = value
		queue_redraw()
var active := false:
	set(value):
		active = value
		queue_redraw()

func _draw():
	var color := Color(0.56, 0.83, 1.0) if active else Color(0.94, 0.96, 1.0)
	if disabled: color.a = 0.32
	var c := size * 0.5
	match glyph:
		"play": draw_colored_polygon(PackedVector2Array([c + Vector2(-5,-8), c + Vector2(8,0), c + Vector2(-5,8)]), color)
		"pause":
			draw_rect(Rect2(c + Vector2(-7,-8),Vector2(5,16)),color)
			draw_rect(Rect2(c + Vector2(2,-8),Vector2(5,16)),color)
		"stop": draw_rect(Rect2(c - Vector2(7,7),Vector2(14,14)),color)
		"previous", "next":
			var direction := -1 if glyph == "previous" else 1
			for shift in [-3, 4]:
				draw_colored_polygon(PackedVector2Array([c + Vector2((shift-5)*direction,-7), c + Vector2((shift+3)*direction,0), c + Vector2((shift-5)*direction,7)]),color)
			draw_line(c + Vector2(9*direction,-8),c + Vector2(9*direction,8),color,2,true)
		"shuffle":
			draw_polyline(PackedVector2Array([c+Vector2(-9,-6),c+Vector2(-4,-6),c+Vector2(4,6),c+Vector2(9,6)]),color,2,true)
			draw_polyline(PackedVector2Array([c+Vector2(-9,6),c+Vector2(-4,6),c+Vector2(4,-6),c+Vector2(9,-6)]),color,2,true)
			for y in [-6,6]: draw_polyline(PackedVector2Array([c+Vector2(5,y-3),c+Vector2(9,y),c+Vector2(5,y+3)]),color,2,true)
		"repeat", "repeat_one":
			draw_polyline(PackedVector2Array([c+Vector2(-8,2),c+Vector2(-8,-5),c+Vector2(8,-5),c+Vector2(8,-2)]),color,2,true)
			draw_polyline(PackedVector2Array([c+Vector2(8,-2),c+Vector2(8,5),c+Vector2(-8,5),c+Vector2(-8,2)]),color,2,true)
			draw_polyline(PackedVector2Array([c+Vector2(4,-9),c+Vector2(8,-5),c+Vector2(4,-1)]),color,2,true)
			draw_polyline(PackedVector2Array([c+Vector2(-4,1),c+Vector2(-8,5),c+Vector2(-4,9)]),color,2,true)
			if glyph == "repeat_one": draw_line(c+Vector2(0,-2),c+Vector2(0,2),color,2,true)
