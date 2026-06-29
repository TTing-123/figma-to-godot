class_name FigmaAssetExtractor
extends RefCounted

# 资源提取器：图片 / 矢量(SVG→PNG@3x) / 位图填充 vector / PNG 回退矢量。
# 持有 4 个 cache，由主导入器实例 _assets 持有；extract() 一次性填充，主文件经只读访问器读取。
# 副作用：extract 在 node dict 注入 _bitmap_corner_baked / _effects_baked_in_texture，
# 供 _process_node 判断纹理是否已烘焙圆角/阴影/渐变（是则跳过 shader）。

var _image_cache: Dictionary = {}
var _vector_cache: Dictionary = {}
var _vector_size_cache: Dictionary = {}
var _vector_content_center_cache: Dictionary = {}  # 内容几何中心(像素)：修正 PNG 画布留白不对称

func image_cache() -> Dictionary:
	return _image_cache

func vector_cache() -> Dictionary:
	return _vector_cache

func vector_size_cache() -> Dictionary:
	return _vector_size_cache

func vector_content_center_cache() -> Dictionary:
	return _vector_content_center_cache

func extract(data: Dictionary, assets_dir: String) -> void:
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
		var safe_name = FigmaImporterUtils._sanitize_filename(ref)
		var image_path = images_dir + "%s.png" % safe_name
		FigmaImporterUtils._save_base64_image(base64_data, image_path)
		_image_cache[ref] = image_path

	# 收集所有TEXT节点的ID，这些节点不应该被转换为图片
	var text_node_ids = FigmaImporterUtils._collect_text_node_ids(data.get("nodes", []))

	# 提取矢量资源（SVG 字符串 → 栅格化成 PNG）
	var vectors = data.get("vectors", {})
	# 导出端矢量本体几何中心(PNG @3x 像素)：含阴影/模糊外扩矢量用于精确对齐本体，替代 alpha 扫描
	var _body_centers = data.get("vectorBodyCenter", {})
	# 建 node_id → node 查找表（位图填充分流需 fills/cornerRadius/width/height）
	var _node_by_id: Dictionary = {}
	var _stk: Array = []
	for _nd in data.get("nodes", []):
		_stk.append(_nd)
	while _stk.size() > 0:
		var _nd2 = _stk.pop_back()
		if _nd2 is Dictionary:
			_node_by_id[_nd2.get("id", "")] = _nd2
			var _cs = _nd2.get("children", [])
			if _cs is Array:
				for _cc in _cs:
					_stk.append(_cc)
	for node_id in vectors:
		# 跳过TEXT类型的节点，保持为Label而不是图片
		if node_id in text_node_ids:
			continue

		var svg_text = vectors[node_id]
		var safe_name = FigmaImporterUtils._sanitize_filename(node_id)
		var png_path = vectors_dir + "%s.png" % safe_name
		# 位图填充的 vector：Godot SVG 栅格化不支持 <pattern>+<image>，
		# 改用原始位图 + 圆角 alpha mask 生成 PNG（保留圆角，下游 texture/size/位置复用 vector 路径）。
		var _n: Dictionary = _node_by_id.get(node_id, {})
		var _iref = FigmaImporterUtils._get_image_fill_ref(_n)
		# 位图填充且导出端已烘焙 PNG(含形状+描边+阴影)时跳过此重建，交由下方 PNG 分支用烘焙结果；
		# 否则只用原始位图+圆角 mask 会丢矢量形状(如六边形切角)与描边。
		if _iref != "" and _image_cache.has(_iref) and not svg_text.begins_with("PNG:"):
			var _vw = float(_n.get("width", 0.0))
			var _vh = float(_n.get("height", 0.0))
			var _vcr = float(_n.get("cornerRadius", 0))
			if _rasterize_image_fill_vector(_iref, png_path, _vw, _vh, _vcr):
				_vector_cache[node_id] = png_path
				_vector_size_cache[node_id] = Vector2(_vw * 3.0, _vh * 3.0)
				_vector_content_center_cache[node_id] = Vector2(_vw * 1.5, _vh * 1.5)
				_n["_bitmap_corner_baked"] = true
			continue
		# PNG 回退：导出��� SVG 失败/无矢量内容时已栅格化为 PNG（3x），前缀 "PNG:" 标记
		if svg_text.begins_with("PNG:"):
			var _pb64 = svg_text.substr(4)
			var _pbytes = Marshalls.base64_to_raw(_pb64)
			var _pimg := Image.new()
			# 拒收 1×1 占位空图(mask/空节点导出失败)，否则节点会缩成 ~0.33px
			if _pimg.load_png_from_buffer(_pbytes) == OK and _pimg.get_width() >= 2 and _pimg.get_height() >= 2:
				_pimg.save_png(png_path)
				_vector_cache[node_id] = png_path
				_vector_size_cache[node_id] = Vector2(_pimg.get_width(), _pimg.get_height())
				# 导出端 PNG 已烘焙阴影/模糊/渐变(见 code.ts _vectorNeedsPng)，纹理内已含效果；
				# 导入端不应再挂 shader 重画阴影(TextureRect 不渲染节点外，use_shadow 本就画不出)。
				_n["_effects_baked_in_texture"] = true
				# 本体几何中心：优先用导出端精确值(本体在 PNG @3x 的像素中心)；
				# 阴影/模糊外扩使 PNG 比本体大且不对称，alpha 扫描对半透明/渐变本体不可靠。
				# 无精确值时回退高阈值扫描(扫不到则由对齐处回退 PNG 中心)。
				var _bc = _body_centers.get(node_id, null)
				if _bc != null and _bc is Array and _bc.size() >= 2:
					_vector_content_center_cache[node_id] = Vector2(float(_bc[0]), float(_bc[1]))
				else:
					var _pthr2 = 180 if FigmaImporterUtils._has_visible_drop_shadow(_n) else 12
					var _pcc2 = FigmaImporterUtils._scan_alpha_center(_pimg, _pthr2)
					if _pcc2 != null:
						_vector_content_center_cache[node_id] = _pcc2
			else:
				push_warning("[FigmaImporter] PNG 回退无效或占位空图(1×1)跳过: %s" % node_id)
			continue
		# SVG 含完整路径数据，栅格化成 PNG（3x scale）
		var svg_bytes = svg_text.to_utf8_buffer()
		var img := Image.new()
		if img.load_svg_from_buffer(svg_bytes, 3.0) == OK:
			img.save_png(png_path)
			_vector_cache[node_id] = png_path
			_vector_size_cache[node_id] = Vector2(img.get_width(), img.get_height())
			# 内容几何中心(像素)：用于修正 SVG viewBox 留白/描边不对称导致的内容偏移
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
					if _cdata[_ci + 3] > 12:
						if _cpx < _cmn_x: _cmn_x = _cpx
						if _cpx > _cmx_x: _cmx_x = _cpx
						if _cpy < _cmn_y: _cmn_y = _cpy
						if _cpy > _cmx_y: _cmx_y = _cpy
					_ci += 4
			if _cmx_x >= 0:
				_vector_content_center_cache[node_id] = Vector2((_cmn_x + _cmx_x) / 2.0, (_cmn_y + _cmx_y) / 2.0)
		else:
			push_warning("[FigmaImporter] SVG 栅格化失败: %s" % node_id)

# 位图填充 vector：原始位图 + 圆角 alpha mask → PNG（Godot SVG 栅格化不支持 pattern+image 位图填充）
func _rasterize_image_fill_vector(ref: String, out_png: String, width: float, height: float, corner: float) -> bool:
	if not _image_cache.has(ref):
		return false
	var img := Image.new()
	if img.load(_image_cache[ref]) != OK:
		push_warning("[FigmaImporter] 位图填充加载失败: %s" % ref)
		return false
	img.convert(Image.FORMAT_RGBA8)
	var SCALE := 3.0
	var tw := int(round(width * SCALE))
	var th := int(round(height * SCALE))
	if tw < 1: tw = 1
	if th < 1: th = 1
	img.resize(tw, th, Image.INTERPOLATE_LANCZOS)
	if corner > 0.0:
		var r := corner * SCALE
		var hw := tw / 2.0
		var hh := th / 2.0
		var hx := hw - r
		var hy := hh - r
		if hx < 0.0: hx = 0.0
		if hy < 0.0: hy = 0.0
		var data := img.get_data()
		var i := 0
		for y in range(th):
			var ay: float = abs(float(y) - hh)
			var qy: float = ay - hy
			if qy < 0.0: qy = 0.0
			for x in range(tw):
				var ax: float = abs(float(x) - hw)
				var qx: float = ax - hx
				if qx < 0.0: qx = 0.0
				var dist := sqrt(qx * qx + qy * qy) - r
				var cov := 0.5 - dist
				if cov <= 0.0:
					data[i + 3] = 0
				elif cov < 1.0:
					var na := int(round(data[i + 3] * cov))
					if na < 0: na = 0
					elif na > 255: na = 255
					data[i + 3] = na
				i += 4
		img = Image.create_from_data(tw, th, false, Image.FORMAT_RGBA8, data)
	img.save_png(out_png)
	return true
