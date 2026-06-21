# Figma to Godot

将 Figma 设计稿转换为 Godot 4.x UI 场景的导入插件。

## 安装

1. 将 `figma_importer/` 目录复制到你的 Godot 项目的 `addons/figma_importer/`
2. 在 Godot 编辑器中启用插件：**Project > Project Settings > Plugins > Figma Importer > Enabled**

## 使用方法

### 1. 从 Figma 导出 JSON

使用 [Figma Plugin API](https://www.figma.com/plugin-docs/) 编写导出插件，将设计稿导出为 JSON 格式。

JSON 文件需要包含：
- `nodes` — 选中节点的树形结构
- `images` — 图片资源的 Base64 数据
- `vectors` — 矢量资源的 Base64 PNG 数据

### 2. 在 Godot 中导入

1. 打开 Godot 编辑器
2. 菜单栏 **Project > Tools > Import Figma JSON...**
3. 选择导出的 JSON 文件
4. 场景文件将自动保存到 `scenes/` 目录

### 3. 运行场景

直接运行生成的 `.tscn` 场景文件即可预览 UI。

## 支持的功能

- Frame / Group / Component → Control
- Vector / Boolean → TextureRect（SVG 转 PNG）
- Text → Label（保留字体大小、颜色、对齐）
- Rectangle / Ellipse → Panel（纯色填充）
- Auto Layout → 绝对定位（计算后的坐标）
- 圆角矩形 → Shader 实现（SDF 圆角）
- 渐变填充 → Shader 实现
- 描边 → Shader 实现
- 阴影效果 → StyleBoxFlat
- 外发光效果 → Shader SDF 发光
- 裁剪 → clip_contents
- 透明度 → modulate

## Shader 特性

插件使用自定义 `rounded_rect.gdshader`，支持：
- 四角独立圆角
- 父节点圆角裁剪
- 渐变填充
- 描边
- 外发光（SDF）
- 胶囊形状

## 项目结构

```
figma_importer/
├── figma_importer_plugin.gd    # 编辑器插件入口
├── figma_local_importer.gd     # 核心导入逻辑
├── plugin.cfg                  # 插件配置
└── rounded_rect.gdshader       # 圆角/发光/渐变 Shader
```

## 注意事项

- Figma 中的 Auto Layout 子节点坐标已由 Figma 计算，导入器直接使用
- 负间距（itemSpacing < 0）会被修正为 0，避免子节点重叠
- SVG 容器中的子节点会自动居中（修正 Figma API 坐标偏差）
- 荧光效果（DROP_SHADOW offset=0,0）会传递给最近的 VECTOR 子节点

## 许可证

MIT
