class_name FigmaImporterUtils
extends RefCounted

# 无状态工具函数集合（全 static）：文件名清洗、颜色转换、字体名匹配、
# 边界计算、mask 重组、父节点坐标预处理等。
# 主导入器与各子模块均通过 FigmaImporterUtils._xxx() 调用。
# 注：函数名保留原下划线前缀，调用点仅需加 FigmaImporterUtils. 前缀。

# 替换 Windows 文件名非法字符
static func _sanitize_filename(name: String) -> String:
	var result = name.replace(":", "_").replace(";", "_").replace("\\", "_").replace("/", "_")
	result = result.replace("*", "_").replace("?", "_").replace('"', "_")
	result = result.replace("<", "_").replace(">", "_").replace("|", "_")
	return result

# base64 字符串 → 写入文件（图片/字体位图）
static func _save_base64_image(base64_data: String, path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var bytes = Marshalls.base64_to_raw(base64_data)
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_buffer(bytes)
		file.close()

# 递归收集所有 TEXT 节点 id（这些节点保持为 Label，不转图片）
static func _collect_text_node_ids(nodes: Array) -> PackedStringArray:
	var text_ids = PackedStringArray()
	for node in nodes:
		if node.get("type", "") == "TEXT":
			text_ids.append(node.get("id", ""))
		var children = node.get("children", [])
		if not children.is_empty():
			text_ids.append_array(FigmaImporterUtils._collect_text_node_ids(children))
	return text_ids

# 取节点第一个 IMAGE 填充的 imageRef（位图填充 vector 判定）
static func _get_image_fill_ref(node: Dictionary) -> String:
	var fills = node.get("fills", [])
	if fills is Array:
		for f in fills:
			if f is Dictionary and f.get("type", "") == "IMAGE":
				var ref = f.get("imageRef", "")
				if ref != "":
					return ref
	return ""

# 节点是否有可见的外扩阴影(DROP_SHADOW)：外扩阴影膨胀 PNG 并污染 alpha 中心扫描
static func _has_visible_drop_shadow(n: Dictionary) -> bool:
	var effects = n.get("effects", [])
	if not (effects is Array):
		return false
	for e in effects:
		if e is Dictionary and e.get("type", "") == "DROP_SHADOW" and e.get("visible", true):
			return true
	return false

# 扫描图像 alpha 通道，返回不透明内容的几何中心(像素)；无内容返回 null。
# 修正 SVG/PNG 画布留白(阴影、viewBox/渲染范围不对称)导致的内容偏移，供"内容中心对齐"使用。
static func _scan_alpha_center(img: Image, threshold: int = 12):
	img.convert(Image.FORMAT_RGBA8)
	var _cdata = img.get_data()
	var _cw = img.get_width()
	var _ch = img.get_height()
	var _cmn_x = _cw
	var _cmn_y = _ch
	var _cmx_x = -1
	var _cmx_y = -1
	var _ci = 0
	for _cpy in range(_ch):
		for _cpx in range(_cw):
			if _cdata[_ci + 3] > threshold:
				if _cpx < _cmn_x: _cmn_x = _cpx
				if _cpx > _cmx_x: _cmx_x = _cpx
				if _cpy < _cmn_y: _cmn_y = _cpy
				if _cpy > _cmx_y: _cmx_y = _cpy
			_ci += 4
	if _cmx_x >= 0:
		return Vector2((_cmn_x + _cmx_x + 1) / 2.0, (_cmn_y + _cmx_y + 1) / 2.0)  # +1: pixel-index (min+max)/2 is 0.5px less than geometric center (min+max+1)/2
	return null

# Figma 字重名 → Google Fonts wght 数字
static func _get_weight(style: String) -> String:
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

# 递归收集目录下所有 .ttf/.otf 文件
static func _collect_fonts_recursive(dir_path: String, result: PackedStringArray) -> void:
	var dir = DirAccess.open(dir_path)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not file_name.begins_with("."):
			var full_path = dir_path + file_name
			if dir.current_is_dir():
				FigmaImporterUtils._collect_fonts_recursive(full_path + "/", result)
			elif file_name.ends_with(".ttf") or file_name.ends_with(".otf"):
				result.append(full_path)
		file_name = dir.get_next()
	dir.list_dir_end()

# 为 family/style 在可用字体文件中查找匹配。
# family 名比较前去除空格：导出端下载文件名去空格(如 "ElMessiri-Bold.ttf")，
# 而 Figma family 带空格("El Messiri")，直接 contains 永远不命中 → 退回网络下载。
# 归一后本地即可命中，加载不再依赖网络。

# 样式别名映射（精确匹配/判断共用）：Figma weight 名 → 文件名常见后缀
static func _font_style_aliases() -> Dictionary:
	return {
		"regular": ["regular", "normal", "book", "roman"],
		"bold": ["bold", "heavy", "black"],
		"italic": ["italic", "oblique", "slanted"],
		"bold italic": ["bold italic", "boldoblique", "heavyitalic"],
		"light": ["light", "thin", "hairline"],
		"medium": ["medium", "semibold", "demi"],
	}

# 判断已匹配的字体文件是否精确对应请求的 style（含别名）。
# Regular 特判：文件名不含任何 weight 后缀时视为 regular。
# 用于区分"精确匹配"与"仅 family 级 fallback"，决定是否标记字形不一致。
static func _is_font_style_match(font_path: String, style: String) -> bool:
	var file_name = font_path.get_file().get_basename().to_lower().replace(" ", "")
	var style_lower = style.to_lower()
	if file_name.contains(style_lower):
		return true
	for alias in _font_style_aliases().get(style_lower, [style_lower]):
		if file_name.contains(alias):
			return true
	if style_lower == "regular" or style_lower == "normal":
		for s in ["bold", "italic", "light", "medium", "thin", "heavy", "semibold", "demi", "black"]:
			if file_name.contains(s):
				return false
		return true
	return false

static func _find_matching_font(family: String, style: String, available_fonts: PackedStringArray) -> String:
	# 将字体名称转换为小写用于比较（family 去空格以匹配去空格的下载文件名）
	var family_lower = family.to_lower().replace(" ", "")
	var style_lower = style.to_lower()
	var style_aliases = _font_style_aliases()

	# 第一轮：精确匹配（文件名包含 family + style）
	for font_path in available_fonts:
		var file_name = font_path.get_file().get_basename().to_lower().replace(" ", "")
		if file_name.contains(family_lower) and file_name.contains(style_lower):
			return font_path

	# 第二轮：只匹配 family，style 为 regular 时优先匹配无 style 的文件
	for font_path in available_fonts:
		var file_name = font_path.get_file().get_basename().to_lower().replace(" ", "")
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
		var file_name = font_path.get_file().get_basename().to_lower().replace(" ", "")
		if file_name.contains(family_lower):
			return font_path

	return ""

# 递归计算节点（含子树）的绝对坐标边界框
static func _calculate_bounds(node: Dictionary) -> Dictionary:
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
		var child_bounds = FigmaImporterUtils._calculate_bounds(child)
		bounds.min_x = min(bounds.min_x, child_bounds.min_x)
		bounds.min_y = min(bounds.min_y, child_bounds.min_y)
		bounds.max_x = max(bounds.max_x, child_bounds.max_x)
		bounds.max_y = max(bounds.max_y, child_bounds.max_y)

	return bounds

# Figma mask（蒙版）：mask 形状遮罩同层级、z序在其后的连续兄弟节点。
# 重组树：mask 吸收后续兄弟为子节点 + 设 clipsContent=true，借现有 clip_contents 逻辑裁剪；
# 坐标由 _preprocess 的 absoluteX/Y 差值自动修正（被遮罩节点 _rel 自动变为相对 mask 原点）。
static func _apply_mask_groups(node: Dictionary) -> void:
	var children = node.get("children", [])
	if not (children is Array):
		return
	for c in children:
		FigmaImporterUtils._apply_mask_groups(c)
	var new_children: Array = []
	var i := 0
	while i < children.size():
		var c = children[i]
		if c is Dictionary and c.get("isMask", false) == true:
			c["clipsContent"] = true
			c["_is_mask_clip"] = true
			# Figma 中 mask 仅作裁剪形状，自身 fill 不渲染 → 清空避免背景色
			c["fills"] = []
			new_children.append(c)
			# Figma mask 不渲染 mask 形状自身填充（仅用形状 alpha 裁剪），裁剪由本节点 clip_contents 提供；
			# 故丢弃 mask 原有 children（mask 形状）。FRAME/COMPONENT 作 mask 时其子是被遮罩内容，需保留。
			var masked: Array = []
			var mtype = c.get("type", "")
			if mtype == "FRAME" or mtype == "COMPONENT":
				var own = c.get("children", [])
				if own is Array:
					masked.append_array(own)
			var j := i + 1
			while j < children.size() and not (children[j] is Dictionary and children[j].get("isMask", false)):
				masked.append(children[j])
				j += 1
			# mask 形状几何用 renderBounds(PNG 范围，含描边/效果外扩)：mask 节点已由 _attach_mask_render_bounds
			# 挂 _mask_rb=[x,y,w,h](绝对画布坐标)。无 _mask_rb 时回退 bounding box。被遮罩节点各自在场景生成时
			# 用自己的 absoluteX/Y 算 UV，故此处只存 mask 绝对几何，由 _propagate_mask_alpha 传到整个子树。
			var _mid = c.get("id", "")
			var _mrb = c.get("_mask_rb", null)
			var _mx: float
			var _my: float
			var _mw: float
			var _mh: float
			if _mrb is Array and _mrb.size() >= 4:
				_mx = float(_mrb[0])
				_my = float(_mrb[1])
				_mw = float(_mrb[2])
				_mh = float(_mrb[3])
			else:
				_mx = float(c.get("absoluteX", c.get("x", 0.0)))
				_my = float(c.get("absoluteY", c.get("y", 0.0)))
				_mw = float(c.get("width", 0.0))
				_mh = float(c.get("height", 0.0))
			var _ma := {"id": _mid, "mx": _mx, "my": _my, "mw": _mw, "mh": _mh}
			for _mc in masked:
				if _mc is Dictionary and not _mc.get("_is_mask_clip", false):
					_mc["_mask_alpha"] = _ma
					_propagate_mask_alpha(_mc, _ma)
			c["children"] = masked
			i = j
		else:
			new_children.append(c)
			i += 1
	node["children"] = new_children

# 把导出端的 maskRenderBounds(绝对坐标)挂到对应 mask 节点 _mask_rb，供 _apply_mask_groups 读取。
static func _attach_mask_render_bounds(node: Dictionary, mask_rb_map: Dictionary) -> void:
	if node.get("isMask", false) == true:
		var _id = node.get("id", "")
		if mask_rb_map.has(_id):
			node["_mask_rb"] = mask_rb_map[_id]
	for _c in node.get("children", []):
		if _c is Dictionary:
			_attach_mask_render_bounds(_c, mask_rb_map)

# 递归传播 _mask_alpha 到被遮罩节点的整个子树（每个后代场景生成时用自己的绝对坐标算 UV）。
# 遇到嵌套 mask 阻断：嵌套 mask 的子树由其自身 _apply_mask_groups 处理。
static func _propagate_mask_alpha(node: Dictionary, mask_alpha: Dictionary) -> void:
	for _c in node.get("children", []):
		if _c is Dictionary and not _c.get("isMask", false) and not _c.has("_mask_alpha"):
			_c["_mask_alpha"] = mask_alpha
			_propagate_mask_alpha(_c, mask_alpha)

# 预处理：计算每个节点相对父节点的坐标、圆角裁剪祖先、荧光传递等。注入 _rel_x/_rel_y/
# _parent_corner_radius/_offset_in_parent/_glow_data 等下划线字段，供 _process_node 只读消费。
static func _preprocess_parent_positions(node: Dictionary, parent_pos: Dictionary, offset_x: float = 0, offset_y: float = 0, depth: int = 0, root_width: float = 0, root_height: float = 0) -> void:
	# 父节点不可见时，子节点也不可见（Figma 行为）
	if parent_pos.get("visible", true) == false:
		node["visible"] = false
	# 存储父节点的绝对坐标（已减去全局偏移量）
	var abs_x = node.get("absoluteX", node.get("x", 0)) - offset_x
	var abs_y = node.get("absoluteY", node.get("y", 0)) - offset_y
	# Figma Plugin API 已知 bug：GROUP 内与 GROUP 完全重叠（同尺寸）的子节点，其 absoluteY
	# 会多加 GROUP 高度（子被错放到 GROUP 正下方紧贴）。检测尺寸相同且 reported absY 恰好
	# 落在 GROUP 底边（absY 差 ≈ GROUP 高度）时，减去 GROUP 高度修正（如 Mask_Group/Rarity）。
	if parent_pos.get("is_group", false):
		var _p_size = parent_pos.get("size", Vector2.ZERO)
		if _p_size.y > 0 and abs(node.get("width", 0) - _p_size.x) < 0.5 and abs(node.get("height", 0) - _p_size.y) < 0.5:
			if abs((abs_y - parent_pos.get("abs_y", abs_y)) - _p_size.y) < 0.5:
				abs_y -= _p_size.y
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
	var _obo = parent_pos.get("origin_bbox_offset", Vector2.ZERO)
	node["_rel_x"] = abs_x - _p_abs_x + _obo.x
	node["_rel_y"] = abs_y - _p_abs_y + _obo.y

	# 直接父是否 clipsContent（矩形裁边界判断，保留原语义）
	node["_parent_clips_content"] = parent_pos.get("clips_content", false)
	# 圆角裁剪祖先：沿树向上最近的 clipsContent+圆角>0 祖先（跳过无圆角中间层）。
	# Figma clipsContent+cornerRadius 按圆角形状裁所有后代；Godot clip_contents 仅矩形裁，
	# 故后代用 shader 的 parent_corner_radius 自我裁剪到祖先圆角（如工具栏贴 HMI 圆角边）。
	# clip_anc_base_offset = 父相对(父的裁剪祖先)的偏移；本节点相对裁剪祖先 = _rel + base_offset。
	var _anc_radius = parent_pos.get("clip_anc_radius", 0)
	var _anc_base = parent_pos.get("clip_anc_base_offset", Vector2.ZERO)
	node["_parent_corner_radius"] = _anc_radius
	node["_parent_size"] = parent_pos.get("clip_anc_size", Vector2.ZERO)
	node["_offset_in_parent"] = Vector2(node["_rel_x"], node["_rel_y"]) + _anc_base

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
	if node_type != "VECTOR" and node_type != "BOOLEAN_OPERATION":
		for effect in node.get("effects", []):
			if effect.get("type") == "DROP_SHADOW":
				var eoffset = effect.get("offset", {})
				if eoffset.get("x", 0) == 0 and eoffset.get("y", 0) == 0 and effect.get("radius", 0) >= 5:
					# 递归查找第一个 VECTOR 后代节点传递荧光
					var found = FigmaImporterUtils._find_last_vector(children)
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
	# 反射节点(det<0)的 origin 落在 bbox 外(x 反射在右、y 反射在下)。下游 _rel=子origin-父origin 是相对父 origin，
	# 但 Godot offset 空间原点=父 bbox 左上；反射父须补偿 origin→bbox左上，否则反射 GROUP 的子节点整体偏
	# -(反射轴尺寸)(如 Mask_Group 子偏 -父width)。
	var _rt_self = node.get("relativeTransform", null)
	var _origin_bbox = Vector2.ZERO
	if _rt_self != null and float(_rt_self[0][0]) * float(_rt_self[1][1]) - float(_rt_self[0][1]) * float(_rt_self[1][0]) < 0:
		if float(_rt_self[0][0]) < 0:
			_origin_bbox.x = node.get("width", 0.0)
		if float(_rt_self[1][1]) < 0:
			_origin_bbox.y = node.get("height", 0.0)
	var current_corner = node.get("cornerRadius", 0)
	var current_clips = node.get("clipsContent", false)
	var current_size = Vector2(node.get("width", 0), node.get("height", 0))

	# 所有节点都使用自己的绝对坐标作为参考点
	# Group 在 Figma 中不改变坐标系统，但 Godot 中每个节点都需要相对父节点的坐标
	# 注意：Figma Plugin API 对 GROUP 内子节点的 absoluteY 有已知 bug
	#（与 GROUP 完全重叠的子节点 absoluteY 会多加 GROUP 的高度），
	# 但这是 API 层面的问题，导出插件无法修复。
	# 本节点是否为新的圆角裁剪边界（clipsContent+圆角>0+无旋转）；否则子继承本节点的裁剪祖先
	var _self_is_anc = current_clips and current_corner > 0 and node.get("rotation", 0.0) == 0.0
	var _anc_radius_c = float(current_corner) if _self_is_anc else float(node["_parent_corner_radius"])
	var _anc_size_c = current_size if _self_is_anc else node["_parent_size"]
	var _anc_base_c = Vector2.ZERO if _self_is_anc else node["_offset_in_parent"]
	var current_pos = {
		"abs_x": abs_x,
		"abs_y": abs_y,
		"corner_radius": current_corner,
		"clips_content": current_clips,
		"size": current_size,
		"visible": node.get("visible", true),
		"rotation": node.get("rotation", 0.0),
		"is_group": is_group,
		"clip_anc_radius": _anc_radius_c,
		"clip_anc_size": _anc_size_c,
		"clip_anc_base_offset": _anc_base_c,
		"origin_bbox_offset": _origin_bbox,
	}
	for child in children:
		FigmaImporterUtils._preprocess_parent_positions(child, current_pos, offset_x, offset_y, depth + 1, root_width, root_height)

# 递归查找最后一个 VECTOR 类型的节点（ring 总是排在 SVG 组最后）
static func _find_last_vector(nodes: Array) -> Dictionary:
	var result = {}
	for node in nodes:
		if node.get("type", "") == "VECTOR":
			result = node
		var children = node.get("children", [])
		if children.size() > 0:
			var found = FigmaImporterUtils._find_last_vector(children)
			if not found.is_empty():
				result = found
	return result

# 检查节点是否只有纯黑色 SOLID 填充（Figma 中不可见，导出后应隐藏）
static func _is_solid_black_fill(node: Dictionary) -> bool:
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

# Godot 节点名不允许 / . : [ ] 及空白；保留中文等 Unicode 字符
static func _sanitize_name(name: String) -> String:
	var regex = RegEx.new()
	regex.compile("[/.\\[\\]\\s:]")
	var result = regex.sub(name, "_", true)
	return result if result.length() > 0 else "Node"

# 把 sub_resource 字典格式化为 tscn 片段
static func _format_sub_resource(res: Dictionary) -> String:
	var content = '[sub_resource type="%s" id="%d"]\n' % [res["type"], res["id"]]
	for key in res["properties"]:
		content += "%s = %s\n" % [key, str(res["properties"][key])]
	content += "\n"
	return content

# 从 'SubResource("5")' 形式的字符串中解析出资源 id
static func _extract_sub_resource_id(s: String) -> int:
	var regex = RegEx.new()
	regex.compile('SubResource\\("(-?\\d+)"\\)')
	var m = regex.search(s)
	if m:
		return int(m.get_string(1))
	return -1

# Figma 归一化颜色(r,g,b,a ∈ [0,1]) → Godot Color 字符串
static func _figma_color_to_godot(color: Dictionary) -> String:
	var r = color.get("r", 0.0)
	var g = color.get("g", 0.0)
	var b = color.get("b", 0.0)
	var a = color.get("a", 1.0)
	return "Color(%f, %f, %f, %f)" % [r, g, b, a]
