# 轻缓存图标

生成方式：内置 image_gen，2026-09-11。原始 PNG 保留透明背景；使用 sips 缩放、iconutil 打包为 macOS ICNS。

## 最终提示词

Use case: logo-brand. Create one original, polished macOS application icon for a Chinese utility named 轻缓存 (Light Cache), a quiet Mac memory and automated-browser cleanup companion. No text, no lettering. A single bold flowing leaf/breeze emblem with a subtle negative-space cut that suggests clearing space and lightness, instantly legible at 32 pixels. Warm ivory emblem on a deep forest-teal rounded-square tile, colors around #216E5C with very subtle mint highlights. Restrained premium native macOS feel, gently dimensional, precise smooth curves, balanced optical center, simple silhouette, no decorative particles, no literal broom, no computer, no recycling arrows, no badges. Square 1024x1024 canvas. The icon tile occupies approximately 88% of the canvas, with consistent generous transparent margins and actual transparent pixels outside its rounded corners. Front-facing, centered, orthographic, no perspective, no external cast shadow, no mockup, no background scene. Produce the finished app icon artwork as a clean high resolution PNG suitable for an .icns file.

## 文件

- Logo-master.png：生成原图（实际 1254 × 1254，含透明通道）。
- AppIcon.icns：16–1024 像素的 macOS 图标集。
- BrandIcon.png：应用窗口使用的 256 像素标志。
- 重建：在项目目录执行 `zsh build.sh`，图标将自动重新打包。
