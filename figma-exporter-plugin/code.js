"use strict";
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
    absPosMap.clear();
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
    const nodes = [];
    const imageRefs = new Map();
    const vectorRefs = new Map();
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
    const images = {};
    for (const [ref, bytes] of imageRefs) {
        const base64 = uint8ArrayToBase64(bytes);
        images[ref] = base64;
    }
    // 导出矢量图形
    const vectors = {};
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
// absPosMap: 存储每个节点修正后的绝对位置
const absPosMap = new Map();
async function parseNode(node, imageRefs, vectorRefs) {
    var _a, _b;
    const base = {
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
    // 保存原始 Figma API 的 x/y
    const origX = base.x;
    const origY = base.y;
    // 获取绝对位置：优先用 absoluteBoundingBox（画布坐标），它对 GROUP 节点也正确
    // absoluteTransform 对 GROUP 有 bug（返回错误的 y 值）
    if ('absoluteBoundingBox' in node && node.absoluteBoundingBox) {
        const bbox = node.absoluteBoundingBox;
        base.absoluteX = bbox.x;
        base.absoluteY = bbox.y;
        // 用 absoluteBoundingBox 的尺寸覆盖（更准确）
        base.width = bbox.width;
        base.height = bbox.height;
    } else if ('absoluteTransform' in node) {
        const transform = node.absoluteTransform;
        base.absoluteX = transform[0][2];
        base.absoluteY = transform[1][2];
    }
    // 安全检查：如果无法获取绝对位置，用原始 x/y 作为后备
    if (base.absoluteX === undefined || base.absoluteY === undefined) {
        base.absoluteX = base.x;
        base.absoluteY = base.y;
    }
    // 缓存绝对位置
    absPosMap.set(node.id, { x: base.absoluteX, y: base.absoluteY });
    // 计算相对父节点的偏移
    {
        const parent = node.parent;
        if (parent && parent.type !== 'PAGE') {
            const parentAbs = absPosMap.get(parent.id);
            if (parentAbs) {
                base.x = base.absoluteX - parentAbs.x;
                base.y = base.absoluteY - parentAbs.y;
            } else if ('absoluteBoundingBox' in parent && parent.absoluteBoundingBox) {
                base.x = base.absoluteX - parent.absoluteBoundingBox.x;
                base.y = base.absoluteY - parent.absoluteBoundingBox.y;
            } else if ('absoluteTransform' in parent) {
                base.x = base.absoluteX - parent.absoluteTransform[0][2];
                base.y = base.absoluteY - parent.absoluteTransform[1][2];
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
            if (fill.visible === false)
                continue;
            const fillData = { type: fill.type };
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
                    }
                    catch (e) {
                        console.error('Failed to export image:', e);
                    }
                }
            }
            if ((_a = fill.type) === null || _a === void 0 ? void 0 : _a.startsWith('GRADIENT_')) {
                fillData.gradientStops = (_b = fill.gradientStops) === null || _b === void 0 ? void 0 : _b.map((stop) => ({
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
            if (stroke.visible === false)
                continue;
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
            if (effect.visible === false)
                continue;
            const effectData = { type: effect.type };
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
            fontFamily: node.fontName !== figma.mixed ? node.fontName.family : '',
            fontWeight: node.fontName !== figma.mixed ? node.fontName.style : '',
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
        }
        catch (e) {
            console.error('Failed to export text as PNG:', e);
        }
    }
    // 处理矢量节点 - 导出为高分辨率 PNG
    const vectorTypes = ['VECTOR', 'BOOLEAN', 'STAR', 'LINE', 'ELLIPSE', 'REGULAR_POLYGON'];
    if (vectorTypes.includes(node.type)) {
        try {
            // 对有描边的线条节点使用 render bounds（包含描边区域），
            // 其他节点使用 layout bounds（与 Figma UI 显示尺寸一致）。
            const hasStroke = node.type === 'VECTOR' && 'strokeWeight' in node && node.strokeWeight > 0;
            const bytes = await node.exportAsync({
                format: 'PNG',
                constraint: { type: 'SCALE', value: 3 },
                useAbsoluteBounds: !hasStroke
            });
            vectorRefs.set(node.id, bytes);
            // 对有描边的线条节点：用 render bounds 的实际尺寸覆盖
            // （useAbsoluteBounds=false 时 absoluteBoundingBox 包含描边区域）
            if (hasStroke && 'absoluteRenderBounds' in node && node.absoluteRenderBounds) {
                const rb = node.absoluteRenderBounds;
                // render bounds 给出包含描边的实际像素尺寸
                base.width = rb.width;
                base.height = rb.height;
            } else if (hasStroke) {
                // 后备：用 strokeWeight 补偿
                if (base.height === 0 && base.width > 0) {
                    base.height = node.strokeWeight;
                } else if (base.width === 0 && base.height > 0) {
                    base.width = node.strokeWeight;
                }
            }
        }
        catch (e) {
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
function uint8ArrayToBase64(bytes) {
    let binary = '';
    for (let i = 0; i < bytes.length; i++) {
        binary += String.fromCharCode(bytes[i]);
    }
    return globalThis.btoa(binary);
}
