shader_type canvas_item;

uniform float corner_radius : hint_range(0.0, 200.0) = 10.0;
uniform vec4 corner_radiuses = vec4(10.0);  // per-corner: x=br, y=tr, z=bl, w=tl (匹配 rounded_box_sdf)
uniform vec2 target_size = vec2(375.0, 812.0);
uniform float parent_corner_radius : hint_range(0.0, 200.0) = 0.0;
uniform vec2 parent_size = vec2(375.0, 812.0);
uniform vec2 offset_in_parent = vec2(0.0, 0.0);
uniform bool use_texture = false;

// 渐变支持
uniform bool use_gradient = false;
uniform vec4 gradient_color1 : source_color = vec4(1.0);  // 起始颜色
uniform vec4 gradient_color2 : source_color = vec4(1.0);  // 结束颜色
uniform vec2 gradient_start = vec2(0.0);   // 渐变起点（画布坐标）
uniform vec2 gradient_end = vec2(1.0);     // 渐变终点（画布坐标）
uniform vec2 node_pos_in_root = vec2(0.0); // 节点在根画布中的位置

// 描边支持
uniform float border_width = 0.0;
uniform vec4 border_color : source_color = vec4(1.0);

// SDF 圆角矩形
float rounded_box_sdf(vec2 p, vec2 b, vec4 r) {
	r.xy = (p.x > 0.0) ? r.xy : r.zw;
	r.x = (p.y > 0.0) ? r.x : r.y;
	vec2 q = abs(p) - b + r.x;
	return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r.x;
}

// SDF 胶囊（圆角线段）：沿 line_a→line_b 的线段，两端半径为 radius
float capsule_sdf(vec2 p, vec2 line_a, vec2 line_b, float radius) {
	vec2 pa = p - line_a, ba = line_b - line_a;
	float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
	return length(pa - ba * h) - radius;
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

	// 判断是否需要胶囊模式：corner_radius >= 较小的 half_size
	float min_half = min(half_size.x, half_size.y);
	if (corner_radius >= min_half) {
		// 胶囊 SDF：两端圆头 + 中间平边
		// 根据宽高比选择方向：竖向(h>w)用竖线段，横向(w>=h)用横线段
		float d;
		if (half_size.y > half_size.x) {
			// 竖向胶囊：竖线段 + 上下半圆头
			float half_line = half_size.y - min_half;
			d = capsule_sdf(p, vec2(0.0, -half_line), vec2(0.0, half_line), min_half);
		} else {
			// 横向胶囊：横线段 + 左右半圆头
			float half_line_x = max(half_size.x - min_half, 0.0);
			d = capsule_sdf(p, vec2(-half_line_x, 0.0), vec2(half_line_x, 0.0), min_half);
		}
		if (d > 0.0) { discard; }
	} else {
		// 普通圆角矩形 SDF
		float d = rounded_box_sdf(p, half_size, corner_radiuses);
		if (d > 0.0) { discard; }
	}

	// 渐变填充（在画布坐标空间计算，y 轴翻转）
	if (use_gradient) {
		// 节点本地像素 -> 画布 UV (root=375x812)，翻转 y
		vec2 canvas_uv = node_pos_in_root + pixel_pos / vec2(375.0, 812.0);
		canvas_uv.y = 1.0 - canvas_uv.y;
		vec2 gs = vec2(gradient_start.x, 1.0 - gradient_start.y);
		vec2 ge = vec2(gradient_end.x, 1.0 - gradient_end.y);
		vec2 gradient_dir = ge - gs;
		float gradient_len = length(gradient_dir);
		if (gradient_len > 0.001) {
			float t = clamp(dot(canvas_uv - gs, gradient_dir) / (gradient_len * gradient_len), 0.0, 1.0);
			COLOR = mix(gradient_color1, gradient_color2, t);
		} else {
			COLOR = gradient_color1;
		}
	}

	// 描边（在渐变填充之后，纹理之前）
	if (border_width > 0.0) {
		vec2 border_center = target_size * 0.5;
		vec2 border_p = pixel_pos - border_center;
		vec2 border_half = target_size * 0.5;
		float border_d = rounded_box_sdf(border_p, border_half, corner_radiuses);
		if (border_d > -border_width) {
			COLOR = border_color;
		}
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
