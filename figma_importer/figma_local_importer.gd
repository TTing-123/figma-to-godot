class_name FigmaLocalImporter
extends RefCounted

signal progress_changed(message: String, percent: float)

# 节点类型映射 - 全部用 Control，避免容器布局问题
const TYPE_MAP = {
	"FRAME": "Control",
	"GROUP": "Control",
	"VECTOR": "TextureRect",
	"BOOLEAN": "TextureRect",
	"STAR": "TextureRect",
	"LINE": "TextureRect",
	"ELLIPSE": "TextureRect",
	"REGULAR_POLYGON": "TextureRect",
	"RECTANGLE": "Panel",
	"TEXT": "Label",
	"SLICE": "Control",
	"COMPONENT": "Control",
	"COMPONENT_SET": "Control",
	"INSTANCE": "Control",
}

var _resource_id_counter: int = 0
var _ext_resources: Array[Dictionary] = []
var _sub_resources: Array[Dictionary] = []
var _nodes: PackedStringArray = []
var _name_counter: Dictionary = {}
var _image_cache: Dictionary = {}
var _vector_cache: Dictionary = {}
var _vector_size_cache: Dictionary = {}
var _font_cache: Dictionary = {}  # { "fontFamily_fontWeight": "res://path/to/font.ttf" }

func import_from_file(json_path: String, output_path: String) -> Error:
	# 读取 JSON 文件
	progress_changed.emit("读取文件...", 0.1)
	var file = FileAccess.open(json_path, FileAccess.READ)
	if not file:
		push_error("无法打开文件: %s" % json_path)
		return ERR_FILE_NOT_FOUND

	var json_text = file.get_as_text()
	file.close()

	# 解析 JSON
	progress_changed.emit("解析 JSON...", 0.2)
	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		push_error("JSON 解析失败: %s" % json.get_error_message())
		return ERR_PARSE_ERROR

	var data = json.data
	if not data is Dictionary:
		push_error("JSON 格式错误：根节点不是对象")
		return ERR_INVALID_DATA

	# 提取资源（根据输出路径生成对应的资源目录）
	progress_changed.emit("提取资源...", 0.3)
	var scene_name = output_path.get_file().get_basename()
	# 去掉末尾的数字后缀，统一用 figma_export_assets
	var base_name = scene_name.rstrip("0123456789")
	var assets_dir = "res://%s_assets/" % base_name
	# 如果场景名有数字后缀，加到 assets 后面
	var suffix = scene_name.substr(base_name.length())
	if suffix.length() > 0:
		assets_dir = "res://%s_assets%s/" % [base_name, suffix]
	_extract_resources(data, assets_dir)

	# 查找字体资源
	progress_changed.emit("查找字体...", 0.5)
	var fonts = data.get("fonts", {})
	if not fonts.is_empty():
		_find_fonts(fonts, assets_dir)

	# 生成场景
	progress_changed.emit("生成场景...", 0.6)
	var nodes = data.get("nodes", [])
	if nodes.is_empty():
		push_error("没有找到节点数据")
		return ERR_INVALID_DATA

	# 使用第一个选中的节点作为根节点
	var root_node = nodes[0]
	var scene_content = _generate_scene(root_node)

	# 保存文件
	progress_changed.emit("保存文件...", 0.9)
	var dir = DirAccess.open("res://")
	if dir:
		var output_dir = output_path.get_base_dir()
		if not dir.dir_exists(output_dir):
			dir.make_dir_recursive(output_dir)

	var out_file = FileAccess.open(output_path, FileAccess.WRITE)
	if not out_file:
		push_error("无法写入文件: %s" % output_path)
		return ERR_CANT_CREATE

	out_file.store_string(scene_content)
	out_file.close()

	progress_changed.emit("导入完成！", 1.0)
	return OK

func _extract_resources(data: Dictionary, assets_dir: String) -> void:
	# 使用传入的资源目录
	var images_dir = assets_dir + "images/"
	var vectors_dir = assets_dir + "vectors/"

	# 确保目录存在
	DirAccess.make_dir_recursive_absolute(images_dir)
	DirAccess.make_dir_recursive_absolute(vectors_dir)

	# 提取图片资源
	var images = data.get("images", {})
	for ref in images:
		var base64_data = images[ref]
		var safe_name = _sanitize_filename(ref)
		var image_path = images_dir + "%s.png" % safe_name
		_save_base64_image(base64_data, image_path)
		_image_cache[ref] = image_path

	# 收集所有TEXT节点的ID，这些节点不应该被转换为图片
	var text_node_ids = _collect_text_node_ids(data.get("nodes", []))

	# 提取矢量资源（SVG 字符串 → 栅格化成 PNG）
	var vectors = data.get("vectors", {})
	for node_id in vectors:
		# 跳过TEXT类型的节点，保持为Label而不是图片
		if node_id in text_node_ids:
			continue

		var svg_text = vectors[node_id]
		var safe_name = _sanitize_filename(node_id)
		var png_path = vectors_dir + "%s.png" % safe_name
		# SVG 含完整路径数据，栅格化成 PNG（3x scale）
		var svg_bytes = svg_text.to_utf8_buffer()
		var img := Image.new()
		if img.load_svg_from_buffer(svg_bytes, 3.0) == OK:
			img.save_png(png_path)
			_vector_cache[node_id] = png_path
			_vector_size_cache[node_id] = Vector2(img.get_width(), img.get_height())
		else:
			push_warning("[FigmaImporter] SVG 栅格化失败: %s" % node_id)

func _find_fonts(fonts: Dictionary, assets_dir: String) -> void:
	# 字体目录
	var fonts_dir = assets_dir + "fonts/"
	var font_dirs = [fonts_dir, "res://fonts/", "res://assets/fonts/"]

	# 确保字体目录存在
	DirAccess.make_dir_recursive_absolute(fonts_dir)

	# 收集项目中所有 .ttf 和 .otf 文件
	var all_fonts: PackedStringArray = []
	for font_dir in font_dirs:
		_collect_fonts_recursive(font_dir, all_fonts)

	# 为每个需要的字体查找匹配的文件
	for font_key in fonts:
		var font_info = fonts[font_key]
		var family = font_info.get("family", "")
		var style = font_info.get("style", "")

		# 尝试查找匹配的字体文件
		var matched_font = _find_matching_font(family, style, all_fonts)
		if matched_font:
			_font_cache[font_key] = matched_font
		else:
			# 尝试自动下载字体
			var downloaded = _download_font_from_google(family, style, fonts_dir)
			if downloaded:
				_font_cache[font_key] = downloaded

	# 打印结果
	if _font_cache.size() > 0:
		print("[FigmaImporter] 字体: %d/%d 已加载" % [_font_cache.size(), fonts.size()])
	else:
		print("[FigmaImporter] 未找到字体，请手动下载到 %s" % fonts_dir)

func _download_font_from_google(family: String, style: String, target_dir: String) -> String:
	# 构建字体文件名
	var font_filename = "%s-%s.ttf" % [family.replace(" ", ""), style]
	var font_path = target_dir + font_filename

	# 步骤1: 从 Google Fonts CSS API 获取字体文件 URL
	var weight = _get_weight(style)
	var family_encoded = family.replace(" ", "+")
	var css_url = "https://fonts.googleapis.com/css2?family=%s:wght@%s" % [family_encoded, weight]

	# 使用 HTTPClient 下载 CSS
	var http = HTTPClient.new()
	var err = http.connect_to_host("fonts.googleapis.com", 443, TLSOptions.client())
	if err != OK:
		return ""

	var _deadline := Time.get_ticks_msec() + 15000
	while http.get_status() == HTTPClient.STATUS_CONNECTING or http.get_status() == HTTPClient.STATUS_RESOLVING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		http.poll()
		OS.delay_usec(10000)

	if http.get_status() != HTTPClient.STATUS_CONNECTED:
		return ""

	# 发送请求（需要特定 User-Agent 才能获取 TTF 格式）
	var headers = ["User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"]
	err = http.request(HTTPClient.METHOD_GET, "/css2?family=%s:wght@%s" % [family_encoded, weight], headers)
	if err != OK:
		return ""

	_deadline = Time.get_ticks_msec() + 15000
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		http.poll()
		OS.delay_usec(10000)

	# 读取 CSS 响应
	var response_body = PackedByteArray()
	if http.has_response():
		var _body_deadline := Time.get_ticks_msec() + 15000
		while http.get_status() == HTTPClient.STATUS_BODY:
			if Time.get_ticks_msec() > _body_deadline:
				return ""
			http.poll()
			var chunk = http.read_response_body_chunk()
			if chunk.size() > 0:
				response_body.append_array(chunk)
			else:
				OS.delay_usec(1000)

	var css_text = response_body.get_string_from_utf8()

	# 步骤2: 从 CSS 中提取 TTF 文件 URL
	var regex = RegEx.new()
	regex.compile("url\\((https://fonts\\.gstatic\\.com/[^)]+\\.ttf)\\)")
	var result = regex.search(css_text)
	if not result:
		return ""

	var font_url = result.get_string(1)

	# 步骤3: 下载 TTF 文件
	var font_http = HTTPClient.new()
	var url_parts = font_url.substr(8).split("/")
	var host = url_parts[0]
	var path = "/" + "/".join(Array(url_parts).slice(1))

	err = font_http.connect_to_host(host, 443, TLSOptions.client())
	if err != OK:
		return ""

	_deadline = Time.get_ticks_msec() + 15000
	while font_http.get_status() == HTTPClient.STATUS_CONNECTING or font_http.get_status() == HTTPClient.STATUS_RESOLVING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		font_http.poll()
		OS.delay_usec(10000)

	if font_http.get_status() != HTTPClient.STATUS_CONNECTED:
		return ""

	err = font_http.request(HTTPClient.METHOD_GET, path, ["User-Agent: Mozilla/5.0"])
	if err != OK:
		return ""

	_deadline = Time.get_ticks_msec() + 15000
	while font_http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		font_http.poll()
		OS.delay_usec(10000)

	var font_data = PackedByteArray()
	if font_http.has_response():
		var _body_deadline := Time.get_ticks_msec() + 15000
		while font_http.get_status() == HTTPClient.STATUS_BODY:
			if Time.get_ticks_msec() > _body_deadline:
				push_warning("[FigmaImporter] 字体文件下载超时")
				return ""
			font_http.poll()
			var chunk = font_http.read_response_body_chunk()
			if chunk.size() > 0:
				font_data.append_array(chunk)
			else:
				OS.delay_usec(1000)

	if font_data.size() < 1000:
		return ""

	# 保存字体文件
	var file = FileAccess.open(font_path, FileAccess.WRITE)
	if file:
		file.store_buffer(font_data)
		file.close()
		print("[FigmaImporter] 下载字体: %s" % font_filename)
		return font_path

	return ""

func _get_weight(style: String) -> String:
	match style.to_lower():
		"thin", "hairline":
			return "100"
		"extralight", "ultralight":
			return "200"
		"light":
			return "300"
		"regular", "normal", "book":
			return "400"
		"medium":
			return "500"
		"semibold", "demibold":
			return "600"
		"bold":
			return "700"
		"extrabold", "ultrabold":
			return "800"
		"black", "heavy":
			return "900"
		_:
			return "400"

func _collect_fonts_recursive(dir_path: String, result: PackedStringArray) -> void:
	var dir = DirAccess.open(dir_path)
	if not dir:
		return

	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path = dir_path + file_name
			if dir.current_is_dir():
				_collect_fonts_recursive(full_path + "/", result)
			elif file_name.ends_with(".ttf") or file_name.ends_with(".otf"):
				result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

func _find_matching_font(family: String, style: String, available_fonts: PackedStringArray) -> String:
	# 将字体名称转换为小写用于比较
	var family_lower = family.to_lower()
	var style_lower = style.to_lower()

	# 常见的样式映射
	var style_aliases = {
		"regular": ["regular", "normal", "book", "roman"],
		"bold": ["bold", "heavy", "black"],
		"italic": ["italic", "oblique", "slanted"],
		"bold italic": ["bold italic", "boldoblique", "heavyitalic"],
		"light": ["light", "thin", "hairline"],
		"medium": ["medium", "semibold", "demi"],
	}

	# 第一轮：精确匹配（文件名包含 family + style）
	for font_path in available_fonts:
		var file_name = font_path.get_file().get_basename().to_lower()
		if file_name.contains(family_lower) and file_name.contains(style_lower):
			return font_path

	# 第二轮：只匹配 family，style 为 regular 时优先匹配无 style 的文件
	for font_path in available_fonts:
		var file_name = font_path.get_file().get_basename().to_lower()
		if file_name.contains(family_lower):
			# 如果请求的是 regular，匹配不包含其他样式的文件
			if style_lower == "regular" or style_lower == "normal":
				var is_regular = true
				for other_style in ["bold", "italic", "light", "medium", "thin", "heavy"]:
					if file_name.contains(other_style):
						is_regular = false
						break
				if is_regular:
					return font_path
			# 否则匹配包含样式关键词的文件
			else:
				var aliases = style_aliases.get(style_lower, [style_lower])
				for alias in aliases:
					if file_name.contains(alias):
						return font_path

	# 第三轮：只匹配 family（返回第一个找到的）
	for font_path in available_fonts:
		var file_name = font_path.get_file().get_basename().to_lower()
		if file_name.contains(family_lower):
			return font_path

	return ""

func _collect_text_node_ids(nodes: Array) -> PackedStringArray:
	var text_ids = PackedStringArray()
	for node in nodes:
		if node.get("type", "") == "TEXT":
			text_ids.append(node.get("id", ""))
		# 递归处理子节点
		var children = node.get("children", [])
		if not children.is_empty():
			text_ids.append_array(_collect_text_node_ids(children))
	return text_ids

func _sanitize_filename(name: String) -> String:
	# 替换 Windows 文件名中的非法字符
	var result = name.replace(":", "_").replace(";", "_").replace("\\", "_").replace("/", "_")
	result = result.replace("*", "_").replace("?", "_").replace('"', "_")
	result = result.replace("<", "_").replace(">", "_").replace("|", "_")
	return result

func _save_base64_image(base64_data: String, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var bytes = Marshalls.base64_to_raw(base64_data)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(bytes)
		file.close()

func _generate_scene(root_node: Dictionary) -> String:
	_resource_id_counter = 0
	_ext_resources.clear()
	_sub_resources.clear()
	_nodes.clear()
	_name_counter.clear()

	# 计算所有节点的边界框
	var bounds = _calculate_bounds(root_node)
	var offset_x = bounds.min_x
	var offset_y = bounds.min_y

	# 获取根节点大小
	var root_width = root_node.get("width", 0)
	var root_height = root_node.get("height", 0)

	# 预处理：计算每个节点的父节点绝对坐标
	_preprocess_parent_positions(root_node, {}, offset_x, offset_y, 0, root_width, root_height)

	# 处理根节点
	_process_node(root_node, "", 0)

	# 构建场景文件
	var content = "[gd_scene load_steps=%d format=3]\n\n" % (_resource_id_counter + 2)

	# 添加外部资源（Shader）
	content += '[ext_resource type="Shader" path="res://addons/figma_importer/rounded_rect.gdshader" id="shader_rounded"]\n'

	# 添加其他外部资源
	for ext_res in _ext_resources:
		content += '[ext_resource type="%s" path="%s" id="%d"]\n' % [
			ext_res["type"],
			ext_res["path"],
			ext_res["id"]
		]

	content += "\n"

	# 添加子资源
	for sub_res in _sub_resources:
		content += _format_sub_resource(sub_res)

	# 添加节点
	for node_line in _nodes:
		content += node_line

	return content

func _calculate_bounds(node: Dictionary) -> Dictionary:
	var abs_x = node.get("absoluteX", node.get("x", 0))
	var abs_y = node.get("absoluteY", node.get("y", 0))
	var width = node.get("width", 0)
	var height = node.get("height", 0)

	var bounds = {
		"min_x": abs_x,
		"min_y": abs_y,
		"max_x": abs_x + width,
		"max_y": abs_y + height
	}

	for child in node.get("children", []):
		var child_bounds = _calculate_bounds(child)
		bounds.min_x = min(bounds.min_x, child_bounds.min_x)
		bounds.min_y = min(bounds.min_y, child_bounds.min_y)
		bounds.max_x = max(bounds.max_x, child_bounds.max_x)
		bounds.max_y = max(bounds.max_y, child_bounds.max_y)

	return bounds

func _preprocess_parent_positions(node: Dictionary, parent_pos: Dictionary, offset_x: float = 0, offset_y: float = 0, depth: int = 0, root_width: float = 0, root_height: float = 0) -> void:
	# 父节点不可见时，子节点也不可见（Figma 行为）
	if parent_pos.get("visible", true) == false:
		node["visible"] = false
	# 存储父节点的绝对坐标（已减去全局偏移量）
	var abs_x = node.get("absoluteX", node.get("x", 0)) - offset_x
	var abs_y = node.get("absoluteY", node.get("y", 0)) - offset_y
	node["_abs_x"] = abs_x
	node["_abs_y"] = abs_y
	node["_parent_abs_x"] = parent_pos.get("abs_x", abs_x)
	node["_parent_abs_y"] = parent_pos.get("abs_y", abs_y)

	# 存储根节点大小
	node["_root_width"] = root_width
	node["_root_height"] = root_height
	# 存储节点在根画布中的 UV 位置（用于渐变坐标转换）
	if root_width > 0 and root_height > 0:
		node["_canvas_uv"] = Vector2(abs_x / root_width, abs_y / root_height)

	# 统一用 absoluteX/Y 差值计算相对父节点的偏移
	# 解决 Figma Plugin API 对 GROUP 子节点 x/y 返回绝对坐标的已知问题
	#（FRAME 子节点的 x/y 是相对偏移，但 GROUP 子节点的 x/y = absoluteX/Y）
	var _p_abs_x = parent_pos.get("abs_x", abs_x)
	var _p_abs_y = parent_pos.get("abs_y", abs_y)
	node["_rel_x"] = abs_x - _p_abs_x
	node["_rel_y"] = abs_y - _p_abs_y

	# 存储父节点的裁剪信息和尺寸
	var parent_clips = parent_pos.get("clips_content", false)
	var parent_corner = parent_pos.get("corner_radius", 0)
	node["_parent_clips_content"] = parent_clips
	node["_parent_corner_radius"] = parent_corner if (parent_clips and parent_pos.get("rotation", 0.0) == 0.0) else 0
	node["_parent_size"] = parent_pos.get("size", Vector2.ZERO)
	# 记录节点在父节点中的偏移（用于 shader 中父节点圆角裁剪）
	node["_offset_in_parent"] = Vector2(abs_x - _p_abs_x, abs_y - _p_abs_y)

	# 处理 auto-layout 负间距：重新计算子节点位置，避免重叠
	# Figma 导出的 x/y 已包含 itemSpacing 效果，负间距会导致子节点重叠
	var children = node.get("children", [])
	var layout_mode = node.get("layoutMode", "NONE")
	var item_spacing = node.get("itemSpacing", 0)
	if (layout_mode == "VERTICAL" or layout_mode == "HORIZONTAL") and item_spacing < 0 and children.size() > 1:
		var effective_spacing = max(0, item_spacing)
		if layout_mode == "VERTICAL":
			var py = node.get("paddingTop", 0)
			var p_abs_y = node.get("absoluteY", 0)
			for child in children:
				child["y"] = py
				child["absoluteY"] = p_abs_y + py
				py += child.get("height", 0) + effective_spacing
			# 更新父容器高度以适应不再重叠的子节点
			var new_h = py + node.get("paddingBottom", 0)
			if new_h > node.get("height", 0):
				node["height"] = new_h
				node["absoluteY_end"] = node.get("absoluteY", 0) + new_h
		else:
			var px = node.get("paddingLeft", 0)
			var p_abs_x = node.get("absoluteX", 0)
			for child in children:
				child["x"] = px
				child["absoluteX"] = p_abs_x + px
				px += child.get("width", 0) + effective_spacing
			# 更新父容器宽度以适应不再重叠的子节点
			var new_w = px + node.get("paddingRight", 0)
			if new_w > node.get("width", 0):
				node["width"] = new_w

	# 荧光传递：FRAME 节点的 DROP_SHADOW 荧光效果应传递给后代中的 VECTOR
	# 而不是应用在 FRAME 本身（否则整个面板背景都会发光）
	var node_type = node.get("type", "")
	if node_type != "VECTOR":
		for effect in node.get("effects", []):
			if effect.get("type") == "DROP_SHADOW":
				var eoffset = effect.get("offset", {})
				if eoffset.get("x", 0) == 0 and eoffset.get("y", 0) == 0 and effect.get("radius", 0) >= 5:
					# 递归查找第一个 VECTOR 后代节点传递荧光
					var found = _find_last_vector(children)
					if found:
						var ecolor = effect.get("color", {})
						found["_glow_data"] = {
							"color": "Color(%f, %f, %f, %f)" % [ecolor.get("r",0), ecolor.get("g",0), ecolor.get("b",0), ecolor.get("a",1)],
							"radius": effect.get("radius", 0),
							"intensity": clampf(ecolor.get("a", 1.0) * 2.0, 0.0, 1.0),
						}
					break

	# 递归处理子节点
	# 注意：在Figma中，Group不改变子节点的坐标系统，只有Frame/Component改变
	var is_group = (node_type == "GROUP")
	var current_corner = node.get("cornerRadius", 0)
	var current_clips = node.get("clipsContent", false)
	var current_size = Vector2(node.get("width", 0), node.get("height", 0))

	# 所有节点都使用自己的绝对坐标作为参考点
	# Group 在 Figma 中不改变坐标系统，但 Godot 中每个节点都需要相对父节点的坐标
	# 注意：Figma Plugin API 对 GROUP 内子节点的 absoluteY 有已知 bug
	#（与 GROUP 完全重叠的子节点 absoluteY 会多加 GROUP 的高度），
	# 但这是 API 层面的问题，导出插件无法修复。
	var current_pos = {
		"abs_x": abs_x,
		"abs_y": abs_y,
		"corner_radius": current_corner,
		"clips_content": current_clips,
		"size": current_size,
		"visible": node.get("visible", true),
		"rotation": node.get("rotation", 0.0)
	}
	for child in children:
		_preprocess_parent_positions(child, current_pos, offset_x, offset_y, depth + 1, root_width, root_height)

func _process_node(node: Dictionary, parent_path: String, depth: int) -> void:
	var node_type = node.get("type", "")
	var raw_name = _sanitize_name(node.get("name", "Unnamed"))
	var node_name = _get_unique_name(raw_name, parent_path)
	var node_id = node.get("id", "")
	var corner_radius = node.get("cornerRadius", 0)
	var tl = int(node.get("topLeftRadius", corner_radius))
	var tr = int(node.get("topRightRadius", corner_radius))
	var bl = int(node.get("bottomLeftRadius", corner_radius))
	var br = int(node.get("bottomRightRadius", corner_radius))

	# 获取 Godot 类型
	var godot_type = TYPE_MAP.get(node_type, "Control")

	# 使用预处理阶段计算的相对偏移（基于 absoluteX/Y 差值）
	# Figma Plugin API 对 GROUP 子节点的 x/y 返回绝对坐标（非相对偏移），
	# 直接用 x/y 会导致 GROUP 子节点位置错误。_rel_x/y 已统一修正。
	var x = node.get("_rel_x", node.get("x", 0))
	var y = node.get("_rel_y", node.get("y", 0))
	var width = node.get("width", 0)
	var height = node.get("height", 0)

	# VECTOR 类型修正：SVG 栅格化的 PNG 含完整内容（含描边溢出），
	# 实际像素尺寸 = 内容大小 × 3。需要按情况修正 TextureRect 尺寸。
	if node_type == "VECTOR" and _vector_size_cache.has(node_id):
		var png_size: Vector2 = _vector_size_cache[node_id]
		if png_size.x > 0 and png_size.y > 0:
			if width == 0 and height == 0:
				# 两者都为 0（线条等），使用 PNG 尺寸
				width = png_size.x
				height = png_size.y
			elif width == 0:
				width = height * png_size.x / png_size.y
			elif height == 0:
				height = width * png_size.y / png_size.x
			else:
				# width/height 都有值（AABB）：PNG 可能含描边溢出，比 AABB 大。
				# 用实际内容尺寸（÷3）作为 TextureRect 大小，并居中对齐到节点中心
				# （描边通常对称，节点中心 = 内容中心）。无溢出时 PNG/3≈AABB，几乎无变化。
				var content_w = png_size.x / 3.0
				var content_h = png_size.y / 3.0
				x += (width - content_w) / 2.0
				y += (height - content_h) / 2.0
				width = content_w
				height = content_h

	# 构建节点属性 - 全部使用绝对定位
	var properties: Dictionary = {}
	properties["layout_mode"] = 1  # ANCHORS

	# 使用相对于父节点的坐标
	if depth == 0:
		# 根节点从 (0, 0) 开始
		properties["offset_left"] = 0
		properties["offset_top"] = 0
		properties["offset_right"] = width
		properties["offset_bottom"] = height

		# 根节点圆角
		var root_corner = node.get("cornerRadius", 0)
		if root_corner > 0:
			var style_id = _next_resource_id()
			_sub_resources.append({
				"id": style_id,
				"type": "StyleBoxFlat",
				"properties": {
					"bg_color": "Color(0, 0, 0, 0.01)",
					"corner_radius_top_left": int(root_corner),
					"corner_radius_top_right": int(root_corner),
					"corner_radius_bottom_right": int(root_corner),
					"corner_radius_bottom_left": int(root_corner),
				}
			})
			properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id
			properties["clip_contents"] = true
	else:
		# 子节点：相对父节点的坐标
		#
		# 坐标模型：
		#   Figma: node.x/y = relativeTransform 平移分量 = 旋转后本地原点(0,0)的位置。
		#          旋转绕本地原点(0,0)，旋转后 AABB 中心 = (x,y) + R(θ)·(w/2,h/2)。
		#   Godot: offset_left/top = 未旋转矩形左上角。pivot_offset = 中心 = (w/2,h/2)。
		#          旋转绕 pivot_offset，旋转后 AABB 中心 = (offset_left+w/2, offset_top+h/2)。
		#
		#   令二者 AABB 中心相等 → offset_left = x + (w/2)(cosθ-1) + (h/2)sinθ
		#                           offset_top  = y - (w/2)sinθ   + (h/2)(cosθ-1)
		var _erot = node.get("rotation", 0.0)
		if _erot != 0.0:
			var _th = deg_to_rad(_erot)
			var _cs = cos(_th)
			var _sn = sin(_th)
			var _hw = width / 2.0
			var _hh = height / 2.0
			properties["offset_left"] = x + _hw * (_cs - 1.0) + _hh * _sn
			properties["offset_top"] = y - _hw * _sn + _hh * (_cs - 1.0)
			properties["offset_right"] = properties["offset_left"] + width
			properties["offset_bottom"] = properties["offset_top"] + height
		else:
			properties["offset_left"] = x
			properties["offset_top"] = y
			properties["offset_right"] = x + width
			properties["offset_bottom"] = y + height

	# 处理可见性
	if not node.get("visible", true):
		properties["visible"] = false

	# 处理纯黑色 VECTOR 节点：设为隐藏（Figma 中不可见，导出后不应显示）
	if node_type == "VECTOR" and _is_solid_black_fill(node):
		properties["visible"] = false

	# 处理透明度
	var opacity = node.get("opacity", 1.0)
	if opacity < 1.0:
		properties["modulate"] = "Color(1, 1, 1, %f)" % opacity

	# 处理裁剪：clipsContent=true 时裁剪超出自身边界的子节点（根节点也裁剪，匹配 Figma 根 Frame）
	if node.get("clipsContent", false):
		properties["clip_contents"] = true

	# 处理旋转（Figma rotation 为顺时针角度，绕节点中心）
	var rot = node.get("rotation", 0.0)
	if rot != 0.0:
		properties["pivot_offset"] = "Vector2(%f, %f)" % [width / 2.0, height / 2.0]
		properties["rotation"] = deg_to_rad(rot)

	# 处理样式
	_apply_styles(node, properties, node_id)

	# 动态改变类型
	if properties.has("texture"):
		# 有纹理 → TextureRect
		godot_type = "TextureRect"
		properties["expand_mode"] = 1  # IGNORE_SIZE
		# 如果 _apply_styles 中没有设置 stretch_mode（细线型 Vector），则使用默认值
		if not properties.has("stretch_mode"):
			properties["stretch_mode"] = 5  # KEEP_ASPECT_CENTERED
		# 如果有圆角（自己的或继承的），应用 Shader
		var effective_radius = max(tl, max(tr, max(bl, br)))
		var parent_radius = node.get("_parent_corner_radius", 0)
		var shader_radius = max(effective_radius, parent_radius)
		# 只有父节点有clipsContent时才应用shader裁剪
		var parent_clips = node.get("_parent_clips_content", false)
		if shader_radius > 0 and (parent_clips or effective_radius > 0) or node.has("_shadow_data"):
			# 使用父节点大小作为目标大小（裁剪区域）
			
			
			var shader_id = _next_resource_id()
			_sub_resources.append({
				"id": shader_id,
				"type": "ShaderMaterial",
				"properties": {
					"shader": 'ExtResource("shader_rounded")',
					"shader_parameter/corner_radius": shader_radius,
					"shader_parameter/target_size": "Vector2(%f, %f)" % [width, height],
					"shader_parameter/parent_corner_radius": 0.0,
					"shader_parameter/parent_size": "Vector2(%f, %f)" % [width, height],
					"shader_parameter/offset_in_parent": "Vector2(0.0, 0.0)",
					"shader_parameter/use_texture": true,
				}
			})
			properties["material"] = 'SubResource("%d")' % shader_id
			# 保持节点自身的大小，不改变尺寸
			if node.has("_shadow_data"):
				var _sd = node["_shadow_data"]
				_sub_resources[-1]["properties"]["shader_parameter/use_shadow"] = true
				_sub_resources[-1]["properties"]["shader_parameter/shadow_color"] = _sd["color"]
				_sub_resources[-1]["properties"]["shader_parameter/shadow_size"] = _sd["size"]
				_sub_resources[-1]["properties"]["shader_parameter/shadow_offset"] = _sd["offset"]
		# TextureRect 也可以有荧光效果（如 ring 矢量图）
		elif node.has("_glow_data"):
			var gd2 = node["_glow_data"]
			var shader_id = _next_resource_id()
			_sub_resources.append({
				"id": shader_id,
				"type": "ShaderMaterial",
				"properties": {
					"shader": 'ExtResource("shader_rounded")',
					"shader_parameter/corner_radius": 0.0,
					"shader_parameter/corner_radiuses": "Vector4(0.0, 0.0, 0.0, 0.0)",
					"shader_parameter/target_size": "Vector2(%f, %f)" % [width, height],
					"shader_parameter/parent_corner_radius": 0.0,
					"shader_parameter/parent_size": "Vector2(%f, %f)" % [width, height],
					"shader_parameter/offset_in_parent": "Vector2(0.0, 0.0)",
					"shader_parameter/use_texture": true,
					"shader_parameter/use_glow": true,
					"shader_parameter/glow_color": gd2["color"],
					"shader_parameter/glow_radius": gd2["radius"],
					"shader_parameter/glow_intensity": gd2["intensity"],
				}
			})
			properties["material"] = 'SubResource("%d")' % shader_id
	elif properties.has("theme_override_styles/panel"):
		# 有样式（填充/描边）→ Panel
		if godot_type == "Control":
			godot_type = "Panel"

		# Panel 节点也应用圆角 shader，处理自身圆角和父节点圆角裁剪
		# shader 不调整节点大小，保持原位置（区别于 TextureRect 分支）
		var panel_self_radius = max(tl, max(tr, max(bl, br)))
		var panel_parent_radius = node.get("_parent_corner_radius", 0)
		var panel_parent_size = node.get("_parent_size", Vector2.ZERO)
		var panel_offset_in_parent = node.get("_offset_in_parent", Vector2.ZERO)
		# 当自身有圆角、父节点有圆角裁剪、有渐变填充、或有发光时，应用 shader
		var has_gradient = node.has("_gradient_data")
		var has_glow = node.has("_glow_data")
		if panel_self_radius > 0 or panel_parent_radius > 0 or has_gradient or has_glow:
			var panel_shader_props = {
				"shader": 'ExtResource("shader_rounded")',
				"shader_parameter/corner_radius": float(panel_self_radius),
					"shader_parameter/corner_radiuses": "Vector4(%f, %f, %f, %f)" % [float(br), float(tr), float(bl), float(tl)],
				"shader_parameter/target_size": "Vector2(%f, %f)" % [width, height],
				"shader_parameter/parent_corner_radius": float(panel_parent_radius),
				"shader_parameter/parent_size": "Vector2(%f, %f)" % [panel_parent_size.x, panel_parent_size.y],
				"shader_parameter/offset_in_parent": "Vector2(%f, %f)" % [panel_offset_in_parent.x, panel_offset_in_parent.y],
				"shader_parameter/use_texture": false,
			}
			# 渐变填充：传递渐变参数到 shader
			if node.has("_gradient_data"):
				var gd = node["_gradient_data"]
				panel_shader_props["shader_parameter/use_gradient"] = true
				panel_shader_props["shader_parameter/gradient_type"] = gd.get("type", 0)
				panel_shader_props["shader_parameter/gradient_color1"] = gd["color1"]
				panel_shader_props["shader_parameter/gradient_color2"] = gd["color2"]
				panel_shader_props["shader_parameter/gradient_start"] = gd["start"]
				panel_shader_props["shader_parameter/gradient_end"] = gd["end"]
			# 描边：传递到 shader（独立于渐变）
			if node.has("_stroke_data"):
				var sd = node["_stroke_data"]
				panel_shader_props["shader_parameter/border_width"] = sd["width"]
				panel_shader_props["shader_parameter/border_color"] = sd["color"]
			# 外发光：传递到 shader
			if node.has("_glow_data"):
				var gd2 = node["_glow_data"]
				panel_shader_props["shader_parameter/use_glow"] = true
				panel_shader_props["shader_parameter/glow_color"] = gd2["color"]
				panel_shader_props["shader_parameter/glow_radius"] = gd2["radius"]
				panel_shader_props["shader_parameter/glow_intensity"] = gd2["intensity"]
			# 内阴影：传递到 shader
			if node.has("_inner_shadow_data"):
				var isd = node["_inner_shadow_data"]
				panel_shader_props["shader_parameter/use_inner_shadow"] = true
				panel_shader_props["shader_parameter/inner_shadow_color"] = isd["color"]
				panel_shader_props["shader_parameter/inner_shadow_blur"] = isd["blur"]
				panel_shader_props["shader_parameter/inner_shadow_offset"] = isd["offset"]
			var panel_shader_id = _next_resource_id()
			_sub_resources.append({
				"id": panel_shader_id,
				"type": "ShaderMaterial",
				"properties": panel_shader_props,
			})
			properties["material"] = 'SubResource("%d")' % panel_shader_id

	# 处理文本
	if node_type == "TEXT":
		_apply_text_properties(node, properties)

	# 生成节点定义
	var node_def: String
	if depth == 0:
		node_def = '\n[node name="%s" type="%s"]\n' % [node_name, godot_type]
	elif depth == 1:
		node_def = '\n[node name="%s" type="%s" parent="."]\n' % [node_name, godot_type]
	else:
		node_def = '\n[node name="%s" type="%s" parent="%s"]\n' % [node_name, godot_type, parent_path]

	for key in properties:
		if key.begins_with("_"):
			continue
		var value = properties[key]
		if value is String:
			node_def += "%s = %s\n" % [key, value]
		elif value is float:
			node_def += "%s = %f\n" % [key, value]
		elif value is int:
			node_def += "%s = %d\n" % [key, value]
		elif value is bool:
			node_def += "%s = %s\n" % [key, "true" if value else "false"]

	_nodes.append(node_def)

	# 递归处理子节点
	var current_path: String
	if depth == 0:
		current_path = "."
	else:
		current_path = parent_path + "/" + node_name

	for child in node.get("children", []):
		_process_node(child, current_path, depth + 1)

func _apply_styles(node: Dictionary, properties: Dictionary, node_id: String) -> void:
	var fills = node.get("fills", [])
	var effects = node.get("effects", [])
	var strokes = node.get("strokes", [])
	var stroke_weight = node.get("strokeWeight", 0)

	# 获取圆角值，优先使用独立值
	var corner_radius = node.get("cornerRadius", 0)
	var tl = node.get("topLeftRadius", corner_radius)
	var tr = node.get("topRightRadius", corner_radius)
	var bl = node.get("bottomLeftRadius", corner_radius)
	var br = node.get("bottomRightRadius", corner_radius)

	# TEXT 类型单独处理：fills 是文字颜色（由 _apply_text_properties 处理），
	# 即便 figma 把 TEXT 也按矢量 PNG 导出，也保持 Label，不变 TextureRect。
	var node_type = node.get("type", "")
	var is_text = (node_type == "TEXT")

	# 处理填充（TEXT 跳过：SOLID 是文字颜色）
	if not is_text:
		for fill in fills:
			match fill.get("type"):
				"SOLID":
					var color = _figma_color_to_godot(fill.get("color", {}))
					var style_id = _create_flat_style_ex(color, int(tl), int(tr), int(bl), int(br))
					properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id

				"GRADIENT_LINEAR", "GRADIENT_RADIAL", "GRADIENT_ANGULAR", "GRADIENT_DIAMOND":
					var style_id = _create_gradient_style_ex(fill, int(tl), int(tr), int(bl), int(br))
					if style_id > 0:
						properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id
					# 存储渐变数据供 shader 使用
					var stops = fill.get("gradientStops", [])
					if stops.size() >= 2:
						var c1 = stops[0].get("color", {})
						var c2 = stops[stops.size() - 1].get("color", {})
						# gradientTransform: 2x3 矩阵
						# canvas_pos = gradient_pos * matrix
						# gradient (0,0)->(1,0) 映射到 canvas
						# canvas_x = a*gx + c*gy + e, canvas_y = b*gx + d*gy + f
						var gt = fill.get("gradientTransform", [[1, 0, 0], [0, 1, 0]])
						var sx = gt[0][0] * 0 + gt[0][1] * 0 + gt[0][2]
						var sy = gt[1][0] * 0 + gt[1][1] * 0 + gt[1][2]
						var ex = gt[0][0] * 1 + gt[0][1] * 0 + gt[0][2]
						var ey = gt[1][0] * 1 + gt[1][1] * 0 + gt[1][2]
						# 垂直渐变需要交换 start/end（Figma 垂直渐变方向与 shader 相反）
						var dx = abs(ex - sx)
						var dy = abs(ey - sy)
						if dy > dx:
							var tmp_x = sx; var tmp_y = sy
							sx = ex; sy = ey
							ex = tmp_x; ey = tmp_y
						# 将坐标从 Figma 的 (-0.5, -0.5)→(0.5, 0.5) 映射到 UV 空间的 (0, 0)→(1, 1)
						sx = sx + 0.5
						sy = sy + 0.5
						ex = ex + 0.5
						ey = ey + 0.5
						var _gtype = 0
						if fill.get("type") == "GRADIENT_RADIAL":
							_gtype = 1
						elif fill.get("type") == "GRADIENT_ANGULAR":
							_gtype = 2
						elif fill.get("type") == "GRADIENT_DIAMOND":
							_gtype = 3
						node["_gradient_data"] = {
							"color1": "Color(%f, %f, %f, %f)" % [c1.get("r",0), c1.get("g",0), c1.get("b",0), c1.get("a",1)],
							"color2": "Color(%f, %f, %f, %f)" % [c2.get("r",0), c2.get("g",0), c2.get("b",0), c2.get("a",1)],
							"start": "Vector2(%f, %f)" % [sx, sy],
							"end": "Vector2(%f, %f)" % [ex, ey],
							"type": _gtype,
						}

				"IMAGE":
					var ref = fill.get("imageRef", "")
					if ref and _image_cache.has(ref):
						var res_id = _next_resource_id()
						_ext_resources.append({
							"id": res_id,
							"type": "Texture2D",
							"path": _image_cache[ref]
						})
						properties["texture"] = 'ExtResource("%d")' % res_id

	# 处理矢量（TEXT 跳过：保持 Label）
	if not is_text and _vector_cache.has(node_id):
		var res_id = _next_resource_id()
		_ext_resources.append({
			"id": res_id,
			"type": "Texture2D",
			"path": _vector_cache[node_id]
		})
		properties["texture"] = 'ExtResource("%d")' % res_id
		properties["expand_mode"] = 1  # IGNORE_SIZE
		# 细线型 Vector（只有 strokes 没有 fills，高度很小）使用 STRETCH，
		# 让纹理适应节点大小，避免被裁剪
		var node_height = node.get("height", 0)
		var is_thin_line = fills.is_empty() and not strokes.is_empty() and node_height < 2.0
		if is_thin_line:
			properties["stretch_mode"] = 0  # STRETCH
		else:
			properties["stretch_mode"] = 6  # KEEP_ASPECT_COVERED
		# VECTOR 类型：纹理已包含完整的渲染结果（fill + stroke），
		# 移除 fill/stroke 产生的 panel 样式，避免干扰纹理渲染
		properties.erase("theme_override_styles/panel")

	# 处理描边
	if not is_text and not strokes.is_empty() and stroke_weight > 0:
		for stroke in strokes:
			if stroke.get("type") == "SOLID":
				var stroke_color = _figma_color_to_godot(stroke.get("color", {}))
				var border_w = stroke_weight if stroke_weight >= 0.5 else 1
				# 存储描边数据供 shader 使用
				node["_stroke_data"] = {"color": stroke_color, "width": border_w}
				# VECTOR 类型已有纹理，不需要 panel 样式
				if node_type != "VECTOR" and not properties.has("theme_override_styles/panel"):
					properties["theme_override_styles/panel"] = _create_border_style_ex(stroke_color, border_w, int(tl), int(tr), int(bl), int(br))

	# 若有圆角但尚无 panel，先建透明背景 panel（供阴影合并 & 圆角渲染；TEXT 跳过）
	if not is_text and (tl > 0 or tr > 0 or bl > 0 or br > 0) and not properties.has("theme_override_styles/panel"):
		var style_id = _create_flat_style_ex("Color(0, 0, 0, 0)", tl, tr, bl, br)
		properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id

	# 处理阴影和发光
	var has_drop_shadow = false
	for effect in effects:
		match effect.get("type"):
			"DROP_SHADOW":
				var offset = effect.get("offset", {})
				var ox = offset.get("x", 0)
				var oy = offset.get("y", 0)
				var radius = effect.get("radius", 0)
				# offset=(0,0) + 较大 radius = 荧光效果（非投影）
				if ox == 0 and oy == 0 and radius >= 5:
					# 只有 VECTOR 类型节点才直接应用荧光
					# FRAME 节点的荧光由 _preprocess_parent_positions 传递给子矢量图
					if node_type == "VECTOR":
						var color = effect.get("color", {})
						node["_glow_data"] = {
							"color": "Color(%f, %f, %f, %f)" % [color.get("r",0), color.get("g",0), color.get("b",0), color.get("a",1)],
							"radius": radius,
							"intensity": clampf(color.get("a", 1.0) * 2.0, 0.0, 1.0),
						}
				else:
					# 普通投影：合并进节点 panel StyleBoxFlat（见 _apply_drop_shadow）
					_apply_drop_shadow(effect, properties)
					has_drop_shadow = true
					var _sc = effect.get("color", {})
					node["_shadow_data"] = {
						"color": _figma_color_to_godot(_sc),
						"size": effect.get("radius", 0),
						"offset": "Vector2(%f, %f)" % [ox, oy],
					}
			"INNER_SHADOW":
				var ic = effect.get("color", {})
				var io = effect.get("offset", {})
				node["_inner_shadow_data"] = {
					"color": _figma_color_to_godot(ic),
					"blur": effect.get("radius", 0),
					"offset": "Vector2(%f, %f)" % [io.get("x", 0), io.get("y", 0)],
				}

	# 有圆角的节点需要 clip_contents 才能显示圆角（TEXT 跳过）
	# 有发光时禁用裁剪，允许发光超出节点边界
	if not is_text and (tl > 0 or tr > 0 or bl > 0 or br > 0) and not node.has("_glow_data") and not has_drop_shadow:
		properties["clip_contents"] = true

func _create_flat_style(color: String, corner_radius: int) -> int:
	return _create_flat_style_ex(color, corner_radius, corner_radius, corner_radius, corner_radius)

func _create_flat_style_ex(color: String, tl: int, tr: int, bl: int, br: int) -> int:
	var res_id = _next_resource_id()
	_sub_resources.append({
		"id": res_id,
		"type": "StyleBoxFlat",
		"properties": {
			"bg_color": color,
			"corner_radius_top_left": tl,
			"corner_radius_top_right": tr,
			"corner_radius_bottom_left": bl,
			"corner_radius_bottom_right": br,
		}
	})
	return res_id

func _create_gradient_style(fill: Dictionary, corner_radius: int) -> int:
	return _create_gradient_style_ex(fill, corner_radius, corner_radius, corner_radius, corner_radius)

func _create_gradient_style_ex(fill: Dictionary, tl: int, tr: int, bl: int, br: int) -> int:
	var stops = fill.get("gradientStops", [])
	if stops.size() < 2:
		return 0

	# 选择最不透明的 stop 颜色（渐变可能从透明到不透明）
	var best_color = stops[0].get("color", {})
	var best_alpha = best_color.get("a", 0)
	for s in stops:
		var c = s.get("color", {})
		var a = c.get("a", 0)
		if a > best_alpha:
			best_alpha = a
			best_color = c

	var style_id = _next_resource_id()
	_sub_resources.append({
		"id": style_id,
		"type": "StyleBoxFlat",
		"properties": {
			"bg_color": _figma_color_to_godot(best_color),
			"corner_radius_top_left": tl,
			"corner_radius_top_right": tr,
			"corner_radius_bottom_left": bl,
			"corner_radius_bottom_right": br,
		}
	})
	return style_id

func _create_border_style(color: String, width, corner_radius) -> String:
	return _create_border_style_ex(color, width, corner_radius, corner_radius, corner_radius, corner_radius)

func _create_border_style_ex(color: String, width, tl: int, tr: int, bl: int, br: int) -> String:
	var w = max(1, int(ceil(width)))
	var res_id = _next_resource_id()
	_sub_resources.append({
		"id": res_id,
		"type": "StyleBoxFlat",
		"properties": {
			"bg_color": "Color(0, 0, 0, 0)",
			"border_width_left": w,
			"border_width_right": w,
			"border_width_top": w,
			"border_width_bottom": w,
			"border_color": color,
			"corner_radius_top_left": tl,
			"corner_radius_top_right": tr,
			"corner_radius_bottom_left": bl,
			"corner_radius_bottom_right": br,
		}
	})
	return 'SubResource("%d")' % res_id

func _apply_drop_shadow(effect: Dictionary, properties: Dictionary) -> void:
	# 将投影合并到节点当前的 panel StyleBoxFlat。
	# StyleBoxFlat 的 shadow 是背景阴影，写到节点正在用的 bg style 上即可生效。
	# 旧实现单独创建了一个 StyleBoxFlat 但没赋给节点，导致阴影完全不显示。
	# 若节点没有 panel 样式（纯 TextureRect/Label），则无法应用，跳过。
	if not properties.has("theme_override_styles/panel"):
		return
	var style_id := _extract_sub_resource_id(str(properties["theme_override_styles/panel"]))
	if style_id < 0:
		return
	for res in _sub_resources:
		if int(res["id"]) == style_id:
			var offset = effect.get("offset", {})
			res["properties"]["shadow_color"] = _figma_color_to_godot(effect.get("color", {}))
			res["properties"]["shadow_size"] = effect.get("radius", 0)
			res["properties"]["shadow_offset"] = "Vector2(%f, %f)" % [offset.get("x", 0), offset.get("y", 0)]
			return

func _extract_sub_resource_id(s: String) -> int:
	# 从 'SubResource("5")' 形式的字符串中解析出资源 id
	var regex = RegEx.new()
	regex.compile('SubResource\\("(-?\\d+)"\\)')
	var m = regex.search(s)
	if m:
		return int(m.get_string(1))
	return -1

func _apply_text_properties(node: Dictionary, properties: Dictionary) -> void:
	var characters = node.get("characters", "")
	if characters.is_empty():
		return
	# 跳过 SF Symbol 等不可渲染的特殊字符（Unicode U+10000 以上）
	if characters.unicode_at(0) >= 0x10000:
		return

	characters = characters.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
	properties["text"] = '"%s"' % characters

	var style = node.get("style", {})
	var font_size = style.get("fontSize", 16)
	properties["theme_override_font_sizes/font_size"] = font_size

	# 字体
	var font_family = style.get("fontFamily", "")
	var font_weight = style.get("fontWeight", "")
	if font_family and font_weight:
		var font_key = "%s_%s" % [font_family, font_weight]
		if _font_cache.has(font_key):
			var font_path = _font_cache[font_key]
			var res_id = _next_resource_id()
			_ext_resources.append({
				"id": res_id,
				"type": "FontFile",
				"path": font_path
			})
			properties["theme_override_fonts/font"] = 'ExtResource("%d")' % res_id

	# 文本颜色（fills 中第一个 SOLID 填充）
	for fill in node.get("fills", []):
		if fill.get("type") == "SOLID":
			var color = _figma_color_to_godot(fill.get("color", {}))
			properties["theme_override_colors/font_color"] = color
			break

	# 行高
	# Figma: lineHeight = {unit:"AUTO"|"PIXELS"|"PERCENT", value:N}
	# Godot: line_spacing = 在默认行高基础上的增量（像素）
	var line_height = style.get("lineHeight", {})
	match line_height.get("unit", ""):
		"PIXELS":
			# 固定行高：line_spacing = 目标行高 - fontSize（近似默认行高）
			var target_lh = line_height.get("value", 0)
			if target_lh > 0:
				properties["theme_override_constants/line_spacing"] = int(target_lh - font_size)
		"PERCENT":
			# 百分比行高：目标 = fontSize * percent/100
			var pct = line_height.get("value", 100)
			var target_lh = font_size * pct / 100.0
			properties["theme_override_constants/line_spacing"] = int(target_lh - font_size)
		# AUTO: 使用字体默认行高，不设 line_spacing

	# 字间距
	var letter_spacing = style.get("letterSpacing", {})
	if letter_spacing.get("unit", "") == "PIXELS":
		var spacing = int(letter_spacing.get("value", 0))
		if spacing != 0:
			properties["theme_override_constants/character_spacing"] = spacing

	# 文本装饰
	match node.get("textDecoration", "NONE"):
		"UNDERLINE":
			properties["underline"] = true
		"STRIKETHROUGH":
			properties["strikethrough"] = true

	# 文本大小写
	match node.get("textCase", "ORIGINAL"):
		"UPPER":
			properties["uppercase"] = true
		# LOWER/TITLE: Godot Label 无直接支持

	# 水平对齐
	match style.get("textAlignHorizontal"):
		"LEFT":
			properties["horizontal_alignment"] = 0
		"CENTER":
			properties["horizontal_alignment"] = 1
		"RIGHT":
			properties["horizontal_alignment"] = 2
		"JUSTIFIED":
			properties["horizontal_alignment"] = 3

	# 垂直对齐
	match style.get("textAlignVertical"):
		"TOP":
			properties["vertical_alignment"] = 0
		"CENTER":
			properties["vertical_alignment"] = 1
		"BOTTOM":
			properties["vertical_alignment"] = 2

	# ── 对齐修正：让文字视觉中心与 Figma 一致 ──
	#
	# Figma 的 width/height 是文字紧凑边界框，Godot Label 的渲染尺寸由字体度量决定。
	# 同一 fontSize 在两个系统中渲染尺寸不同，需要调整 offset 让文字中心对齐。
	#
	# 修正公式（所有对齐方式推导结果一致）：
	#   label_pos = figma_pos + (figma_size - godot_render_size) / 2
	var _ol = properties.get("offset_left", 0)
	var _ot = properties.get("offset_top", 0)
	var _fw = node.get("width", 0)
	var _fh = node.get("height", 0)

	# 渲染尺寸：用字体 ascent+descent 计算 Label 高度
	# Godot Label 的高度 = ascent + descent + line_gap（不是文字紧密边界）
	var _text = node.get("characters", "")
	var _godot_rw = _fw  # 宽度直接用 Figma 值
	var _godot_rh = font_size * 1.36  # 默认估算

	# 尝试加载字体获取精确 ascent+descent
	var _font_key = "%s_%s" % [font_family, font_weight]
	if _font_cache.has(_font_key):
		var _font_res_path = _font_cache[_font_key]
		var _abs_path = ProjectSettings.globalize_path(_font_res_path)
		if FileAccess.file_exists(_abs_path):
			var _f = FileAccess.open(_abs_path, FileAccess.READ)
			if _f:
				var _data = _f.get_buffer(_f.get_length())
				_f.close()
				var _font = FontFile.new()
				_font.data = _data
				var _ascent = _font.get_ascent(font_size)
				var _descent = _font.get_descent(font_size)
				if _ascent > 0 and _descent > 0:
					_godot_rh = _ascent + _descent

	var ol = _ol + (_fw - _godot_rw) / 2.0
	var ot = _ot + (_fh - _godot_rh) / 2.0
	properties["offset_left"] = ol
	properties["offset_top"] = ot
	properties["offset_right"] = ol + _fw
	properties["offset_bottom"] = ot + _fh

	# ── textAutoResize 控制尺寸行为 ──
	match node.get("textAutoResize", "NONE"):
		"TRUNCATE":
			properties["clip_text"] = true
			properties["text_overrun"] = 3  # ELLipsis
		# WIDTH_AND_HEIGHT / HEIGHT / NONE: offset 已修正，保持不变

func _figma_color_to_godot(color: Dictionary) -> String:
	var r = color.get("r", 0.0)
	var g = color.get("g", 0.0)
	var b = color.get("b", 0.0)
	var a = color.get("a", 1.0)
	return "Color(%f, %f, %f, %f)" % [r, g, b, a]

func _next_resource_id() -> int:
	_resource_id_counter += 1
	return _resource_id_counter

func _get_unique_name(name: String, parent_path: String) -> String:
	var key = "%s/%s" % [parent_path, name]
	if not _name_counter.has(key):
		_name_counter[key] = 0
		return name
	_name_counter[key] += 1
	return "%s_%d" % [name, _name_counter[key]]

func _sanitize_name(name: String) -> String:
	# Godot 节点名不允许 / . : [ ] 及空白；保留中文等 Unicode 字符（原实现会把中文全替成 _）
	var regex = RegEx.new()
	regex.compile("[/.\\[\\]\\s:]")
	var result = regex.sub(name, "_", true)
	return result if result.length() > 0 else "Node"

func _format_sub_resource(res: Dictionary) -> String:
	var content = '[sub_resource type="%s" id="%d"]\n' % [res["type"], res["id"]]
	for key in res["properties"]:
		content += "%s = %s\n" % [key, str(res["properties"][key])]
	content += "\n"
	return content

func _is_solid_black_fill(node: Dictionary) -> bool:
	# 检查节点是否只有纯黑色 SOLID 填充
	var fills = node.get("fills", [])
	if fills.size() != 1:
		return false
	var fill = fills[0]
	if fill.get("type") != "SOLID":
		return false
	var color = fill.get("color", {})
	var r = color.get("r", 0)
	var g = color.get("g", 0)
	var b = color.get("b", 0)
	var a = color.get("a", 1)
	# 检查是否为纯黑色（r=0, g=0, b=0, a=1）
	return r == 0 and g == 0 and b == 0 and a == 1

func _find_last_vector(nodes: Array) -> Dictionary:
	# 递归查找最后一个 VECTOR 类型的节点（ring 总是排在 SVG 组最后）
	var result = {}
	for node in nodes:
		if node.get("type", "") == "VECTOR":
			result = node
		var children = node.get("children", [])
		if children.size() > 0:
			var found = _find_last_vector(children)
			if not found.is_empty():
				result = found
	return result
