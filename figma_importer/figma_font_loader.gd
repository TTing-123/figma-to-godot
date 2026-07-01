class_name FigmaFontLoader
extends RefCounted

# 字体加载器：本地匹配(.ttf/.otf) + Google Fonts 在线下载，持有 _font_cache。
# 主导入器实例 _fonts 持有；find_fonts() 一次性填充，主文件经 lookup(key) 读取。

var _font_cache: Dictionary = {}  # { "fontFamily_fontWeight": "res://path/to/font.ttf" }
# 每个 key 的匹配状态: "exact"(精确style) | "fallback"(仅同family,字形可能不一致) | "downloaded"(在线下载) | "missing"(未获取,未绑定)
var _font_status: Dictionary = {}

# 按 "family_weight" 键查字体资源路径；未命中返回 ""（供主文件用 != "" 判定）
func lookup(key: String) -> String:
	return _font_cache.get(key, "")

# 查 key 的匹配状态；未记录返回 "missing"
func lookup_status(key: String) -> String:
	return _font_status.get(key, "missing")

func find_fonts(fonts: Dictionary, assets_dir: String) -> void:
	# 字体目录
	var fonts_dir = assets_dir + "fonts/"
	var font_dirs = [fonts_dir, "res://fonts/", "res://assets/fonts/"]

	# 确保字体目录存在
	DirAccess.make_dir_recursive_absolute(fonts_dir)

	# 收集项目中所有 .ttf 和 .otf 文件
	var all_fonts: PackedStringArray = []
	for font_dir in font_dirs:
		FigmaImporterUtils._collect_fonts_recursive(font_dir, all_fonts)

	# 为每个需要的字体查找匹配的文件，并记录精确/兜底/缺失状态
	for font_key in fonts:
		var font_info = fonts[font_key]
		var family = font_info.get("family", "")
		var style = font_info.get("style", "")

		# _find_matching_font 含 family 级 fallback，需进一步区分精确匹配与 fallback
		var matched_font = FigmaImporterUtils._find_matching_font(family, style, all_fonts)
		var status := "missing"
		if matched_font:
			status = "exact" if FigmaImporterUtils._is_font_style_match(matched_font, style) else "fallback"
		else:
			# 本地未命中，尝试在线下载（精确 style）
			var downloaded = _download_font_from_google(family, style, fonts_dir)
			if downloaded:
				matched_font = downloaded
				status = "downloaded"
		if matched_font:
			_font_cache[font_key] = matched_font
		_font_status[font_key] = status

	_print_font_report(fonts_dir)

# 打印字体加载汇总：精确/fallback/下载/缺失 计数 + 非精确项明细（warning）
func _print_font_report(fonts_dir: String) -> void:
	var exact := 0
	var fallback := 0
	var downloaded := 0
	var missing := 0
	for k in _font_status:
		match _font_status[k]:
			"exact": exact += 1
			"fallback": fallback += 1
			"downloaded": downloaded += 1
			"missing": missing += 1
	print("[FigmaImporter] 字体: 精确 %d / fallback %d / 下载 %d / 缺失 %d（共 %d）" % [exact, fallback, downloaded, missing, _font_status.size()])
	if fallback == 0 and missing == 0:
		return
	for k in _font_status:
		match _font_status[k]:
			"fallback":
				push_warning("[FigmaImporter] 字体 fallback: %s 未找到精确文件，已用同 family 替代（位置正确，字形可能不一致）→ %s" % [k, _font_cache.get(k, "")])
			"missing":
				push_warning("[FigmaImporter] 字体缺失: %s，未绑定（位置/字形将与 Figma 不一致，请下载 .ttf 到 %s）" % [k, fonts_dir])

func _download_font_from_google(family: String, style: String, target_dir: String) -> String:
	# 构建字体文件名
	var font_filename = "%s-%s.ttf" % [family.replace(" ", ""), style]
	var font_path = target_dir + font_filename

	# 步骤1: 从 Google Fonts CSS API 获取字体文件 URL
	var weight = FigmaImporterUtils._get_weight(style)
	var family_encoded = family.replace(" ", "+")
	var css_url = "https://fonts.googleapis.com/css2?family=%s:wght@%s" % [family_encoded, weight]

	# 使用 HTTPClient 下载 CSS
	var http = HTTPClient.new()
	var err = http.connect_to_host("fonts.googleapis.com", 443, TLSOptions.client())
	if err != OK:
		return ""

	var _deadline := Time.get_ticks_msec() + 3000
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

	_deadline = Time.get_ticks_msec() + 3000
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		http.poll()
		OS.delay_usec(10000)

	# 读取 CSS 响应
	var response_body = PackedByteArray()
	if http.has_response():
		var _body_deadline := Time.get_ticks_msec() + 3000
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

	_deadline = Time.get_ticks_msec() + 3000
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

	_deadline = Time.get_ticks_msec() + 3000
	while font_http.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > _deadline:
			return ""
		font_http.poll()
		OS.delay_usec(10000)

	var font_data = PackedByteArray()
	if font_http.has_response():
		var _body_deadline := Time.get_ticks_msec() + 3000
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
