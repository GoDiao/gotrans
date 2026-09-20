#!/usr/bin/env swift
// 把任意素材（文生图输出、插画、截图）合成为符合 macOS 规范的 1024×1024 图标母图。
//
//   Scripts/finish-icon.swift <素材图> <输出.png> [背景色 #RRGGBB]
//
// 素材不需要透明背景、不需要正方形、不需要留边距——脚本负责：
//   1. 居中裁成正方形，缩放到 764×764
//   2. 套上 macOS 的 squircle（连续曲率圆角，非普通圆弧）
//   3. 在下方加投影
//   4. 输出 1024×1024、带 alpha 的母图
//
// 几何与本项目现有图标一致：主体 764×764，左右边距各 130，上边距 108，投影向下约 31。
// 给了背景色就先铺底再贴素材，适合素材本身带透明或比例不对的情况。
//
// 产出的母图交给 Scripts/make-icon.sh 生成资产目录需要的 10 个尺寸。
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let bodySize: CGFloat = 764
let topInset: CGFloat = 108
// macOS 图标规范在 1024 画布上主体 824、圆角半径 185.4；按本项目主体尺寸等比缩放。
let bodyCornerRadius: CGFloat = 185.4 * (bodySize / 824)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    fail("""
    用法: \(args[0]) <素材图> <输出.png> [选项]

    选项：
      --bg '#RRGGBB'   主体底色。素材是透明背景的标志时必须给，否则圆角方块是透明的，
                       最终只看得到那个标志悬空，图标造型不可见。
      --fit            等比缩放到完整放入，不裁切。素材是悬浮标志、或者内容顶到画布边缘
                       时用这个。默认是 --fill（居中裁切铺满），适合整幅构图的素材。
      --inset <0-0.4>  仅 --fit 有效，主体四周留白比例，默认 0.12。
    """)
}
let sourceURL = URL(fileURLWithPath: args[1])
let outputURL = URL(fileURLWithPath: args[2])

guard let artwork = NSImage(contentsOf: sourceURL) else {
    fail("❌ 读不出素材图：\(sourceURL.path)")
}

func parseHex(_ raw: String) -> Color {
    let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else {
        fail("❌ 颜色要写成 #RRGGBB，收到：\(raw)")
    }
    return Color(
        .sRGB,
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255)
}

var background = Color.clear
var useFit = false
var inset = 0.12
var i = 3
while i < args.count {
    switch args[i] {
    case "--bg":
        guard i + 1 < args.count else { fail("❌ --bg 后面要跟颜色") }
        background = parseHex(args[i + 1]); i += 2
    case "--fit":
        useFit = true; i += 1
    case "--fill":
        useFit = false; i += 1
    case "--inset":
        guard i + 1 < args.count, let v = Double(args[i + 1]), v >= 0, v <= 0.4 else {
            fail("❌ --inset 要跟 0 到 0.4 之间的小数")
        }
        inset = v; i += 2
    default:
        fail("❌ 不认识的选项：\(args[i])")
    }
}

struct IconCanvas: View {
    let artwork: NSImage
    let background: Color
    let useFit: Bool
    let inset: Double

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            ZStack {
                background
                // fill 是居中裁切铺满；fit 是完整放入并留白。两者都保持原始比例，不拉伸。
                Image(nsImage: artwork)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: useFit ? .fit : .fill)
                    .padding(useFit ? bodySize * inset : 0)
            }
            .frame(width: bodySize, height: bodySize)
            .clipShape(RoundedRectangle(cornerRadius: bodyCornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.30), radius: 8, x: 0, y: 14)
            .padding(.top, topInset)
        }
        .frame(width: canvas, height: canvas)
    }
}

MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: IconCanvas(artwork: artwork, background: background, useFit: useFit, inset: inset))
    renderer.scale = 1
    guard let cgImage = renderer.cgImage else {
        fail("❌ 渲染失败")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: canvas, height: canvas)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("❌ PNG 编码失败")
    }
    do {
        try data.write(to: outputURL)
    } catch {
        fail("❌ 写入失败：\(error.localizedDescription)")
    }
    print("==> 母图已生成 \(Int(canvas))×\(Int(canvas))：\(outputURL.path)")
    print("    下一步：Scripts/make-icon.sh \(outputURL.path)")
}
