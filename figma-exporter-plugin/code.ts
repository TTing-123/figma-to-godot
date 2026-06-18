// Figma Exporter for Godot - 核心逻辑
// 运行在 Figma 沙箱中

// 显示 UI
figma.showUI(__html__, { width: 320, height: 240 });

// 监听 UI 消息
figma.ui.onmessage = async (msg) => {
  if (msg.type === 'export') {
    await handleExport();
  }
  if (msg.type === 'cancel') {
    figma.closePlugin();
  }
};

// 主导出函数
async function handleExport() {
  const selection = figma.currentPage.selection;

  if (selection.length === 0) {
    figma.ui.postMessage({
      type: 'error',
      message: '请先选中一个节点'
    });
    return;
  }

  figma.ui.postMessage({
    type: 'progress',
    message: '正在解析节点...',
    percent: 10
  });

  // 解析选中的节点
  const nodes: any[] = [];
  const imageRefs: Map<string, Uint8Array> = new Map();
  const vectorRefs: Map<string, Uint8Array> = new Map();

  for (const node of selection) {
    const parsed = await parseNode(node, imageRefs, vectorRefs);
    if (parsed) {
      nodes.push(parsed);
    }
  }

  figma.ui.postMessage({
    type: 'progress',
    message: '正在导出图片...',
    percent: 50
  });

  // 导出图片资源
  const images: { [key: string]: string } = {};
  for (const [ref, bytes] of imageRefs) {
    const base64 = uint8ArrayToBase64(bytes);
    images[ref] = base64;
  }

  // 导出矢量图形
  const vectors: { [key: string]: string } = {};
  for (const [nodeId, bytes] of vectorRefs) {
    const base64 = uint8ArrayToBase64(bytes);
    vectors[nodeId] = base64;
  }

  figma.ui.postMessage({
    type: 'progress',
    message: '正在打包...',
    percent: 90
  });

  // 构建导出数据
  const exportData = {
    version: '1.0.0',
    exportedAt: new Date().toISOString(),
    figmaFile: figma.fileKey || 'unknown',
    nodes: nodes,
    images: images,
    vectors: vectors
  };

  // 发送到 UI 进行下载
  figma.ui.postMessage({
    type: 'download',
    data: JSON.stringify(exportData, null, 2),
    filename: 'figma_export.json'
  });

  figma.ui.postMessage({
    type: 'progress',
    message: '导出完成！',
    percent: 100
  });
}

// 解析节点
async function parseNode(
  node: SceneNode,
  imageRefs: Map<string, Uint8Array>,
  vectorRefs: Map<string, Uint8Array>
): Promise<any> {
  const base: any = {
    id: node.id,
    name: node.name,
    type: node.type,
    visible: node.visible,
    opacity: 'opacity' in node ? node.opacity : 1,
    x: 'x' in node ? node.x : 0,
    y: 'y' in node ? node.y : 0,
    width: 'width' in node ? node.width : 0,
    height: 'height' in node ? node.height : 0,
  };

  // 获取��对位置
  if ('absoluteTransform' in node) {
    const transform = node.absoluteTransform;
    base.absoluteX = transform[0][2];
    base.absoluteY = transform[1][2];
  }

  // GROUP 特殊处理：Figma Plugin API 返回的 GROUP.x/y/width/height 可能不是
  // UI 显示的真实 bbox（被旋转/变形过的 GROUP 其 transform.translation 不对应
  // bbox.top-left）。用 absoluteRenderBounds 覆盖，让 JSON 中的数据与 Figma UI
  // 显示的 X/Y/W/H 一致。
  if (node.type === 'GROUP' && (node as any).children && (node as any).children.length > 0) {
    const bounds = (node as any).absoluteRenderBounds;
    if (bounds && bounds.width > 0 && bounds.height > 0) {
      base.absoluteX = bounds.x;
      base.absoluteY = bounds.y;
      base.width = bounds.width;
      base.height = bounds.height;
      const parent = (node as any).parent;
      if (parent && parent.type !== 'PAGE' && 'absoluteTransform' in parent) {
        const pt = parent.absoluteTransform;
        base.x = bounds.x - pt[0][2];
        base.y = bounds.y - pt[1][2];
      } else {
        base.x = bounds.x;
        base.y = bounds.y;
      }
    }
  }

  // 处理自动布局
  if ('layoutMode' in node && node.layoutMode !== 'NONE') {
    base.layoutMode = node.layoutMode;
    base.itemSpacing = 'itemSpacing' in node ? node.itemSpacing : 0;
    base.paddingLeft = 'paddingLeft' in node ? node.paddingLeft : 0;
    base.paddingRight = 'paddingRight' in node ? node.paddingRight : 0;
    base.paddingTop = 'paddingTop' in node ? node.paddingTop : 0;
    base.paddingBottom = 'paddingBottom' in node ? node.paddingBottom : 0;
    base.primaryAxisAlignItems = 'primaryAxisAlignItems' in node ? node.primaryAxisAlignItems : 'MIN';
    base.counterAxisAlignItems = 'counterAxisAlignItems' in node ? node.counterAxisAlignItems : 'MIN';
  }

  // 处理圆角
  if ('cornerRadius' in node) {
    base.cornerRadius = node.cornerRadius;
  }
  if ('topLeftRadius' in node) {
    base.topLeftRadius = node.topLeftRadius;
    base.topRightRadius = node.topRightRadius;
    base.bottomLeftRadius = node.bottomLeftRadius;
    base.bottomRightRadius = node.bottomRightRadius;
  }

  // 处理填充
  if ('fills' in node && Array.isArray(node.fills)) {
    base.fills = [];
    for (const fill of node.fills) {
      if (fill.visible === false) continue;
      const fillData: any = { type: fill.type };

      if (fill.type === 'SOLID') {
        fillData.color = {
          r: fill.color.r,
          g: fill.color.g,
          b: fill.color.b,
          a: fill.opacity !== undefined ? fill.opacity : 1
        };
      }

      if (fill.type === 'IMAGE' && 'imageHash' in fill) {
        fillData.imageRef = fill.imageHash;
        // 导出图片
        if (!imageRefs.has(fill.imageHash)) {
          try {
            const bytes = await node.exportAsync({ format: 'PNG', constraint: { type: 'SCALE', value: 2 } });
            imageRefs.set(fill.imageHash, bytes);
          } catch (e) {
            console.error('Failed to export image:', e);
          }
        }
      }

      if (fill.type?.startsWith('GRADIENT_')) {
        fillData.gradientStops = fill.gradientStops?.map((stop: any) => ({
          position: stop.position,
          color: {
            r: stop.color.r,
            g: stop.color.g,
            b: stop.color.b,
            a: stop.color.a
          }
        }));
        fillData.gradientTransform = fill.gradientTransform;
      }

      base.fills.push(fillData);
    }
  }

  // 处理描边
  if ('strokes' in node && Array.isArray(node.strokes)) {
    base.strokes = [];
    for (const stroke of node.strokes) {
      if (stroke.visible === false) continue;
      if (stroke.type === 'SOLID') {
        base.strokes.push({
          type: 'SOLID',
          color: {
            r: stroke.color.r,
            g: stroke.color.g,
            b: stroke.color.b,
            a: stroke.opacity !== undefined ? stroke.opacity : 1
          }
        });
      }
    }
  }

  if ('strokeWeight' in node) {
    base.strokeWeight = typeof node.strokeWeight === 'number' ? node.strokeWeight : 0;
  }

  // 处理效果（阴影等）
  if ('effects' in node && Array.isArray(node.effects)) {
    base.effects = [];
    for (const effect of node.effects) {
      if (effect.visible === false) continue;
      const effectData: any = { type: effect.type };

      if (effect.type === 'DROP_SHADOW' || effect.type === 'INNER_SHADOW') {
        effectData.color = {
          r: effect.color.r,
          g: effect.color.g,
          b: effect.color.b,
          a: effect.color.a
        };
        effectData.offset = effect.offset;
        effectData.radius = effect.radius;
        effectData.spread = effect.spread;
      }

      if (effect.type === 'LAYER_BLUR' || effect.type === 'BACKGROUND_BLUR') {
        effectData.radius = effect.radius;
      }

      base.effects.push(effectData);
    }
  }

  // 处理文本
  if (node.type === 'TEXT') {
    base.characters = node.characters;
    base.style = {
      fontFamily: node.fontName !== figma.mixed ? (node.fontName as FontName).family : '',
      fontWeight: node.fontName !== figma.mixed ? (node.fontName as FontName).style : '',
      fontSize: node.fontSize !== figma.mixed ? node.fontSize : 16,
      lineHeight: node.lineHeight !== figma.mixed ? node.lineHeight : null,
      letterSpacing: node.letterSpacing !== figma.mixed ? node.letterSpacing : null,
      textAlignHorizontal: node.textAlignHorizontal,
      textAlignVertical: node.textAlignVertical,
    };

    // 导出矢量文本为高分辨率 PNG
    try {
      const bytes = await node.exportAsync({ format: 'PNG', constraint: { type: 'SCALE', value: 3 } });
      vectorRefs.set(node.id, bytes);
    } catch (e) {
      console.error('Failed to export text as PNG:', e);
    }
  }

  // 处理矢量节点 - 导出为高分辨率 PNG
  const vectorTypes = ['VECTOR', 'BOOLEAN', 'STAR', 'LINE', 'ELLIPSE', 'REGULAR_POLYGON'];
  if (vectorTypes.includes(node.type)) {
    try {
      // useAbsoluteBounds: false 让 PNG 按 layout bounds (几何 bbox = width/height) 导出，
      // 而非默认的 renderBounds。这样 PNG 尺寸与 figma UI 显示的节点尺寸一致。
      const bytes = await node.exportAsync({
        format: 'PNG',
        constraint: { type: 'SCALE', value: 3 },
        useAbsoluteBounds: false
      } as any);
      vectorRefs.set(node.id, bytes);
    } catch (e) {
      console.error('Failed to export vector as PNG:', e);
    }
  }

  // 处理裁剪
  if ('clipsContent' in node) {
    base.clipsContent = node.clipsContent;
  }

  // 递归处理子节点
  if ('children' in node) {
    base.children = [];
    for (const child of node.children) {
      const parsed = await parseNode(child, imageRefs, vectorRefs);
      if (parsed) {
        base.children.push(parsed);
      }
    }
  }

  return base;
}

// 工具函数：Uint8Array 转 Base64
function uint8ArrayToBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return (globalThis as any).btoa(binary);
}
