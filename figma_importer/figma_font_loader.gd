class_name FigmaFontLoader
extends RefCounted

# 字体加载器：本地匹配(.ttf/.otf) + Google Fonts 在线下载，持有 _font_cache。
# 主导入器实例 _fonts 持有；find_fonts() 一次性填充，主文件经 lookup(key) 读取。

var _font_cache: Dictionary = {}  # { "fontFamily_fontWeight": "res://path/to/font.ttf" }

# 按 "family_weight" 键查字体资源路径；未命中返回 ""（供主文件用 != "" 判定）
func lookup(key: String) -> String:
	return _font_cache.get(key, "")

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

	# 为每个需要的字体查找匹配的文件
	for font_key in fonts:
		var font_info = fonts[font_key]
		var family = font_info.get("family", "")
		var style = font_info.get("style", "")

		# 尝试查找匹配的字体文件
		var matched_font = FigmaImporterUtils._find_matching_font(family, style, all_fonts)
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
	var weight = FigmaImporterUtils._get_weight(style)
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
