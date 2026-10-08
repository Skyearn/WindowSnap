#!/usr/bin/env swift
//
// 生成 App 图标。形状直接按菜单栏那个图标（rectangle.3.group）量出来的比例画，
// 保证 App 图标和菜单栏图标是同一套形状语言。
//
// 注意：这里是自己用 CoreGraphics 画矩形，没有直接使用 SF Symbol 位图
//（苹果的 SF Symbols 许可不允许把它用在 App 图标 / Logo 上）。
//
// 用法：swift scripts/make_icon.swift
//
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - 形状

/// 三块窗口的归一化位置。坐标系：左上角原点，y 向下。
/// 数值是把菜单栏图标渲染成位图后逐像素量出来的。
private let glyphRects: [(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat)] = [
    (0.000, 0.000, 0.486, 0.447),   // 左上
    (0.081, 0.605, 0.459, 0.395),   // 左下
    (0.622, 0.053, 0.378, 0.921)    // 右侧通高
]

/// macOS 图标网格：圆角矩形占画布约 80.5%，圆角半径约画布的 18.1%
private let contentInsetRatio: CGFloat = 0.0985
private let cornerRadiusRatio: CGFloat = 0.181
/// 字形占画布的比例
private let glyphBoxRatio: CGFloat = 0.44
/// 线宽（相对字形框）
private let strokeRatio: CGFloat = 0.058

private let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
private let iconset = root.appendingPathComponent("build/AppIcon.iconset", isDirectory: true)

private func drawIcon(size: Int) -> CGImage? {
    let s = CGFloat(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil,
                              width: size,
                              height: size,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // 背景：蓝色渐变圆角矩形
    let inset = s * contentInsetRatio
    let background = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let backgroundPath = CGPath(roundedRect: background,
                                cornerWidth: s * cornerRadiusRatio,
                                cornerHeight: s * cornerRadiusRatio,
                                transform: nil)

    ctx.saveGState()
    ctx.addPath(backgroundPath)
    ctx.clip()
    let colors = [
        CGColor(red: 0.42, green: 0.60, blue: 0.99, alpha: 1.0),
        CGColor(red: 0.16, green: 0.31, blue: 0.90, alpha: 1.0)
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: background.minX, y: background.maxY),
                               end: CGPoint(x: background.maxX, y: background.minY),
                               options: [])
    }
    ctx.restoreGState()

    // 字形
    let boxSide = s * glyphBoxRatio
    let box = CGRect(x: (s - boxSide) / 2, y: (s - boxSide) / 2, width: boxSide, height: boxSide)
    // 小尺寸下线条会细到看不见，给一个下限（相当于 SF Symbols 的光学补偿）
    let stroke = max(boxSide * strokeRatio, max(1.3, s * 0.021))
    let radius = boxSide * 0.055

    ctx.setLineJoin(.round)
    for rect in glyphRects {
        // 归一化坐标 -> 画布坐标（y 向下翻成 y 向上）
        var r = CGRect(x: box.minX + rect.x * box.width,
                       y: box.minY + (1 - rect.y - rect.height) * box.height,
                       width: rect.width * box.width,
                       height: rect.height * box.height)
        // 量出来的外沿是含线宽的，这里内缩半个线宽，做成居中描边
        r = r.insetBy(dx: stroke / 2, dy: stroke / 2)
        let corner = min(radius, r.height / 2, r.width / 2)
        let path = CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil)

        // 淡填充：让字形在深色背景上更有分量
        ctx.addPath(path)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.fillPath()
        // 白色描边
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setLineWidth(stroke)
        ctx.strokePath()
    }

    return ctx.makeImage()
}

private func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                            UTType.png.identifier as CFString,
                                                            1, nil) else {
        throw NSError(domain: "icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "icon", code: 2)
    }
}

// MARK: - 主流程

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for variant in variants {
    guard let image = drawIcon(size: variant.pixels) else {
        FileHandle.standardError.write("画不出 \(variant.name)\n".data(using: .utf8) ?? Data())
        exit(1)
    }
    try write(image, to: iconset.appendingPathComponent(variant.name))
}

print("图标已生成：\(iconset.path)")
