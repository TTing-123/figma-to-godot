class_name FigmaLocalImporter
extends RefCounted

signal progress_changed(message: String, percent: float)

# 节点类型映射 - 全部用 Control，避免容器布局问题
const TYPE_MAP = {
	"FRAME": "Control",
	"GROUP": "Control",
	"VECTOR": "TextureRect",
	"BOOLEAN_OPERATION": "TextureRect",
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

# tscn 输出缓冲区/id 分配/序列化由 _writer 持有（add_* 内部原子分配 id + append，调用顺序即 id 顺序）
var _writer := FigmaTscnWriter.new()
# 资源提取（图片/矢量/位图填充），4 cache 由 _assets 持有
var _assets := FigmaAssetExtractor.new()
# 字体（本地匹配 + Google 下载），_font_cache 由 _fonts 持有
var _fonts := FigmaFontLoader.new()

func import_from_file(json_path: String, output_path: String) -> Error:
	# 读取 JSON 文件
	progress_changed.emit("读取文件...", 0.1)
	await RenderingServer.frame_post_draw
	var file = FileAccess.open(json_path, FileAccess.READ)
	if not file:
		push_error("无法打开文件: %s" % json_path)
		return ERR_FILE_NOT_FOUND

	var json_text = file.get_as_text()
	file.close()

	# 解析 JSON
	progress_changed.emit("解析 JSON...", 0.2)
	await RenderingServer.frame_post_draw
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
	await RenderingServer.frame_post_draw
	var scene_name = output_path.get_file().get_basename()
	# 去掉末尾的数字后缀，统一用 figma_export_assets
	var base_name = scene_name.rstrip("0123456789")
	var assets_dir = "res://%s_assets/" % base_name
	# 如果场景名有数字后缀，加到 assets 后面
	var suffix = scene_name.substr(base_name.length())
	if suffix.length() > 0:
		assets_dir = "res://%s_assets%s/" % [base_name, suffix]
	_assets.extract(data, assets_dir)

	# 查找字体资源
	progress_changed.emit("查找字体...", 0.5)
	await RenderingServer.frame_post_draw
	var fonts = data.get("fonts", {})
	if not fonts.is_empty():
		_fonts.find_fonts(fonts, assets_dir)
	
	# 生成场景
	progress_changed.emit("生成场景...", 0.6)
	await RenderingServer.frame_post_draw
	var nodes = data.get("nodes", [])
	if nodes.is_empty():
		push_error("没有找到节点数据")
		return ERR_INVALID_DATA

	# 使用第一个选中的节点作为根节点
	var root_node = nodes[0]
	var scene_content = _generate_scene(root_node, data.get("maskRenderBounds", {}))

	# 保存文件
	progress_changed.emit("保存文件...", 0.9)
	await RenderingServer.frame_post_draw
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
	await RenderingServer.frame_post_draw
	return OK

func _generate_scene(root_node: Dictionary, mask_rb_map: Dictionary = {}) -> String:
	_writer.reset()

	# 计算所有节点的边界框
	var bounds = FigmaImporterUtils._calculate_bounds(root_node)
	var offset_x = bounds.min_x
	var offset_y = bounds.min_y

	# 获取��节点大小
	var root_width = root_node.get("width", 0)
	var root_height = root_node.get("height", 0)

	# 挂载 mask renderBounds 到 mask 节点，再重组 mask 蒙版（mask 吸收后续兄弟 + clipsContent）
	FigmaImporterUtils._attach_mask_render_bounds(root_node, mask_rb_map)
	FigmaImporterUtils._apply_mask_groups(root_node)
	# 预处理：计算每个节点的父节点绝对坐标
	FigmaImporterUtils._preprocess_parent_positions(root_node, {}, offset_x, offset_y, 0, root_width, root_height)

	# 处理根节点
	_process_node(root_node, "", 0)

	# 序列化为 .tscn（header + ext/sub_resource + 节点）
	return _writer.serialize()

func _process_node(node: Dictionary, parent_path: String, depth: int) -> void:
	var node_type = node.get("type", "")
	var raw_name = FigmaImporterUtils._sanitize_name(node.get("name", "Unnamed"))
	var node_name = _writer.unique_name(raw_name, parent_path)
	var node_id = node.get("id", "")
	var corner_radius = node.get("cornerRadius", 0)
	var tl = int(node.get("topLeftRadius", corner_radius))
	var tr = int(node.get("topRightRadius", corner_radius))
	var bl = int(node.get("bottomLeftRadius", corner_radius))
	var br = int(node.get("bottomRightRadius", corner_radius))

	# 获取 Godot 类型
	var godot_type = TYPE_MAP.get(node_type, "Control")
	# mask 蒙版：透明裁剪容器（Figma 中 mask 仅贡献裁剪形状，自身 fill 不渲染）
	if node.get("_is_mask_clip", false):
		godot_type = "Control"

	# 使用预处理阶段计算的相对偏移（基于 absoluteX/Y 差值）
	# Figma Plugin API 对 GROUP 子节点的 x/y 返回绝对坐标（非相对偏移），
	# 直接用 x/y 会导致 GROUP 子节点位置错误。_rel_x/y 已统一修正。
	var x = node.get("_rel_x", node.get("x", 0))
	var y = node.get("_rel_y", node.get("y", 0))
	var width = node.get("width", 0)
	var height = node.get("height", 0)

	# VECTOR 尺寸：SVG 栅格化的 PNG 已烘焙旋转，其像素尺寸（÷3）即节点视觉包围。
	# 用它作 Godot size；位置由下方几何中心公式对齐（不再用原始几何尺寸）。
	# 含 ELLIPSE/STAR/LINE/REGULAR_POLYGON：带阴影/GROUP坐标系时 SVG viewBox 留白不对称，
	# 内容(球体)会偏离节点几何中心，必须统一走下方的"内容中心对齐"。
	var _is_svg_vector = node_type in ["VECTOR", "BOOLEAN_OPERATION", "ELLIPSE", "STAR", "LINE", "REGULAR_POLYGON"]
	if _is_svg_vector and _assets.vector_size_cache().has(node_id):
		var png_size: Vector2 = _assets.vector_size_cache()[node_id]
		if png_size.x > 0 and png_size.y > 0:
			var content_w = png_size.x / 3.0
			var content_h = png_size.y / 3.0
			if width == 0 and height == 0:
				width = content_w
				height = content_h
			elif width == 0:
				width = height * content_w / content_h
			elif height == 0:
				height = width * content_h / content_w
			else:
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
			var style_id = _writer.add_sub_resource("StyleBoxFlat", {
				"bg_color": "Color(0, 0, 0, 0.01)",
				"corner_radius_top_left": int(root_corner),
				"corner_radius_top_right": int(root_corner),
				"corner_radius_bottom_right": int(root_corner),
				"corner_radius_bottom_left": int(root_corner),
			})
			properties["theme_override_styles/panel"] = 'SubResource("%d")' % style_id
			properties["clip_contents"] = true
	else:
		# 子节点：相对父节点的坐标
		if _is_svg_vector and _assets.vector_size_cache().has(node_id):
			# PNG(SVG 栅格化/烘焙)已烘焙旋转+翻转，Godot 不再设 rotation。
			# 本体几何中心用导出端 absoluteBoundingBox.center(全局真实路径 bbox，含定义框内偏移)：
			#   _cx = x + (absCx - node.absoluteX)，x=_rel 已含父 GROUP bbox 补偿。
			# 数学：本地路径中心经 relativeTransform M 到父本地 = x + M·M⁻¹·(absC - absOrigin) = x+(absC-absOrigin)，
			# M 抵消，对反射(det<0)同样成立。旧方案用 node/content 尺寸推算均错：反射 VECTOR node 尺寸是
			# "定义框"≠路径 bbox，且路径在定义框内偏移每节点不同(2:704 路径10×9 在定义框10×15 内 y 偏移决定 _cy)。
			var _cx: float = x + width / 2.0
			var _cy: float = y + height / 2.0
			if _assets.vector_body_abs_center_cache().has(node_id):
				var _bac = _assets.vector_body_abs_center_cache()[node_id]
				_cx = x + (_bac.x - node.get("absoluteX", x))
				_cy = y + (_bac.y - node.get("absoluteY", y))
			elif node.has("relativeTransform") and node["relativeTransform"] != null:
				# 回退(无本体中心数据)：relativeTransform + content 尺寸(路径居中定义框假设，近似)
				var _m = node["relativeTransform"]
				var _r0 = _m[0]
				var _r1 = _m[1]
				_cx = x + float(_r0[0]) * (width / 2.0) + float(_r0[1]) * (height / 2.0)
				_cy = y + float(_r1[0]) * (width / 2.0) + float(_r1[1]) * (height / 2.0)
			# PNG 内容中心(像素÷3)对齐 C，而非 PNG 画布中心，修正 viewBox 留白不对称的内容偏移
			var _ccx = width / 2.0
			var _ccy = height / 2.0
			if _assets.vector_content_center_cache().has(node_id):
				var _cc = _assets.vector_content_center_cache()[node_id]
				_ccx = _cc.x / 3.0
				_ccy = _cc.y / 3.0
			properties["offset_left"] = _cx - _ccx
			properties["offset_top"] = _cy - _ccy
			properties["offset_right"] = properties["offset_left"] + width
			properties["offset_bottom"] = properties["offset_top"] + height
		else:
			# 其他节点：Godot 设 rotation，令旋转中心 = 几何中心。
			#   offset_left = x + (w/2)(cosθ-1) + (h/2)sinθ   (Figma y-down M=[[cos,sin],[-sin,cos]])
			#   offset_top  = y - (w/2)sinθ + (h/2)(cosθ-1)
			var _erot = node.get("rotation", 0.0)
			# 反射(rotation=0 但 det<0，如垂直镜像 GROUP)也走中心算法：反射轴上 origin≠bbox 左上，
			# 而 _rel=absoluteX/Y 差=origin 差，直接用会让容器偏一个 size(Group_3_1 垂直反射 m11=-1，offset_top 偏下 height=25)。
			# GROUP 不设 scale(避免双重翻转)，但 offset 必须经 M·(hw,hh) 由 origin 修正到 bbox 左上。
			var _reflected = false
			if node_type == "GROUP" and node.has("relativeTransform") and node["relativeTransform"] != null:
				var _m = node["relativeTransform"]
				if float(_m[0][0]) * float(_m[1][1]) - float(_m[0][1]) * float(_m[1][0]) < 0:
					_reflected = true
			if _erot != 0.0 or _reflected:
				var _hw = width / 2.0
				var _hh = height / 2.0
				var _cx: float
				var _cy: float
				if node.has("relativeTransform") and node["relativeTransform"] != null:
					# 几何中心相对父 = 左上相对父(x,y=_rel) + M·(hw,hh)。M 取自 relativeTransform
					# 线性部分(含旋转+反射)；_rel=子origin-父absX 已含父 GROUP 包围盒补偿，故直接用 x,y。
					# 标量 cos/sin 假设纯旋转，对反射(det<0) b 符号反 → 必须用矩阵 M。
					var _m = node["relativeTransform"]
					var _r0 = _m[0]
					var _r1 = _m[1]
					_cx = x + float(_r0[0]) * _hw + float(_r0[1]) * _hh
					_cy = y + float(_r1[0]) * _hw + float(_r1[1]) * _hh
				else:
					var _th = deg_to_rad(_erot)
					_cx = x + _hw * cos(_th) + _hh * sin(_th)
					_cy = y - _hw * sin(_th) + _hh * cos(_th)
				properties["offset_left"] = _cx - _hw
				properties["offset_top"] = _cy - _hh
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

	# 处理纯黑色 VECTOR 节��：设为隐藏（Figma 中不可见，导出后不应显示）
	if (node_type == "VECTOR" or node_type == "BOOLEAN_OPERATION") and FigmaImporterUtils._is_solid_black_fill(node):
		properties["visible"] = false

	# 处理透明度
	var opacity = node.get("opacity", 1.0)
	if opacity < 1.0:
		properties["modulate"] = "Color(1, 1, 1, %f)" % opacity

	# 处理裁剪：clipsContent=true 时裁剪超出自身边界的子节点（根节点也裁剪，匹配 Figma 根 Frame）
	if node.get("clipsContent", false):
		properties["clip_contents"] = true

	# 处理旋转：Figma rotation 正=逆时针(视觉)，Godot rotation 正=顺时针，故取负。
	# VECTOR/BOOLEAN_OPERATION 的 PNG 已烘焙旋转，不在此设 Godot rotation。
	var rot = node.get("rotation", 0.0)
	# 反射 GROUP(det<0) 不设 Godot rotation：Figma GROUP 不引入坐标层，子的 relativeTransform 已
	# 相对最近非 GROUP 祖先(含正确全局反射)；在 GROUP 上设 rotation=π 会把子节点错误 y 翻转。
	var _skip_group_rot = false
	if rot != 0.0 and node_type == "GROUP" and node.has("relativeTransform") and node["relativeTransform"] != null:
		var _rt_g = node["relativeTransform"]
		if float(_rt_g[0][0]) * float(_rt_g[1][1]) - float(_rt_g[0][1]) * float(_rt_g[1][0]) < 0:
			_skip_group_rot = true
	if rot != 0.0 and not _skip_group_rot and node_type != "VECTOR" and node_type != "BOOLEAN_OPERATION":
		properties["pivot_offset"] = "Vector2(%f, %f)" % [width / 2.0, height / 2.0]
		# 检测反射(det<0)：Figma "旋转"可含翻转，M=[[-cosφ,sinφ],[sinφ,cosφ]] det=-1。
		# Godot 用 scale.x=-1 表翻转，rotation 仅存纯旋转角(-atan2(c,d))；det>0 直接 -deg_to_rad。
		# 仅非 GROUP 叶子：GROUP 是逻辑容器，反射由子节点各自体现；在 GROUP 上设 scale 会与
		# 子节点双重翻转。GROUP 保持 rotation=-deg_to_rad(原行为，不在此处理反射)。
		if node_type != "GROUP" and node.has("relativeTransform") and node["relativeTransform"] != null:
			var _rt = node["relativeTransform"]
			var _det = float(_rt[0][0]) * float(_rt[1][1]) - float(_rt[0][1]) * float(_rt[1][0])
			if _det < 0:
				properties["scale"] = "Vector2(-1, 1)"
				properties["rotation"] = -atan2(float(_rt[1][0]), float(_rt[1][1]))
			else:
				properties["rotation"] = -deg_to_rad(rot)
		else:
			if rot == 0.0:
				properties["rotation"] = 0.0
			# 反射 GROUP(_skip_group_rot) 与 VECTOR/BOOLEAN_OPERATION 不设 Godot rotation：
			# 前者子的 relativeTransform 已含全局反射，设 rotation=π 会绕 pivot(默认 0,0)翻转，
			# 把子节点错误甩到上方/左侧(如 Group 5 rot=-180 -> 其下 Subtract 偏上)；
			# 后者 SVG 路径 / PNG 纹理已烘焙反射，再设会二次旋转。

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
		if (not node.get("_bitmap_corner_baked", false) and shader_radius > 0 and (parent_clips or (effective_radius > 0 and not node.get("_effects_baked_in_texture", false)))) or (node.has("_shadow_data") and not node.get("_effects_baked_in_texture", false)) or (node.has("_inner_shadow_data") and not node.get("_effects_baked_in_texture", false)):
			# 使用父节点大小作为目标大小（裁剪区域）


			var shader_id = _writer.add_sub_resource("ShaderMaterial", {
				"shader": 'ExtResource("shader_rounded")',
				"shader_parameter/corner_radius": shader_radius,
				"shader_parameter/corner_radiuses": "Vector4(%f, %f, %f, %f)" % [max(br, parent_radius), max(tr, parent_radius), max(bl, parent_radius), max(tl, parent_radius)],
				"shader_parameter/target_size": "Vector2(%f, %f)" % [width, height],
				"shader_parameter/parent_corner_radius": 0.0,
				"shader_parameter/parent_size": "Vector2(%f, %f)" % [width, height],
				"shader_parameter/offset_in_parent": "Vector2(0.0, 0.0)",
				"shader_parameter/use_texture": true,
			})
			properties["material"] = 'SubResource("%d")' % shader_id
			# 内阴影：material 已���建，叠加 inner shadow 参数（位于 322 shader 分支内，与外阴影独立）
			if node.has("_inner_shadow_data"):
				var _isd = node["_inner_shadow_data"]
				var _isr = _writer.get_sub_resources()[-1]
				_isr["properties"]["shader_parameter/use_inner_shadow"] = true
				_isr["properties"]["shader_parameter/inner_shadow_color"] = _isd["color"]
				_isr["properties"]["shader_parameter/inner_shadow_blur"] = _isd["blur"]
				_isr["properties"]["shader_parameter/inner_shadow_offset"] = _isd["offset"]
			# 保持节点自身的大小，不改变尺寸
			if node.has("_shadow_data"):
				var _sd = node["_shadow_data"]
				# 刚 add_sub_resource 返回的 id 对应 sub_resources 末元素（引用，原地改写）
				var _sr = _writer.get_sub_resources()[-1]
				_sr["properties"]["shader_parameter/use_shadow"] = true
				_sr["properties"]["shader_parameter/shadow_color"] = _sd["color"]
				_sr["properties"]["shader_parameter/shadow_size"] = _sd["size"]
				_sr["properties"]["shader_parameter/shadow_offset"] = _sd["offset"]
		# TextureRect 也可以有荧光效果（如 ring 矢量图）
		elif node.has("_glow_data"):
			var gd2 = node["_glow_data"]
			var shader_id = _writer.add_sub_resource("ShaderMaterial", {
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
			})
			properties["material"] = 'SubResource("%d")' % shader_id
		# material 已创建：补图片填充模式 + 色彩调整 (Figma ImageFilters)，
		# _texture_fill_mode/_image_filters 由 _apply_styles 的 IMAGE 分支暂存
		if properties.has("material") and (node.has("_texture_fill_mode") or node.has("_image_filters")):
			# shader 接管纹理映射(cover/contain/tile)且算 pixel_pos=UV*target_size，须 UV 严格 0..1 覆盖全 rect。
			# CENTERED(5) 缩小居中→shader 困在缩小区；COVERED(6) 保持纹理比例，纹理比例≠rect 时 UV 偏离 0..1
			# → pixel_pos 错位、mask 偏。SCALE(0) UV 严格 0..1 且绘制全 rect，shader 完全接管纹理映射。
			properties["stretch_mode"] = 0  # SCALE
			var _msr = _writer.get_sub_resources()[-1]
			if node.has("_texture_fill_mode"):
				_msr["properties"]["shader_parameter/texture_fill_mode"] = node["_texture_fill_mode"]
				if node.has("_tile_scale"):
					_msr["properties"]["shader_parameter/tile_scale"] = node["_tile_scale"]
			var _flt = node.get("_image_filters", {})
			if _flt is Dictionary and _flt.size() > 0:
				_msr["properties"]["shader_parameter/use_image_adjust"] = true
				_msr["properties"]["shader_parameter/img_exposure"] = float(_flt.get("exposure", 0.0))
				_msr["properties"]["shader_parameter/img_contrast"] = float(_flt.get("contrast", 0.0))
				_msr["properties"]["shader_parameter/img_saturation"] = float(_flt.get("saturation", 0.0))
				_msr["properties"]["shader_parameter/img_temperature"] = float(_flt.get("temperature", 0.0))
				_msr["properties"]["shader_parameter/img_tint"] = float(_flt.get("tint", 0.0))
				_msr["properties"]["shader_parameter/img_highlights"] = float(_flt.get("highlights", 0.0))
				_msr["properties"]["shader_parameter/img_shadows"] = float(_flt.get("shadows", 0.0))
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
			var panel_shader_id = _writer.add_sub_resource("ShaderMaterial", panel_shader_props)
			properties["material"] = 'SubResource("%d")' % panel_shader_id

	# 处理文本
	if node_type == "TEXT":
		_apply_text_properties(node, properties)
	# mask alpha 蒙版（统一：TextureRect/Panel/Label 等任何被遮罩节点都挂 mask shader，覆盖整个子树）
	_apply_mask_alpha(node, properties, width, height)

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

	_writer.add_node_line(node_def)

	# 递归处理子节点
	var current_path: String
	if depth == 0:
		current_path = "."
	else:
		current_path = parent_path + "/" + node_name

	# BOOLEAN_OPERATION 子节点是布尔操作数，视觉已烘焙进父节点合并 SVG，跳过避免空节点。
	# 但 BOOLEAN_OPERATION 作为 mask 时，其 children 是被吸收的遮罩内容（非操作数），必须渲染。
	if node_type != "BOOLEAN_OPERATION" or node.get("_is_mask_clip", false):
		for child in node.get("children", []):
			_process_node(child, current_path, depth + 1)

# mask alpha 蒙版（Figma mask 不规则形状裁剪被遮罩节点）：给当前节点挂/叠加 rounded_rect shader 的 use_mask，
# 用 mask 形状 PNG(renderBounds alpha)裁剪。mask_offset=mask renderBounds 左上 - 节点 absoluteXY（节点像素空间）。
func _apply_mask_alpha(node: Dictionary, properties: Dictionary, width: float, height: float) -> void:
	if not node.has("_mask_alpha"):
		return
	var _ma = node["_mask_alpha"]
	var _mask_png = _assets.vector_cache().get(_ma.get("id", ""), "")
	if _mask_png == "":
		return
	var _mtex_id = _writer.add_ext_resource("Texture2D", _mask_png)
	var _msr: Dictionary
	if properties.has("material"):
		_msr = _writer.get_sub_resources()[-1]
	else:
		var _mid = _writer.add_sub_resource("ShaderMaterial", {
			"shader": 'ExtResource("shader_rounded")',
			"shader_parameter/corner_radius": 0.0,
			"shader_parameter/corner_radiuses": "Vector4(0.0, 0.0, 0.0, 0.0)",
			"shader_parameter/target_size": "Vector2(%f, %f)" % [width, height],
			"shader_parameter/parent_corner_radius": 0.0,
			"shader_parameter/parent_size": "Vector2(%f, %f)" % [width, height],
			"shader_parameter/offset_in_parent": "Vector2(0.0, 0.0)",
			"shader_parameter/use_texture": properties.has("texture"),
		})
		properties["material"] = 'SubResource("%d")' % _mid
		_msr = _writer.get_sub_resources()[-1]
		# 新建 mask material 且节点有纹理(TextureRect)：shader use_texture 接管纹理映射，TextureRect 须
		# stretch_mode=0(SCALE)：UV 严格 0..1 覆盖全 rect，pixel_pos=UV*target_size 不被比例扭曲(COVERED=6 在
		# 纹理比例≠rect 时 UV 偏→mask 错位)。并补 texture_fill_mode(FIT/FILL/TILE)，否则 shader 默认 cover。
		if properties.has("texture"):
			properties["stretch_mode"] = 0  # SCALE
			if node.has("_texture_fill_mode"):
				_msr["properties"]["shader_parameter/texture_fill_mode"] = node["_texture_fill_mode"]
				if node.has("_tile_scale"):
					_msr["properties"]["shader_parameter/tile_scale"] = node["_tile_scale"]
	var _nx = float(node.get("absoluteX", node.get("x", 0.0)))
	var _ny = float(node.get("absoluteY", node.get("y", 0.0)))
	var _dx = float(_ma.get("mx", 0.0)) - _nx
	var _dy = float(_ma.get("my", 0.0)) - _ny
	var _mhw = float(_ma.get("mw", 0.0)) * 0.5
	var _mhh = float(_ma.get("mh", 0.0)) * 0.5
	# shader pixel_pos 是 Control 本地坐标(原点=本地(0,0)=absoluteXY 画布，本地轴随 Godot rotation 旋转)。
	# mask 形状画布固定，节点旋转 → mask 在节点本地系是旋转的；圆形 mask 旋转对称，只需圆心对齐：
	# mask_offset = R⁻¹·(mask圆心画布位移) - mask_size/2，R=[[cos,-sin],[sin,cos]](θ=properties rotation)。
	# (非圆 mask 旋转仍需 shader 旋转采样，此处圆心对齐近似；非旋转节点退化为 (dx,dy)。) 反射(scale.x=-1)跳过。
	var _cx = _dx + _mhw
	var _cy = _dy + _mhh
	var _lcx = _cx
	var _lcy = _cy
	if properties.get("rotation", 0.0) != 0.0 and not properties.has("scale"):
		var _th = float(properties["rotation"])
		var _c = cos(_th)
		var _s = sin(_th)
		_lcx = _c * _cx + _s * _cy
		_lcy = -_s * _cx + _c * _cy
	var _mox = _lcx - _mhw
	var _moy = _lcy - _mhh
	_msr["properties"]["shader_parameter/use_mask"] = true
	_msr["properties"]["shader_parameter/mask_texture"] = 'ExtResource("%d")' % _mtex_id
	_msr["properties"]["shader_parameter/mask_offset"] = "Vector2(%f, %f)" % [_mox, _moy]
	_msr["properties"]["shader_parameter/mask_size"] = "Vector2(%f, %f)" % [float(_ma.get("mw", 0.0)), float(_ma.get("mh", 0.0))]

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
					var color = FigmaImporterUtils._figma_color_to_godot(fill.get("color", {}))
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
					if ref and _assets.image_cache().has(ref):
						var res_id = _writer.add_ext_resource("Texture2D", _assets.image_cache()[ref])
						properties["texture"] = 'ExtResource("%d")' % res_id
						# 图片填充模式 + 色彩调整：material 在 _apply_styles 之后才创建，
						# 此处先暂存到 node，待 TextureRect material 创建后再写入 shader_parameter
						var _sm = fill.get("scaleMode", "FILL")
						if _sm == "TILE":
							node["_texture_fill_mode"] = 2
							node["_tile_scale"] = float(fill.get("scalingFactor", 1.0))
						elif _sm == "FIT":
							node["_texture_fill_mode"] = 0
						else:
							node["_texture_fill_mode"] = 1
						var _flt = fill.get("filters", {})
						if _flt is Dictionary and _flt.size() > 0:
							node["_image_filters"] = _flt

	# 处理矢量（TEXT 跳过：保持 Label；mask 跳过：Figma 中 mask 只裁剪、自身填充不渲染，
	# 保持透明 Control 做裁剪容器，不赋 texture 以免被盖成 TextureRect 显示不存在的填充）
	if not is_text and _assets.vector_cache().has(node_id) and not node.get("_is_mask_clip", false):
		var res_id = _writer.add_ext_resource("Texture2D", _assets.vector_cache()[node_id])
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
				var stroke_color = FigmaImporterUtils._figma_color_to_godot(stroke.get("color", {}))
				var border_w = stroke_weight if stroke_weight >= 0.5 else 1
				# 存储描边数据供 shader 使用
				node["_stroke_data"] = {"color": stroke_color, "width": border_w}
				# VECTOR ��型已有纹理，不需要 panel 样式
				if node_type != "VECTOR" and node_type != "BOOLEAN_OPERATION" and not properties.has("theme_override_styles/panel"):
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
					if node_type == "VECTOR" or node_type == "BOOLEAN_OPERATION":
						var color = effect.get("color", {})
						node["_glow_data"] = {
							"color": "Color(%f, %f, %f, %f)" % [color.get("r",0), color.get("g",0), color.get("b",0), color.get("a",1)],
							"radius": radius,
							"intensity": clampf(color.get("a", 1.0) * 2.0, 0.0, 1.0),
						}
				else:
					# 普通投影：合并进节点 panel StyleBoxFlat（见 _apply_drop_shadow��
					_apply_drop_shadow(effect, properties)
					has_drop_shadow = true
					var _sc = effect.get("color", {})
					node["_shadow_data"] = {
						"color": FigmaImporterUtils._figma_color_to_godot(_sc),
						"size": effect.get("radius", 0),
						"offset": "Vector2(%f, %f)" % [ox, oy],
					}
			"INNER_SHADOW":
				var ic = effect.get("color", {})
				var io = effect.get("offset", {})
				node["_inner_shadow_data"] = {
					"color": FigmaImporterUtils._figma_color_to_godot(ic),
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
	return _writer.add_sub_resource("StyleBoxFlat", {
		"bg_color": color,
		"corner_radius_top_left": tl,
		"corner_radius_top_right": tr,
		"corner_radius_bottom_left": bl,
		"corner_radius_bottom_right": br,
	})

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

	return _writer.add_sub_resource("StyleBoxFlat", {
		"bg_color": FigmaImporterUtils._figma_color_to_godot(best_color),
		"corner_radius_top_left": tl,
		"corner_radius_top_right": tr,
		"corner_radius_bottom_left": bl,
		"corner_radius_bottom_right": br,
	})

func _create_border_style(color: String, width, corner_radius) -> String:
	return _create_border_style_ex(color, width, corner_radius, corner_radius, corner_radius, corner_radius)

func _create_border_style_ex(color: String, width, tl: int, tr: int, bl: int, br: int) -> String:
	var w = max(1, int(ceil(width)))
	var res_id = _writer.add_sub_resource("StyleBoxFlat", {
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
	})
	return 'SubResource("%d")' % res_id

func _apply_drop_shadow(effect: Dictionary, properties: Dictionary) -> void:
	# 将投影合并到节点当前的 panel StyleBoxFlat。
	# StyleBoxFlat 的 shadow 是背景阴影，写到节点正在用的 bg style 上即可生效。
	# 旧实现单独创建了一个 StyleBoxFlat 但没赋给节点，导致阴影完全不显示。
	# 若节点没有 panel 样式（纯 TextureRect/Label），则无法应用，跳过。
	if not properties.has("theme_override_styles/panel"):
		return
	var style_id := FigmaImporterUtils._extract_sub_resource_id(str(properties["theme_override_styles/panel"]))
	if style_id < 0:
		return
	# get_sub_resources 返回内部数组引用，res 是其元素(Dictionary 引用)，原地改写生效
	for res in _writer.get_sub_resources():
		if int(res["id"]) == style_id:
			var offset = effect.get("offset", {})
			res["properties"]["shadow_color"] = FigmaImporterUtils._figma_color_to_godot(effect.get("color", {}))
			res["properties"]["shadow_size"] = effect.get("radius", 0)
			res["properties"]["shadow_offset"] = "Vector2(%f, %f)" % [offset.get("x", 0), offset.get("y", 0)]
			return

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

	# 字体（含兜底：缺失精确 weight 时 fallback 到同 family 保证位置正确；完全缺失则标记 + 警告，不再静默用默认字体）
	var font_family = style.get("fontFamily", "")
	var font_weight = style.get("fontWeight", "")
	if font_family and font_weight:
		var font_key = "%s_%s" % [font_family, font_weight]
		var font_path = _fonts.lookup(font_key)
		if font_path != "":
			var res_id = _writer.add_ext_resource("FontFile", font_path)
			properties["theme_override_fonts/font"] = 'ExtResource("%d")' % res_id
			# fallback：已绑定（位置正确），但字形可能与 Figma 不一致，节点标记 + 警告
			if _fonts.lookup_status(font_key) == "fallback":
				properties["metadata/_figma_font_fallback"] = true
				push_warning("[FigmaImporter] \"%s\" 字体 %s %s 缺失精确文件，已 fallback 到同 family（位置正确，字形可能不一致）" % [node.get("name", ""), font_family, font_weight])
		else:
			# 缺失：未绑定字体，位置/字形将与 Figma 不一致，节点标记 + 警告
			properties["metadata/_figma_font_missing"] = true
			push_warning("[FigmaImporter] \"%s\" 字体 %s %s 缺失，未绑定（请下载 .ttf 到 figma_export_assets/fonts/ 后重新导入）" % [node.get("name", ""), font_family, font_weight])

	# 文本颜色：SOLID 直接取；GRADIENT 取中点(position≈0.5)stop 色作单色近似
	# （Godot Label font_color 仅单色，不支持渐变填充；丢失渐变但保留代表色，如 Kronor 金色）
	for fill in node.get("fills", []):
		var _ftype = fill.get("type", "")
		if _ftype == "SOLID":
			properties["theme_override_colors/font_color"] = FigmaImporterUtils._figma_color_to_godot(fill.get("color", {}))
			break
		elif _ftype.begins_with("GRADIENT"):
			var _stops = fill.get("gradientStops", [])
			if _stops.size() > 0:
				var _best = _stops[0]
				var _best_d = abs(float(_stops[0].get("position", 0)) - 0.5)
				for _s in _stops:
					var _d = abs(float(_s.get("position", 0)) - 0.5)
					if _d < _best_d:
						_best = _s
						_best_d = _d
				properties["theme_override_colors/font_color"] = FigmaImporterUtils._figma_color_to_godot(_best.get("color", {}))
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
	if _fonts.lookup(_font_key) != "":
		var _font_res_path = _fonts.lookup(_font_key)
		var _abs_path = ProjectSettings.globalize_path(_font_res_path)
		if FileAccess.file_exists(_abs_path):
			var _f = FileAccess.open(_abs_path, FileAccess.READ)
			if _f:
				var _data = _f.get_buffer(_f.get_length())
				_f.close()
				var _font = FontFile.new()
				_font.data = _data
				# 水平：字符实际推进宽度（figma 框宽 < 字符宽时，避免 Godot Label 被 minimum_size 撑大导致偏移）
				_godot_rw = _font.get_string_size(_text, 0, -1, font_size).x
				var _ascent = _font.get_ascent(font_size)
				var _descent = _font.get_descent(font_size)
				if _ascent > 0 and _descent > 0:
					_godot_rh = _ascent + _descent

	# 水平 offset：rect 宽=字符推进宽度 _godot_rw，按对齐让字符锚点对齐 Figma 框对应位置
	# （字符宽 > Figma 框宽时，避免 Godot Label 被 minimum_size 撑大、offset_left 不变而整体偏移）
	var _ha = int(properties.get("horizontal_alignment", 0))
	var ol = _ol  # LEFT / JUSTIFIED：字符左边对齐 Figma 框左边
	if _ha == 1:  # CENTER：字符中心对齐 Figma 框中心
		ol = _ol + (_fw - _godot_rw) / 2.0
	elif _ha == 2:  # RIGHT：字符右边对齐 Figma 框右边
		ol = _ol + (_fw - _godot_rw)
	var ot = _ot + (_fh - _godot_rh) / 2.0
	properties["offset_left"] = ol
	properties["offset_top"] = ot
	properties["offset_right"] = ol + _godot_rw
	properties["offset_bottom"] = ot + _fh

	# ── textAutoResize 控制尺寸行为 ──
	match node.get("textAutoResize", "NONE"):
		"TRUNCATE":
			properties["clip_text"] = true
			properties["text_overrun"] = 3  # ELLipsis
		# WIDTH_AND_HEIGHT / HEIGHT / NONE: offset 已修正，保持不变
