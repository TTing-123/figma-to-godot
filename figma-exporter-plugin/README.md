# Figma Exporter for Godot

极简的 Figma 导出插件，用于将设计导出为 JSON + 图片资源，供 Godot 导入使用。

## 安装方法

### 方法 1：本地开发模式

1. 打开 Figma 桌面版
2. 菜单 → Plugins → Development → Import plugin from manifest
3. 选择此目录中的 `manifest.json` 文件
4. 插件会出现在 Plugins → Development 菜单中

### 方法 2：发布到 Figma 社区

1. 在 Figma 中打开插件管理页面
2. 点击 "Publish to Community"
3. 填写插件信息并提交审核

## 使用方法

1. 在 Figma 中选中要导出的节点（Frame、Group 等）
2. 打开插件：Plugins → Development → Export for Godot
3. 点击 "Export" 按钮
4. 保存生成的 `figma_export.json` 文件

## 导出内容

```json
{
  "version": "1.0.0",
  "exportedAt": "2024-01-01T00:00:00.000Z",
  "figmaFile": "file_key",
  "nodes": [
    {
      "id": "1:2",
      "name": "Frame",
      "type": "FRAME",
      "x": 0,
      "y": 0,
      "width": 375,
      "height": 812,
      "fills": [...],
      "children": [...]
    }
  ],
  "images": {
    "image_hash": "base64_encoded_png"
  },
  "vectors": {
    "node_id": "base64_encoded_svg"
  }
}
```

## 文件结构

```
figma-exporter-plugin/
├── manifest.json    # 插件配置
├── code.js          # 主逻辑（Figma 沙箱）
├── code.ts          # TypeScript 源码（可选）
├── ui.html          # UI 界面
├── package.json     # 依赖配置
├── tsconfig.json    # TypeScript 配置
└── README.md        # 说明文档
}
```

## 开发

如果需要修改代码：

```bash
# 安装依赖（可选，如果使用 TypeScript）
npm install

# 编译 TypeScript（可选）
npm run build
```

## 许可证

MIT
