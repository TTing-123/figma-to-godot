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

	# 提取矢量资源（高分辨率 PNG）
	var vectors = data.get("vectors", {})
	for node_id in vectors:
		# 跳过TEXT类型的节点，保持为Label而不是图片
		if node_id in text_node_ids:
			continue

		var base64_data = vectors[node_id]
		var safe_name = _sanitize_filename(node_id)
		var png_path = vectors_dir + "%s.png" % safe_name
		_save_base64_image(base64_data, png_path)
		_vector_cache[node_id] = png_path
		# 加载 PNG 获取实际像素尺寸（figma 的 width/height 可能为 0，例如线条矢量）
		var img = Image.load_from_file(png_path)
		if img:
			_vector_size_cache[node_id] = Vector2(img.get_width(), img.get_height())

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

func _save_base64_svg(base64_data: String, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var bytes = Marshalls.base64_to_raw(base64_data)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(bytes)
		file.close()

func _create_svg_import_file(svg_path: String) -> void:
	# 生成 .import 文件，设置 svg/scale=3.0 保证光栅化分辨率与之前 3x PNG 一致
	var import_path = svg_path + ".import"
	var content = """[remap]

importer="texture"
type="CompressedTexture2D"

[deps]

source_file="res://%s"
dest_files=[]

[params]

compress/mode=0
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=0
compress/channel_pack=0
mipmaps/generate=false
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=1
svg/scale=3.0
editor/scale_with_editor_scale=false
editor/convert_colors_with_editor_theme=false
""" % svg_path.replace("\\", "/")
	var file = FileAccess.open(import_path, FileAccess.WRITE)
	if file:
		file.store_string(content)
		file.close()

func _parse_svg_size(svg_path: String) -> Vector2:
	var file = FileAccess.open(svg_path, FileAccess.READ)
	if not file:
		return Vector2.ZERO
	var content = file.get_as_text()
	file.close()
	# 提取 <svg> 标签中的 width 和 height 属性（Figma 导出的 SVG 会包含这些）
	var regex = RegEx.new()
	regex.compile("<svg[^>]*width=\"([\\d.]+)\"[^>]*height=\"([\\d.]+)\"")
	var result = regex.search(content)
	if result:
		return Vector2(float(result.get_string(1)), float(result.get_string(2)))
	# 备选：从 viewBox 解析
	regex.compile("viewBox=\"[^\\s]+\\s+[^\\s]+\\s+([\\d.]+)\\s+([\\d.]+)\"")
	result = regex.search(content)
	if result:
		return Vector2(float(result.get_string(1)), float(result.get_string(2)))
	return Vector2.ZERO

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
	var content = "[gd_scene load_steps=%d format=3]\n\n" % (_resource_id_counter + 1)

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

	# 存储父节点的裁剪信息和尺寸
	var parent_clips = parent_pos.get("clips_content", false)
	var parent_corner = parent_pos.get("corner_radius", 0)
	node["_parent_clips_content"] = parent_clips
	node["_parent_corner_radius"] = parent_corner if parent_clips else 0
	node["_parent_size"] = parent_pos.get("size", Vector2.ZERO)
	# 记录节点在父节点中的偏移（用于 shader 中父节点圆角裁剪）
	node["_offset_in_parent"] = Vector2(abs_x - parent_pos.get("abs_x", abs_x), abs_y - parent_pos.get("abs_y", abs_y))

	# 处理 auto-layout 负间距：重新计算子节点位置，避免重叠
	# Figma 导出的 x/y 已包含 itemSpacing 效果，负间距会导致子节点重叠
	var children = node.get("children", [])
	var layout_mode = node.get("layoutMode", "NONE")
	var item_spacing = node.get("itemSpacing", 0)
	if (layout_mode == "VERTICAL" or layout_mode == "HORIZONTAL") and item_spacing < 0 and children.size() > 1:
		var effective_spacing = max(0, item_spacing)
		if layout_mode == "VERTICAL":
			var py = node.get("paddingTop", 0)
			for child in children:
				child["y"] = py
				py += child.get("height", 0) + effective_spacing
			# 更新父容器高度以适应不再重叠的子节点
			var new_h = py + node.get("paddingBottom", 0)
			if new_h > node.get("height", 0):
				node["height"] = new_h
				node["absoluteY_end"] = node.get("absoluteY", 0) + new_h
		else:
			var px = node.get("paddingLeft", 0)
			for child in children:
				child["x"] = px
				px += child.get("width", 0) + effective_spacing
			# 更新父容器宽度以适应不再重叠的子节点
			var new_w = px + node.get("paddingRight", 0)
			if new_w > node.get("width", 0):
				node["width"] = new_w

	# SVG 居中修正：无 auto-layout 且子节点全为 VECTOR 的 FRAME，居中子节点
	# Figma Plugin API 对这类容器的子节点坐标有偏差，实际设计中是居中的
	if layout_mode == "NONE" and children.size() > 0:
		var all_vectors = true
		for child in children:
			if child.get("type", "") != "VECTOR":
				all_vectors = false
				break
		if all_vectors:
			var fw = node.get("width", 0)
			var fh = node.get("height", 0)
			if fw > 0 and fh > 0:
				for child in children:
					var cw = child.get("width", 0)
					var ch = child.get("height", 0)
					var new_x = (fw - cw) / 2.0
					var new_y = (fh - ch) / 2.0
					# 同步更新 absoluteX/absoluteY 保持一致
					var parent_abs_x = node.get("absoluteX", 0)
					var parent_abs_y = node.get("absoluteY", 0)
					child["x"] = new_x
					child["y"] = new_y
					child["absoluteX"] = parent_abs_x + new_x
					child["absoluteY"] = parent_abs_y + new_y

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
		"visible": node.get("visible", true)
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

	# 直接使用 Figma 的 x/y（相对于父节点的偏移）
	# 不使用 absoluteX/Y 计算，因为 Figma Plugin API 对 GROUP 节点的 absoluteTransform 有 bug
	var x = node.get("x", 0)
	var y = node.get("y", 0)
	var width = node.get("width", 0)
	var height = node.get("height", 0)

	# VECTOR 类型修正：figma 的 width/height 是矢量路径包围盒，
	# 可能为 0（如水平/垂直线条），但导出的 PNG 含描边厚度有实际像素尺寸。
	# 只有当 figma 的 width 或 height 为 0 时，才用 PNG 尺寸按比例计算。
	if node_type == "VECTOR" and _vector_size_cache.has(node_id):
		var png_size: Vector2 = _vector_size_cache[node_id]
		if png_size.x > 0 and png_size.y > 0:
			# 只有当 width 或 height 为 0 时才修正
			if width == 0 and height == 0:
				# 两者都为 0，使用 PNG 尺寸
				width = png_size.x
				height = png_size.y
			elif width == 0:
				# width 为 0，按 PNG 比例计算
				width = height * png_size.x / png_size.y
			elif height == 0:
				# height 为 0，按 PNG 比例计算
				height = width * png_size.y / png_size.x
			# 如果 width 和 height 都大于 0，直接使用 figma 的尺寸，不做修正

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
		# 子节点使用相对父节点的坐标
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

	# 处理裁剪（根节点不裁剪，允许子节点超出边界）
	if depth > 0 and node.get("clipsContent", false):
		properties["clip_contents"] = true

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
		if shader_radius > 0 and parent_clips:
			# 使用父节点大小作为目标大小（裁剪区域）
			var root_width = node.get("_root_width", width)
			var root_height = node.get("_root_height", height)
			var shader_id = _next_resource_id()
			_sub_resources.append({
				"id": shader_id,
				"type": "ShaderMaterial",
				"properties": {
					"shader": 'ExtResource("shader_rounded")',
					"shader_parameter/corner_radius": shader_radius,
					"shader_parameter/target_size": "Vector2(%f, %f)" % [root_width, root_height],
					"shader_parameter/parent_corner_radius": 0.0,
					"shader_parameter/parent_size": "Vector2(%f, %f)" % [root_width, root_height],
					"shader_parameter/offset_in_parent": "Vector2(0.0, 0.0)",
					"shader_parameter/use_texture": true,
				}
			})
			properties["material"] = 'SubResource("%d")' % shader_id
			# 将节点大小设置为目标大小，shader会处理纹理裁剪
			properties["offset_left"] = 0
			properties["offset_top"] = 0
			properties["offset_right"] = root_width
			properties["offset_bottom"] = root_height
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
					"shader_parameter/corner_radiuses": "Vector4(%f, %f, %f, %f)" % [float(bl), float(tr), float(br), float(tl)],
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

func _apply_auto_layout(node: Dictionary, properties: Dictionary) -> void:
	var layout_mode = node.get("layoutMode", "NONE")
	var primary_axis = node.get("primaryAxisAlignItems", "MIN")
	var item_spacing = node.get("itemSpacing", 0)
	var padding_left = node.get("paddingLeft", 0)
	var padding_right = node.get("paddingRight", 0)
	var padding_top = node.get("paddingTop", 0)
	var padding_bottom = node.get("paddingBottom", 0)

	if layout_mode == "HORIZONTAL":
		properties["_container_type"] = "HBoxContainer"
		match primary_axis:
			"MIN":
				properties["alignment"] = 0
			"CENTER":
				properties["alignment"] = 1
			"MAX":
				properties["alignment"] = 2
	elif layout_mode == "VERTICAL":
		properties["_container_type"] = "VBoxContainer"
		match primary_axis:
			"MIN":
				properties["alignment"] = 0
			"CENTER":
				properties["alignment"] = 1
			"MAX":
				properties["alignment"] = 2

	if item_spacing > 0:
		properties["theme_override_constants/separation"] = item_spacing

	if padding_left > 0 or padding_right > 0 or padding_top > 0 or padding_bottom > 0:
		var style_id = _next_resource_id()
		_sub_resources.append({
			"id": style_id,
			"type": "StyleBoxEmpty",
			"properties": {
				"content_margin_left": padding_left,
				"content_margin_right": padding_right,
				"content_margin_top": padding_top,
				"content_margin_bottom": padding_bottom,
			}
		})
		properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id

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

				"GRADIENT_LINEAR", "GRADIENT_RADIAL":
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
						node["_gradient_data"] = {
							"color1": "Color(%f, %f, %f, %f)" % [c1.get("r",0), c1.get("g",0), c1.get("b",0), c1.get("a",1)],
							"color2": "Color(%f, %f, %f, %f)" % [c2.get("r",0), c2.get("g",0), c2.get("b",0), c2.get("a",1)],
							"start": "Vector2(%f, %f)" % [sx, sy],
							"end": "Vector2(%f, %f)" % [ex, ey],
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

	# 处理阴影和发光
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
					_apply_shadow(effect, properties)
			"INNER_SHADOW":
				_apply_shadow(effect, properties)

	# 如果有圆角但还没有样式，创建透明背景样式（TEXT 跳过：Label 圆角无意义）
	if not is_text and (tl > 0 or tr > 0 or bl > 0 or br > 0) and not properties.has("theme_override_styles/panel"):
		var style_id = _create_flat_style_ex("Color(0, 0, 0, 0)", tl, tr, bl, br)
		properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id

	# 有圆角的节点需要 clip_contents 才能显示圆角（TEXT 跳过）
	# 有发光时禁用裁剪，允许发光超出节点边界
	if not is_text and (tl > 0 or tr > 0 or bl > 0 or br > 0) and not node.has("_glow_data"):
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

func _apply_shadow(effect: Dictionary, properties: Dictionary) -> void:
	var offset = effect.get("offset", {})
	var color = _figma_color_to_godot(effect.get("color", {}))
	var radius = effect.get("radius", 0)

	var shadow_id = _next_resource_id()
	_sub_resources.append({
		"id": shadow_id,
		"type": "StyleBoxFlat",
		"properties": {
			"bg_color": "Color(0, 0, 0, 0)",
			"shadow_color": color,
			"shadow_size": radius,
			"shadow_offset": "Vector2(%f, %f)" % [offset.get("x", 0), offset.get("y", 0)],
		}
	})

func _apply_text_properties(node: Dictionary, properties: Dictionary) -> void:
	var characters = node.get("characters", "")
	if characters.is_empty():
		return
	# 跳过 SF Symbol 等不可渲染的特殊字符（Unicode U+10000 以上）
	if characters.unicode_at(0) >= 0x10000:
		return

	characters = characters.replace('"', '\\"').replace("\n", "\\n")
	properties["text"] = '"%s"' % characters

	var style = node.get("style", {})
	var font_size = style.get("fontSize", 16)
	properties["theme_override_font_sizes/font_size"] = font_size

	# 文本颜色
	for fill in node.get("fills", []):
		if fill.get("type") == "SOLID":
			var color = _figma_color_to_godot(fill.get("color", {}))
			properties["theme_override_colors/font_color"] = color
			break

	# 文本对齐
	match style.get("textAlignHorizontal"):
		"LEFT":
			properties["horizontal_alignment"] = 0
		"CENTER":
			properties["horizontal_alignment"] = 1
		"RIGHT":
			properties["horizontal_alignment"] = 2
		"JUSTIFIED":
			properties["horizontal_alignment"] = 3

	match style.get("textAlignVertical"):
		"TOP":
			properties["vertical_alignment"] = 0
		"CENTER":
			properties["vertical_alignment"] = 1
		"BOTTOM":
			properties["vertical_alignment"] = 2

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
	var regex = RegEx.new()
	regex.compile("[^a-zA-Z0-9_]")
	var result = regex.sub(name, "_", true)
	if result.length() > 0 and result[0] >= "0" and result[0] <= "9":
		result = "_" + result
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
