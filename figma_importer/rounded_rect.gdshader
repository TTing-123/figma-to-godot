shader_type canvas_item;


uniform float corner_radius : hint_range(0.0, 200.0) = 10.0;
uniform vec4 corner_radiuses = vec4(10.0);  // per-corner: x=br, y=tr, z=bl, w=tl (匹配 rounded_box_sdf)
uniform vec2 target_size = vec2(375.0, 812.0);
uniform float parent_corner_radius : hint_range(0.0, 200.0) = 0.0;
uniform vec2 parent_size = vec2(375.0, 812.0);
uniform vec2 offset_in_parent = vec2(0.0, 0.0);
uniform bool use_texture = false;
uniform int texture_fill_mode = 1;  // 图片填充: 0=FIT(contain留白), 1=FILL(cover裁剪填满, Figma默认)
uniform float tile_scale = 1.0;  // TILE 平铺缩放(Figma scalingFactor)
uniform bool use_image_adjust = false;
uniform float img_exposure = 0.0;  // 图片曝光 (-1..1)
uniform float img_contrast = 0.0;  // 对比度 (-1..1)
uniform float img_saturation = 0.0;  // 饱和度 (-1..1)
uniform float img_temperature = 0.0;  // 色温 (-1..1, +暖-冷)
uniform float img_tint = 0.0;  // 色调 (-1..1, 绿-品红)
uniform float img_highlights = 0.0;  // 高光 (-1..1)
uniform float img_shadows = 0.0;  // 阴影 (-1..1)

// 渐变支持
uniform bool use_gradient = false;
uniform vec4 gradient_color1 : source_color = vec4(1.0);  // 起始颜色
uniform vec4 gradient_color2 : source_color = vec4(1.0);  // 结束颜色
uniform vec2 gradient_start = vec2(0.0);   // 渐变起点
uniform vec2 gradient_end = vec2(1.0);     // 渐变终点
uniform int gradient_type = 0;             // 0=线性, 1=径向, 2=角向, 3=菱形

// 描边支持
uniform float border_width = 0.0;
uniform vec4 border_color : source_color = vec4(1.0);

// 外发光支持（模拟 Figma 的 DROP_SHADOW offset=(0,0) 荧光效果）
uniform bool use_glow = false;
uniform vec4 glow_color : source_color = vec4(1.0);
uniform float glow_radius = 0.0;      // 发光扩散半径（像素）
uniform float glow_intensity = 1.0;   // 发光强度 0~1

// 内阴影（Figma INNER_SHADOW，StyleBoxFlat ��支持，用 SDF 模拟）
uniform bool use_inner_shadow = false;
uniform vec4 inner_shadow_color : source_color = vec4(0.0);
uniform float inner_shadow_blur = 0.0;   // 模糊范围（像素）
uniform vec2 inner_shadow_offset = vec2(0.0);

// 图片节点外阴影（TextureRect 无 panel，用 SDF 在矩形内模拟；朝矩形外的部分会被截断）
uniform bool use_shadow = false;
uniform vec4 shadow_color : source_color = vec4(0.0);
uniform float shadow_size = 0.0;
uniform vec2 shadow_offset = vec2(0.0);

// mask alpha 蒙版（Figma mask 用不规则矢量形状裁剪同层后续兄弟；被遮罩图片挂本 shader 叠加 mask alpha）
uniform bool use_mask = false;
uniform sampler2D mask_texture;
uniform vec2 mask_offset = vec2(0.0);   // mask 形状左上角在当前节点像素空间的偏移
uniform vec2 mask_size = vec2(1.0);     // mask 形状在当前节点像素空间的尺寸

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

	// 计算 SDF 距离（用于圆角裁剪和发光）
	float d;
	// 判断是否需要胶囊模式：corner_radius >= 较小的 half_size
	float min_half = min(half_size.x, half_size.y);
	if (corner_radius >= min_half) {
		// 胶囊 SDF：两端圆头 + 中间平边
		if (half_size.y > half_size.x) {
			float half_line = half_size.y - min_half;
			d = capsule_sdf(p, vec2(0.0, -half_line), vec2(0.0, half_line), min_half);
		} else {
			float half_line_x = max(half_size.x - min_half, 0.0);
			d = capsule_sdf(p, vec2(-half_line_x, 0.0), vec2(half_line_x, 0.0), min_half);
		}
	} else {
		// 普通圆角矩形 SDF
		d = rounded_box_sdf(p, half_size, corner_radiuses);
	}

	// 图片外阴影：在形状外（d>0）按 offset 偏移绘制衰减阴影。
	// 必须在 discard 之前画，并用 keep_for_shadow 标志让后续 discard / 纹理块跳过这些像素。
	bool keep_for_shadow = false;
	if (use_shadow && shadow_size > 0.0 && d > 0.0) {
		vec2 sp = p - shadow_offset;
		float sd = rounded_box_sdf(sp, half_size, corner_radiuses);
		float amt = smoothstep(shadow_size, 0.0, sd);  // sd 从 size→0 衰减
		if (sd > 0.0 && amt > 0.001) {                  // 偏移后形状外才有阴影
			COLOR = vec4(shadow_color.rgb, amt * shadow_color.a);
			keep_for_shadow = true;
		}
	}

	// 外发光（在裁剪之前渲染，允许发光超出节点边界）
	if (use_glow && glow_radius > 0.0) {
		// d < 0 在形状内，d > 0 在形状外
		// 发光范围：从边缘向外 glow_radius 像素
		float glow_factor = 1.0 - smoothstep(0.0, glow_radius, d);
		glow_factor = pow(glow_factor, 2.0);  // 更锐利的衰减
		if (glow_factor > 0.001) {
			COLOR = mix(COLOR, glow_color, glow_factor * glow_intensity * glow_color.a);
		}
		// 如果在形状外部且发光已衰减到 0，丢弃（除非该像素留给阴影）
		if (d > 0.0 && glow_factor <= 0.001 && !keep_for_shadow) {
			discard;
		}
	} else {
		if (d > 0.0 && !keep_for_shadow) { discard; }
	}

	// 渐变��充
	if (use_gradient) {
		vec2 uv = pixel_pos / target_size;
		vec2 gradient_dir = gradient_end - gradient_start;
		float gradient_len = length(gradient_dir);
		if (gradient_type == 2) {
			// 角向（conic）：绕 gradient_start，gradient_end 定 0° 方向
			float base = atan(gradient_dir.y, gradient_dir.x);
			float a = atan(uv.y - gradient_start.y, uv.x - gradient_start.x);
			float t = fract((a - base) / (2.0 * PI) + 1.0);
			COLOR = mix(gradient_color1, gradient_color2, t);
		} else if (gradient_type == 3) {
			// 菱形：到 gradient_start 的曼哈顿距离
			float r = max(gradient_len, 0.001);
			float t = clamp((abs(uv.x - gradient_start.x) + abs(uv.y - gradient_start.y)) / r, 0.0, 1.0);
			COLOR = mix(gradient_color1, gradient_color2, t);
		} else if (gradient_type == 1) {
			// 径向渐变：gradient_start 为圆心，半径 = |gradient_end - gradient_start|
			float r = max(gradient_len, 0.001);
			float t = clamp(distance(uv, gradient_start) / r, 0.0, 1.0);
			COLOR = mix(gradient_color1, gradient_color2, t);
		} else if (gradient_len > 0.001) {
			// ��性渐变
			float t = clamp(dot(uv - gradient_start, gradient_dir) / (gradient_len * gradient_len), 0.0, 1.0);
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
		if (border_d > -border_width && border_d <= 0.0) {
			COLOR = border_color;
		}
	}

	if (use_texture && !keep_for_shadow) {
		// 获取纹理尺寸
		vec2 tex_size = vec2(textureSize(TEXTURE, 0));
		float tex_aspect = tex_size.x / tex_size.y;
		float node_aspect = target_size.x / target_size.y;
	
		if (texture_fill_mode == 0) {
			// FIT (contain)：等比适配，留白透明
			vec2 display_size;
			vec2 display_offset;
			if (tex_aspect > node_aspect) {
				display_size = vec2(target_size.x, target_size.x / tex_aspect);
				display_offset = vec2(0.0, (target_size.y - display_size.y) * 0.5);
			} else {
				display_size = vec2(target_size.y * tex_aspect, target_size.y);
				display_offset = vec2((target_size.x - display_size.x) * 0.5, 0.0);
			}
			vec2 local_pos = pixel_pos - display_offset;
			if (local_pos.x >= 0.0 && local_pos.x <= display_size.x &&
				local_pos.y >= 0.0 && local_pos.y <= display_size.y) {
				COLOR = texture(TEXTURE, local_pos / display_size);
			} else {
				COLOR = vec4(0.0, 0.0, 0.0, 0.0);
			}
		} else if (texture_fill_mode == 2) {
			// TILE 平铺：图片按 tile_scale 缩放后重复铺满节点
			vec2 tile_pix = tex_size * tile_scale;
			vec2 tile_uv = fract(pixel_pos / tile_pix);
			COLOR = texture(TEXTURE, tile_uv);
		} else {
			// FILL (cover)：裁剪填满整个节点（Figma IMAGE fill 默认）
			vec2 tex_uv;
			if (tex_aspect > node_aspect) {
				float c = node_aspect / tex_aspect;
				tex_uv = vec2((1.0 - c) * 0.5 + UV.x * c, UV.y);
			} else {
				float c = tex_aspect / node_aspect;
				tex_uv = vec2(UV.x, (1.0 - c) * 0.5 + UV.y * c);
			}
			COLOR = texture(TEXTURE, tex_uv);
		}
	}
	// 图片色彩调整 (Figma ImageFilters，值 -1..1)
	if (use_image_adjust) {
		vec3 c = COLOR.rgb;
		c *= pow(2.0, img_exposure);
		c = (c - 0.5) * (1.0 + img_contrast) + 0.5;
		float gray = dot(c, vec3(0.299, 0.587, 0.114));
		c = mix(vec3(gray), c, clamp(1.0 + img_saturation, 0.0, 2.0));
		c.r += img_temperature * 0.12; c.b -= img_temperature * 0.12;
		c.r += img_tint * 0.06; c.b += img_tint * 0.06; c.g -= img_tint * 0.12;
		float lum = dot(c, vec3(0.299, 0.587, 0.114));
		// 高光/阴影用乘法 gain（按比例），避免加法偏移把暗部 clamp 成死黑
		c *= 1.0 + img_highlights * smoothstep(0.5, 1.0, lum) * 0.5;
		float shadowMask = 1.0 - smoothstep(0.4, 0.7, lum);
		c *= 1.0 + img_shadows * shadowMask;
		COLOR.rgb = clamp(c, 0.0, 1.0);
	}
	// 内阴影（移至纹理/色彩调整之后，确保叠加在图片之上；仅在形状内 d<0 绘制）
	if (use_inner_shadow && d < 0.0) {
		vec2 isp = p - inner_shadow_offset;
		float id = rounded_box_sdf(isp, half_size, corner_radiuses);
		float w = max(inner_shadow_blur, 0.001);
		float amt = smoothstep(-w, 0.0, id);
		COLOR = mix(COLOR, inner_shadow_color, amt * inner_shadow_color.a);
	}

	// 否则保留 COLOR（StyleBoxFlat 绘制的内容）

	// mask alpha 蒙版：纹理/填充确定 COLOR 后，用 mask 形状 alpha 裁剪（形状外 alpha=0）
	if (use_mask) {
		vec2 muv = (pixel_pos - mask_offset) / mask_size;
		if (muv.x >= 0.0 && muv.x <= 1.0 && muv.y >= 0.0 && muv.y <= 1.0) {
			COLOR.a *= texture(mask_texture, muv).a;
		} else {
			COLOR.a = 0.0;
		}
	}
}
