class_name FigmaTscnWriter
extends RefCounted

# tscn 输出缓冲区 + 资源 id 分配 + 序列化。
# 主导入器持有其实例 _writer，通过 add_sub_resource/add_ext_resource 追加内容。
# 关键不变性：add_* 内部「分配 id + append」原子执行，调用点顺序即 id 分配顺序，
# 故 ExtResource/SubResource 的 id 序列与原实现逐字节一致（load_steps = counter + 2）。

var _resource_id_counter: int = 0
var _ext_resources: Array[Dictionary] = []
var _sub_resources: Array[Dictionary] = []
var _nodes: PackedStringArray = []
var _name_counter: Dictionary = {}

func reset() -> void:
	_resource_id_counter = 0
	_ext_resources.clear()
	_sub_resources.clear()
	_nodes.clear()
	_name_counter.clear()

func next_resource_id() -> int:
	_resource_id_counter += 1
	return _resource_id_counter

func unique_name(p_name: String, parent_path: String) -> String:
	var key = "%s/%s" % [parent_path, p_name]
	if not _name_counter.has(key):
		_name_counter[key] = 0
		return p_name
	_name_counter[key] += 1
	return "%s_%d" % [p_name, _name_counter[key]]

# 追加外部资源（图片/字体纹理），返回分配的 id
func add_ext_resource(type: String, path: String) -> int:
	var id := next_resource_id()
	_ext_resources.append({
		"id": id,
		"type": type,
		"path": path,
	})
	return id

# 追加子资源（StyleBoxFlat / ShaderMaterial），返回��配的 id
func add_sub_resource(type: String, properties: Dictionary) -> int:
	var id := next_resource_id()
	_sub_resources.append({
		"id": id,
		"type": type,
		"properties": properties,
	})
	return id

func add_node_line(line: String) -> void:
	_nodes.append(line)

# 返回内部 sub_resources 数组引用（非副本），供回读改写（如 _apply_drop_shadow 合并阴影到已建 StyleBox）
func get_sub_resources() -> Array[Dictionary]:
	return _sub_resources

# 序列化为完整 .tscn 文本：header(load_steps) + 固定 Shader ext + 各 ext/sub_resource + 节点行
func serialize() -> String:
	var content = "[gd_scene load_steps=%d format=3]\n\n" % (_resource_id_counter + 2)
	content += '[ext_resource type="Shader" path="res://addons/figma_importer/rounded_rect.gdshader" id="shader_rounded"]\n'
	for ext_res in _ext_resources:
		content += '[ext_resource type="%s" path="%s" id="%d"]\n' % [ext_res["type"], ext_res["path"], ext_res["id"]]
	content += "\n"
	for sub_res in _sub_resources:
		content += FigmaImporterUtils._format_sub_resource(sub_res)
	for node_line in _nodes:
		content += node_line
	return content
