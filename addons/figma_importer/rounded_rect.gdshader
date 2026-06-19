shader_type canvas_item;

uniform float corner_radius : hint_range(0.0, 200.0) = 10.0;
uniform vec2 target_size = vec2(375.0, 812.0);
uniform float parent_corner_radius : hint_range(0.0, 200.0) = 0.0;
uniform vec2 parent_size = vec2(375.0, 812.0);
uniform vec2 offset_in_parent = vec2(0.0, 0.0);
uniform bool use_texture = false;

// SDF 圆角矩形
float rounded_box_sdf(vec2 p, vec2 b, vec4 r) {
	r.xy = (p.x > 0.0) ? r.xy : r.zw;
	r.x = (p.y > 0.0) ? r.x : r.y;
	vec2 q = abs(p) - b + r.x;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

void fragment() {
	// 当前像素在节点中的位置（像素坐标）
	vec2 pixel_pos = UV * target_size;

	// 父节点圆角裁剪（如果父节点有圆角裁剪）
	if (parent_corner_radius > 0.0) {
		vec2 parent_pixel_pos = pixel_pos + offset_in_parent;
		vec2 parent_center = parent_size * 0.5;
		vec2 parent_p = parent_pixel_pos - parent_center;
		float parent_d = rounded_box_sdf(parent_p, parent_size * 0.5, vec4(parent_corner_radius));
		if (parent_d > 0.0) {
			discard;
		}
	}

	// 自身圆角测试
	vec2 center = target_size * 0.5;
	vec2 p = pixel_pos - center;
	vec2 half_size = target_size * 0.5;
	// 当 corner_radius 超过节点尺寸的一半时，限制为 half_size
	// 这样圆角矩形会正确渲染为胶囊形状（平边+圆头，与 Figma 行为一致）
	vec2 clamped_r = min(vec2(corner_radius), half_size);
	float d = rounded_box_sdf(p, half_size, vec4(clamped_r.x, clamped_r.y, clamped_r.x, clamped_r.y));

	if (d > 0.0) {
		discard;
	}

	if (use_texture) {
		// 获取纹理尺寸
		vec2 tex_size = vec2(textureSize(TEXTURE, 0));

		// 计算纹理在节点中的显示区域（居中，保持比例）
		float tex_aspect = tex_size.x / tex_size.y;
		float node_aspect = target_size.x / target_size.y;

		vec2 display_size;
		vec2 display_offset;

		if (tex_aspect > node_aspect) {
			// 纹理更宽，按宽度适配
			display_size.x = target_size.x;
			display_size.y = target_size.x / tex_aspect;
			display_offset = vec2(0.0, (target_size.y - display_size.y) * 0.5);
		} else {
			// 纹理更高，按高度适配
			display_size.y = target_size.y;
			display_size.x = target_size.y * tex_aspect;
			display_offset = vec2((target_size.x - display_size.x) * 0.5, 0.0);
		}

		// 检查当前像素是否在纹理显示区域内
		vec2 local_pos = pixel_pos - display_offset;
		if (local_pos.x >= 0.0 && local_pos.x <= display_size.x &&
			local_pos.y >= 0.0 && local_pos.y <= display_size.y) {
			// 计算纹理UV
			vec2 tex_uv = local_pos / display_size;
			COLOR = texture(TEXTURE, tex_uv);
		} else {
			// 在节点内但不在纹理显示区域（letterbox区域）
			COLOR = vec4(0.0, 0.0, 0.0, 0.0);
		}
	}
	// 否则保留 COLOR（StyleBoxFlat 绘制的内容）
}
