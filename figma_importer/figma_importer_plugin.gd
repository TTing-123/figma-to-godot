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
	# 选完或取消后都释放对话框，避免每次点菜单都泄漏一个 FileDialog
	dialog.file_selected.connect(func(path): _on_json_file_selected(path, dialog))
	dialog.canceled.connect(dialog.queue_free)
	EditorInterface.get_base_control().add_child(dialog)
	dialog.popup_centered(Vector2i(800, 600))

func _on_json_file_selected(json_path: String, dialog: FileDialog):
	print("[FigmaImporter] 导入 JSON: %s" % json_path)

	# 创建输出路径（自动递增后缀避免覆盖）
	var output_dir = "res://scenes/"
	var base_name = json_path.get_file().get_basename()
	var output_path = _get_unique_path(output_dir, base_name, ".tscn")

	# 使用本地导入器
	var importer = FigmaLocalImporter.new()
	var error = await importer.import_from_file(json_path, output_path)

	# 导入完成（无论成功与否）后释放对话框
	if is_instance_valid(dialog):
		dialog.queue_free()

	if error == OK:
		print("[FigmaImporter] 导入成功: %s" % output_path)
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
