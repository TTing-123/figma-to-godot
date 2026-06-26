# Figma to Godot

> ⚠️ **仍在开发中**：本插件处于早期开发阶段，功能与接口可能随时变动，暂不建议用于生产环境。

将 Figma 设计稿转换为 Godot 4.x UI 场景的导入插件。

## 安装

1. 将 `figma_importer/` 目录复制到你的 Godot 项目的 `addons/figma_importer/`
2. 在 Godot 编辑器中启用插件：**Project > Project Settings > Plugins > Figma Importer > Enabled**

## 使用

1. 用 [Figma Exporter Plugin](https://github.com/TTing-123/figma-exporter-plugin) 导出设计稿为 JSON
2. 在 Godot 中：**Project > Tools > Import Figma JSON...**
3. 选择 JSON 文件，场景自动保存到 `scenes/`
4. 运行生成的 `.tscn` 即可预览
