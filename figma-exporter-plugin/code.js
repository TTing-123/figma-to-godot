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
    // 保存原始 Figma API 的 x/y（后面会被 absoluteRenderBounds 重算）
    const origX = base.x;
    const origY = base.y;
    // 获取绝对位置
    if ('absoluteTransform' in node) {
        const transform = node.absoluteTransform;
        base.absoluteX = transform[0][2];
        base.absoluteY = transform[1][2];
    }
    // GROUP 节点修正：Figma API 的 absoluteTransform 对 GROUP 有 bug。
    // 所有 GROUP 节点统一用：absoluteY = node.y + FRAME.absoluteY
    // node.y 始终是从父节点顶部算起的偏移。
    if (node.type === 'GROUP') {
        let frameAncestor = null;
        let p = node.parent;
        while (p && p.type !== 'PAGE') {
            if (p.type === 'FRAME' || p.type === 'COMPONENT' || p.type === 'COMPONENT_SET') {
                frameAncestor = p;
                break;
            }
            p = p.parent;
        }
        if (frameAncestor) {
            const frameAbs = absPosMap.get(frameAncestor.id);
            if (frameAbs) {
                // 保存原始 node.x（相对于 FRAME 祖先），子节点需要用它计算相对偏移
                base._origNodeX = base.x;
                base._origNodeY = base.y;
                base.absoluteX = base.x + frameAbs.x;
                base.absoluteY = base.y + frameAbs.y;
            }
        }
    }
    // GROUP 子节点修正：node.x/y 相对于 FRAME 祖先，需要减去 GROUP 的 node.x 得到相对于 GROUP 的偏移
    try {
        if (node.parent && node.parent.type === 'GROUP') {
            const parentAbs = absPosMap.get(node.parent.id);
            if (parentAbs && node.parent._origNodeX !== undefined) {
                // origX 是相对于 FRAME 祖先的，减去 GROUP 的 node.x 得到相对于 GROUP 的偏移
                base.x = origX - node.parent._origNodeX;
                base.y = origY - node.parent._origNodeY;
                base.absoluteX = base.x + parentAbs.x;
                base.absoluteY = base.y + parentAbs.y;
            } else if (parentAbs) {
                base.absoluteX = origX + parentAbs.x;
                base.absoluteY = origY + parentAbs.y;
            }
        }
    } catch(e) {
        // 忽略
    }
    // 缓存修正后的位置
    absPosMap.set(node.id, { x: base.absoluteX, y: base.absoluteY });
    // 从修正后的绝对坐标重新计算相对父节点的 x/y
    {
        const parent = node.parent;
        if (parent && parent.type !== 'PAGE') {
            const parentAbs = absPosMap.get(parent.id);
            if (parentAbs) {
                base.x = base.absoluteX - parentAbs.x;
                base.y = base.absoluteY - parentAbs.y;
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
            // useAbsoluteBounds: true 使用节点的 layout bounds（与 Figma UI 显示尺寸一致），
            // 而非默认的 render bounds（包含描边等额外区域）。
            const bytes = await node.exportAsync({
                format: 'PNG',
                constraint: { type: 'SCALE', value: 3 },
                useAbsoluteBounds: true
            });
            vectorRefs.set(node.id, bytes);
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
