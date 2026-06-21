@tool
extends EditorPlugin

func _enter_tree():
	add_tool_menu_item("Import Figma JSON...", _on_import_json_pressed)
	print("[FigmaImporter] Plugin loaded")

func _exit_tree():
	remove_tool_menu_item("Import Figma JSON...")

func _on_import_json_pressed():
	# 打开文件选择对话框
	var dialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.filters = PackedStringArray(["*.json ; JSON Files"])
	dialog.title = "选择 Figma 导出的 JSON 文件"
	dialog.file_selected.connect(_on_json_file_selected)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))

func _on_json_file_selected(json_path: String):
	print("[FigmaImporter] 导入 JSON: %s" % json_path)

	# 创建输出路径（自动递增后缀避免覆盖）
	var output_dir = "res://scenes/"
	var base_name = json_path.get_file().get_basename()
	var output_path = _get_unique_path(output_dir, base_name, ".tscn")

	# 使用本地导入器
	var importer = FigmaLocalImporter.new()
	var error = await importer.import_from_file(json_path, output_path)

	if error == OK:
		print("[FigmaImporter] 导入成功: %s" % output_path)
		# 删除 SVG 的旧导入缓存，确保 scan() 时用 .import 中的 svg/scale=3.0 重新导入
		_clear_svg_import_cache(output_path)
		EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("[FigmaImporter] 导入失败: %d" % error)

func _get_unique_path(dir: String, base_name: String, ext: String) -> String:
	# 检查文件是否存在，如果存在则添加递增数字后缀
	var path = dir + base_name + ext
	var counter = 1

	while FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path.get_basename()):
		path = dir + base_name + str(counter) + ext
		counter += 1

	return path

func _clear_svg_import_cache(output_path: String) -> void:
	# 找到场景对应的 assets 目录，删除其中 SVG 的 .godot/imported 缓存
	var scene_name = output_path.get_file().get_basename()
	var base_name = scene_name.rstrip("0123456789")
	var suffix = scene_name.substr(base_name.length())
	var assets_dir = "res://%s_assets%s/vectors/" % [base_name, suffix if suffix.length() > 0 else ""]

	var dir = DirAccess.open(assets_dir)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name.ends_with(".svg"):
			# 删除 .godot/imported 中对应的 .ctex 缓存
			var svg_res_path = assets_dir + file_name
			var imported_dir = "res://.godot/imported/"
			var import_dir_access = DirAccess.open(imported_dir)
			if import_dir_access:
				import_dir_access.list_dir_begin()
				var cached = import_dir_access.get_next()
				var svg_base = file_name.get_basename()
				while cached != "":
					if cached.begins_with(svg_base + ".svg-") and cached.ends_with(".ctex"):
						var cache_path = imported_dir + cached
						DirAccess.remove_absolute(cache_path)
						print("[FigmaImporter] 删除旧缓存: %s" % cache_path)
					cached = import_dir_access.get_next()
				import_dir_access.list_dir_end()
		file_name = dir.get_next()
	dir.list_dir_end()
