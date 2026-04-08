#!/usr/bin/env python3
"""
ChimeraDarwin19.x ????????
? SVG ????? PNG ? ICO ??

??:
    pip install cairosvg pillow

????:
    ???????????????????????????
    ?? ChimeraDarwin19.x ?????
"""

import os
import sys
from pathlib import Path

# ????????????
try:
    import cairosvg
    HAS_CAIRO = True
except ImportError:
    HAS_CAIRO = False
    print("??: cairosvg ????SVG ???????")
    print("????: pip install cairosvg")

try:
    from PIL import Image
    HAS_PILLOW = True
except ImportError:
    HAS_PILLOW = False
    print("??: pillow ???????????")
    print("????: pip install pillow")


def svg_to_png(svg_path: str, png_path: str, scale: float = 1.0) -> bool:
    """? SVG ????? PNG"""
    if not HAS_CAIRO:
        # ???? cairosvg?????????
        if HAS_PILLOW:
            _create_placeholder_png(png_path, scale)
        return False
    
    try:
        with open(svg_path, 'r') as f:
            svg_content = f.read()
        
        # ?? SVG ????
        width = height = 16
        if 'width="' in svg_content:
            w = svg_content.split('width="')[1].split('"')[0]
            width = int(w.replace('px', ''))
        if 'height="' in svg_content:
            h = svg_content.split('height="')[1].split('"')[0]
            height = int(h.replace('px', ''))
        
        cairosvg.svg2png(
            url=svg_path,
            write_to=png_path,
            output_width=int(width * scale),
            output_height=int(height * scale)
        )
        print(f"??: {png_path}")
        return True
    except Exception as e:
        print(f"???? {svg_path}: {e}")
        if HAS_PILLOW:
            _create_placeholder_png(png_path, scale)
        return False


def _create_placeholder_png(png_path: str, scale: float):
    """???????? PNG"""
    if not HAS_PILLOW:
        return
    
    try:
        size = int(16 * scale)
        img = Image.new('RGBA', (size, size), (100, 100, 100, 255))
        img.save(png_path)
        print(f"?????: {png_path}")
    except Exception as e:
        print(f"???????: {e}")


def create_ico_from_png(png_paths: list, ico_path: str) -> bool:
    """??? PNG ?? ICO ??"""
    if not HAS_PILLOW:
        print("?? pillow ???? ICO ??")
        return False
    
    try:
        images = []
        for png_path in png_paths:
            if os.path.exists(png_path):
                img = Image.open(png_path)
                if img.mode != 'RGBA':
                    img = img.convert('RGBA')
                images.append(img)
        
        if images:
            # ??? ICO (????????????)
            images[0].save(
                ico_path,
                format='ICO',
                sizes=[(img.width, img.height) for img in images[:5]]
            )
            print(f"??: {ico_path}")
            return True
    except Exception as e:
        print(f"?? ICO ??: {e}")
    return False


def create_wallpaper_gradient(
    output_path: str,
    width: int = 1920,
    height: int = 1080,
    colors: list = None,
    direction: str = 'vertical'
) -> bool:
    """??????"""
    if not HAS_PILLOW:
        print("?? pillow ??????")
        return False
    
    if colors is None:
        colors = [
            (30, 5, 51),     # ??: ??
            (58, 27, 108),   # ??: ??
            (100, 60, 150)   # ??: ??
        ]
    
    try:
        img = Image.new('RGB', (width, height))
        pixels = img.load()
        
        if direction == 'vertical':
            mid1 = height // 3
            mid2 = 2 * height // 3
            
            for y in range(height):
                if y < mid1:
                    # ?????
                    t = y / mid1
                    r = int(colors[0][0] * (1-t) + colors[1][0] * t)
                    g = int(colors[0][1] * (1-t) + colors[1][1] * t)
                    b = int(colors[0][2] * (1-t) + colors[1][2] * t)
                else:
                    # ?????
                    t = (y - mid1) / (height - mid1)
                    r = int(colors[1][0] * (1-t) + colors[2][0] * t)
                    g = int(colors[1][1] * (1-t) + colors[2][1] * t)
                    b = int(colors[1][2] * (1-t) + colors[2][2] * t)
                
                for x in range(width):
                    pixels[x, y] = (r, g, b)
        
        img.save(output_path)
        print(f"????: {output_path}")
        return True
    except Exception as e:
        print(f"??????: {e}")
        return False


def main():
    """???"""
    base_dir = Path(__file__).parent.parent
    assets_dir = base_dir / "assets"
    
    # ??????
    for subdir in ['icons/dock', 'icons/menu', 'icons/window', 'icons/status', 'cursors', 'wallpapers']:
        (assets_dir / subdir).mkdir(parents=True, exist_ok=True)
    
    print("=" * 50)
    print("ChimeraDarwin19.x ???????")
    print("=" * 50)
    
    # ?? SVG ? PNG
    print("\n[1] ?? SVG ??? PNG...")
    svg_count = 0
    png_count = 0
    
    for category in ['dock', 'menu', 'window', 'status']:
        svg_dir = assets_dir / 'icons' / category
        png_dir = assets_dir / 'icons' / category
        
        for svg_file in svg_dir.glob('*.svg'):
            svg_count += 1
            png_file = png_dir / f"{svg_file.stem}.png"
            
            # ??????????
            scale = 1.0
            if category == 'window':
                scale = 1.0  # 8x8 -> 8x8
            elif category == 'status':
                scale = 1.0  # 8x8 -> 8x8
            else:
                scale = 4.0  # 16x16 -> 64x64
            
            if svg_to_png(str(svg_file), str(png_file), scale):
                png_count += 1
    
    # ???? SVG ? PNG
    print("\n[2] ???? SVG ? PNG...")
    cursor_svg_dir = assets_dir / 'cursors'
    for svg_file in cursor_svg_dir.glob('*.svg'):
        png_file = cursor_svg_dir / f"{svg_file.stem}.png"
        svg_to_png(str(svg_file), str(png_file), scale=1.0)
    
    # ?? ICO ??
    print("\n[3] ???? ICO ??...")
    arrow_png = assets_dir / 'cursors' / 'arrow.png'
    if arrow_png.exists():
        create_ico_from_png([str(arrow_png)], str(assets_dir / 'cursors' / 'arrow.ico'))
    
    # ?? Dock ????????
    print("\n[4] ????? Dock ??...")
    for svg_file in (assets_dir / 'icons' / 'dock').glob('*.svg'):
        base_name = svg_file.stem
        for size in [32, 48, 64, 128, 256]:
            png_file = assets_dir / 'icons' / 'dock' / f"{base_name}_{size}.png"
            svg_to_png(str(svg_file), str(png_file), scale=size/16)
    
    # ????
    print("\n[5] ??????...")
    wallpapers = [
        {
            'name': 'cyberpunk',
            'colors': [(30, 5, 51), (58, 27, 108), (100, 60, 150)],
            'direction': 'vertical'
        },
        {
            'name': 'nature',
            'colors': [(34, 139, 34), (70, 130, 180), (135, 206, 235)],
            'direction': 'vertical'
        },
        {
            'name': 'minimal',
            'colors': [(45, 45, 48)],
            'direction': 'vertical'
        },
        {
            'name': 'abstract',
            'colors': [(255, 87, 87), (255, 189, 46), (40, 200, 64)],
            'direction': 'diagonal'
        },
    ]
    
    for wp in wallpapers:
        wp_path = assets_dir / 'wallpapers' / f"{wp['name']}.png"
        if len(wp['colors']) == 1:
            # ????
            if HAS_PILLOW:
                img = Image.new('RGB', (1920, 1080), wp['colors'][0])
                img.save(str(wp_path))
                print(f"????: {wp_path}")
        else:
            create_wallpaper_gradient(
                str(wp_path),
                colors=wp['colors'],
                direction=wp['direction']
            )
    
    print("\n" + "=" * 50)
    print(f"??! ??? {png_count}/{svg_count} ? SVG ??")
    print(f"???????: {assets_dir}")
    print("=" * 50)


if __name__ == '__main__':
    main()
