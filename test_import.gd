extends SceneTree

var _started = false

func _init():
	print("=== Test Import ===")

func _process(_delta):
	if _started:
		return
	_started = true

	var json_path = "D:/Matrix_Engine/project/design-to-godot/figma_export.json"
	var output_path = "res://scenes/figma_export.tscn"

	var importer = FigmaLocalImporter.new()
	var error = importer.import_from_file(json_path, output_path)

	if error == OK:
		print("SUCCESS!")
	else:
		print("FAILED: %d" % error)

	quit()
