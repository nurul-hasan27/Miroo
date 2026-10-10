#!/usr/bin/env python3
"""
generate_icons.py
Miroo Phase 13: Production App Icon Generation for macOS and iOS.
Renders pixel-perfect geometric vector iconography representing:
Mac -> iPhone extended display with low-latency connection.
Generates:
1. macOS AppIcon.icns and iconset (all 10 standard resolutions with macOS squircle mask and elevation)
2. iOS AppIcon asset catalog (all standard iPhone/iPad scales + 1024 App Store icon)
"""

import os
import math
import subprocess
from PIL import Image, ImageDraw, ImageFilter

def create_squircle_mask(size, radius_ratio=0.225):
    """Generates a superellipse / smooth squircle mask for macOS app icon standard."""
    scale = 4
    high_size = size * scale
    mask = Image.new("L", (high_size, high_size), 0)
    draw = ImageDraw.Draw(mask)
    
    # Apple squircle formula |x/a|^n + |y/b|^n <= 1 with n ~ 4.2
    n = 4.4
    a = high_size / 2.0 - (16 * scale) # Inset for standard macOS squircle (approx 824/1024)
    b = a
    cx, cy = high_size / 2.0, high_size / 2.0
    
    # Draw via polygon sampling
    points = []
    steps = 720
    for i in range(steps):
        theta = 2.0 * math.pi * i / steps
        cos_t = math.cos(theta)
        sin_t = math.sin(theta)
        
        sgn_cos = 1 if cos_t >= 0 else -1
        sgn_sin = 1 if sin_t >= 0 else -1
        
        r = 1.0 / ((abs(cos_t) ** n) + (abs(sin_t) ** n)) ** (1.0 / n)
        x = cx + a * r * cos_t
        y = cy + b * r * sin_t
        points.append((x, y))
        
    draw.polygon(points, fill=255)
    return mask.resize((size, size), Image.Resampling.LANCZOS)

def draw_miroo_artwork(size=1024, is_macos=False):
    """
    Renders the unified Miroo branding:
    - Calm, technical, premium dark titanium / obsidian backdrop.
    - Mac primary display on left (16:10 aspect).
    - iPhone secondary display on right (19.5:9 portrait aspect).
    - Continuous zero-latency cyan data beam connecting both displays into a unified desktop.
    """
    scale = 2
    canvas_size = size * scale
    img = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    
    # 1. Background Gradient Plate
    # Top-left dark navy graphite -> Bottom-right deep obsidian
    bg = Image.new("RGBA", (canvas_size, canvas_size), (14, 17, 24, 255))
    bg_draw = ImageDraw.Draw(bg)
    for y in range(canvas_size):
        ratio = y / float(canvas_size)
        r = int(18 * (1 - ratio) + 8 * ratio)
        g = int(22 * (1 - ratio) + 11 * ratio)
        b = int(32 * (1 - ratio) + 16 * ratio)
        bg_draw.line([(0, y), (canvas_size, y)], fill=(r, g, b, 255))
        
    # Subtle radial ambient glow in center
    glow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    gcx, gcy = int(canvas_size * 0.55), int(canvas_size * 0.5)
    glow_radius = int(canvas_size * 0.45)
    for r in range(glow_radius, 0, -8):
        alpha = int(22 * (1 - (r / glow_radius) ** 1.8))
        glow_draw.ellipse([gcx - r, gcy - r, gcx + r, gcy + r], fill=(0, 168, 255, alpha))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=24 * scale))
    bg = Image.alpha_composite(bg, glow)
    
    # Subtle diagonal background grid pattern (technical drafting aesthetic)
    grid = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    grid_draw = ImageDraw.Draw(grid)
    grid_spacing = int(48 * scale)
    for x in range(0, canvas_size, grid_spacing):
        grid_draw.line([(x, 0), (x, canvas_size)], fill=(255, 255, 255, 4), width=int(1 * scale))
    for y in range(0, canvas_size, grid_spacing):
        grid_draw.line([(0, y), (canvas_size, y)], fill=(255, 255, 255, 4), width=int(1 * scale))
    bg = Image.alpha_composite(bg, grid)

    # 2. Geometry: Mac Display (Left) + iPhone Display (Right)
    # Mac Display (Aspect ratio ~16:10)
    mac_w = int(480 * scale)
    mac_h = int(320 * scale)
    mac_x = int(canvas_size * 0.16)
    mac_y = int(canvas_size * 0.5 - mac_h * 0.5)
    mac_corner = int(22 * scale)

    # iPhone Display (Aspect ratio ~19.5:9 portrait)
    phone_w = int(210 * scale)
    phone_h = int(440 * scale)
    phone_x = int(mac_x + mac_w - 70 * scale) # Elegantly bridges / overlaps right side of Mac
    phone_y = int(canvas_size * 0.5 - phone_h * 0.5)
    phone_corner = int(42 * scale)

    # Draw Mac Display Shadow
    mac_shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ms_draw = ImageDraw.Draw(mac_shadow)
    ms_draw.rounded_rectangle(
        [mac_x - 10 * scale, mac_y + 12 * scale, mac_x + mac_w + 10 * scale, mac_y + mac_h + 30 * scale],
        radius=mac_corner + 4 * scale,
        fill=(0, 0, 0, 140)
    )
    mac_shadow = mac_shadow.filter(ImageFilter.GaussianBlur(radius=18 * scale))
    bg = Image.alpha_composite(bg, mac_shadow)

    # Draw Mac Display Outer Bezel (Sleek dark anodized aluminum)
    bezel_draw = ImageDraw.Draw(bg)
    bezel_draw.rounded_rectangle(
        [mac_x, mac_y, mac_x + mac_w, mac_y + mac_h],
        radius=mac_corner,
        fill=(22, 26, 36, 255),
        outline=(64, 75, 98, 255),
        width=int(2.5 * scale)
    )

    # Mac Display Screen Glass (Deep Obsidian)
    screen_inset = int(14 * scale)
    screen_x0 = mac_x + screen_inset
    screen_y0 = mac_y + screen_inset
    screen_x1 = mac_x + mac_w - screen_inset
    screen_y1 = mac_y + mac_h - screen_inset
    bezel_draw.rounded_rectangle(
        [screen_x0, screen_y0, screen_x1, screen_y1],
        radius=max(6, mac_corner - int(8 * scale)),
        fill=(10, 13, 19, 255),
        outline=(30, 36, 48, 255),
        width=int(1.5 * scale)
    )

    # Mac Screen Content: Desktop window wireframes
    win_x = screen_x0 + int(24 * scale)
    win_y = screen_y0 + int(28 * scale)
    win_w = int(220 * scale)
    win_h = int(150 * scale)
    bezel_draw.rounded_rectangle(
        [win_x, win_y, win_x + win_w, win_y + win_h],
        radius=int(8 * scale),
        fill=(16, 22, 34, 220),
        outline=(44, 56, 80, 255),
        width=int(1.5 * scale)
    )
    # Window traffic lights
    for i, col in enumerate([(255, 95, 87), (254, 187, 43), (39, 201, 63)]):
        bezel_draw.ellipse(
            [win_x + (14 + i * 16) * scale, win_y + 12 * scale, win_x + (22 + i * 16) * scale, win_y + 20 * scale],
            fill=col
        )
    # Window content lines
    bezel_draw.line(
        [(win_x + 16 * scale, win_y + 44 * scale), (win_x + win_w - 24 * scale, win_y + 44 * scale)],
        fill=(56, 70, 96, 200),
        width=int(2 * scale)
    )
    bezel_draw.line(
        [(win_x + 16 * scale, win_y + 64 * scale), (win_x + int(win_w * 0.6), win_y + 64 * scale)],
        fill=(46, 58, 80, 180),
        width=int(2 * scale)
    )

    # Draw iPhone Display Shadow (Elevated over the Mac screen)
    phone_shadow = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    ps_draw = ImageDraw.Draw(phone_shadow)
    ps_draw.rounded_rectangle(
        [phone_x - 16 * scale, phone_y + 8 * scale, phone_x + phone_w + 16 * scale, phone_y + phone_h + 36 * scale],
        radius=phone_corner + 6 * scale,
        fill=(0, 0, 0, 180)
    )
    phone_shadow = phone_shadow.filter(ImageFilter.GaussianBlur(radius=22 * scale))
    bg = Image.alpha_composite(bg, phone_shadow)

    # Draw iPhone Outer Chassis (Polished dark titanium)
    phone_draw = ImageDraw.Draw(bg)
    phone_draw.rounded_rectangle(
        [phone_x, phone_y, phone_x + phone_w, phone_y + phone_h],
        radius=phone_corner,
        fill=(20, 24, 34, 255),
        outline=(0, 210, 255, 230), # Vibrant electric cyan accent ring!
        width=int(3 * scale)
    )

    # iPhone Screen Glass
    phone_inset = int(12 * scale)
    phone_sx0 = phone_x + phone_inset
    phone_sy0 = phone_y + phone_inset
    phone_sx1 = phone_x + phone_w - phone_inset
    phone_sy1 = phone_y + phone_h - phone_inset
    phone_draw.rounded_rectangle(
        [phone_sx0, phone_sy0, phone_sx1, phone_sy1],
        radius=phone_corner - int(8 * scale),
        fill=(8, 12, 18, 255),
        outline=(0, 160, 230, 100),
        width=int(1.5 * scale)
    )

    # Dynamic Island / Notch on iPhone screen
    notch_w = int(54 * scale)
    notch_h = int(14 * scale)
    notch_x = int((phone_sx0 + phone_sx1) * 0.5 - notch_w * 0.5)
    notch_y = phone_sy0 + int(10 * scale)
    phone_draw.rounded_rectangle(
        [notch_x, notch_y, notch_x + notch_w, notch_y + notch_h],
        radius=int(7 * scale),
        fill=(4, 6, 8, 255)
    )

    # iPhone Content: Mirrored / Extended desktop workspace
    ip_win_x = phone_sx0 + int(16 * scale)
    ip_win_y = phone_sy0 + int(60 * scale)
    ip_win_w = phone_sx1 - phone_sx0 - int(32 * scale)
    ip_win_h = int(240 * scale)
    phone_draw.rounded_rectangle(
        [ip_win_x, ip_win_y, ip_win_x + ip_win_w, ip_win_y + ip_win_h],
        radius=int(14 * scale),
        fill=(14, 22, 38, 230),
        outline=(0, 200, 255, 160),
        width=int(2 * scale)
    )
    # Live stream active pulse grid inside iPhone
    for y_bar in range(ip_win_y + int(36 * scale), ip_win_y + ip_win_h - int(20 * scale), int(26 * scale)):
        phone_draw.line(
            [(ip_win_x + 16 * scale, y_bar), (ip_win_x + ip_win_w - 16 * scale, y_bar)],
            fill=(0, 200, 255, 90),
            width=int(2 * scale)
        )

    # 3. THE EXTENSION BRIDGE: Luminous Cyan Continuous Ray
    # Spans effortlessly from the center of the Mac display across into the iPhone display
    beam = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    beam_draw = ImageDraw.Draw(beam)

    beam_y = int(canvas_size * 0.5)
    beam_x_start = mac_x + int(100 * scale)
    beam_x_end = phone_x + int(phone_w * 0.65)

    # Layer 1: Broad ambient glow
    beam_draw.line(
        [(beam_x_start, beam_y), (beam_x_end, beam_y)],
        fill=(0, 210, 255, 90),
        width=int(22 * scale)
    )
    # Layer 2: Intense inner beam
    beam_draw.line(
        [(beam_x_start + 40 * scale, beam_y), (beam_x_end, beam_y)],
        fill=(56, 225, 255, 180),
        width=int(8 * scale)
    )
    # Layer 3: Laser-sharp white-hot core
    beam_draw.line(
        [(beam_x_start + 60 * scale, beam_y), (beam_x_end - 20 * scale, beam_y)],
        fill=(255, 255, 255, 255),
        width=int(3 * scale)
    )
    # Connection junction node on iPhone screen
    node_cx, node_cy = beam_x_end - int(20 * scale), beam_y
    node_r = int(10 * scale)
    beam_draw.ellipse(
        [node_cx - node_r, node_cy - node_r, node_cx + node_r, node_cy + node_r],
        fill=(255, 255, 255, 255),
        outline=(0, 230, 255, 255),
        width=int(3 * scale)
    )

    beam_glow = beam.filter(ImageFilter.GaussianBlur(radius=8 * scale))
    bg = Image.alpha_composite(bg, beam_glow)
    bg = Image.alpha_composite(bg, beam)

    # Downsample cleanly to target resolution
    final_img = bg.resize((size, size), Image.Resampling.LANCZOS)

    if is_macos:
        # For macOS: Clip with official Apple squircle and add subtle elevation drop shadow
        squircle_mask = create_squircle_mask(size)
        masked_artwork = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        masked_artwork.paste(final_img, (0, 0), squircle_mask)

        # macOS Elevation drop shadow
        shadow_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        shadow_draw = ImageDraw.Draw(shadow_layer)
        # Inset shadow bounds matching squircle footprint
        s_inset = int(size * 0.09)
        s_offset_y = int(size * 0.02)
        shadow_draw.rectangle([s_inset, s_inset + s_offset_y, size - s_inset, size - s_inset + s_offset_y], fill=(0, 0, 0, 110))
        shadow_layer = shadow_layer.filter(ImageFilter.GaussianBlur(radius=int(size * 0.035)))
        
        # Micro rim light around the squircle
        rim_layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        rim_draw = ImageDraw.Draw(rim_layer)
        
        macos_final = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        macos_final = Image.alpha_composite(macos_final, shadow_layer)
        macos_final = Image.alpha_composite(macos_final, masked_artwork)
        return macos_final
    else:
        # iOS AppIcon: Full bleed 1024x1024 square, iOS automatically clips to squircle
        return final_img

def main():
    print("[1/4] Rendering Miroo master iconography...")
    macos_master = draw_miroo_artwork(size=1024, is_macos=True)
    ios_master = draw_miroo_artwork(size=1024, is_macos=False)

    out_dir = "/Users/nurulhasan/Developer/Miroo/MirooMac/Resources"
    os.makedirs(out_dir, exist_ok=True)
    macos_master.save(os.path.join(out_dir, "AppIcon1024_mac.png"))

    ios_dir = "/Users/nurulhasan/Developer/Miroo/MirooPhone/Assets.xcassets/AppIcon.appiconset"
    os.makedirs(ios_dir, exist_ok=True)
    ios_master.save(os.path.join(ios_dir, "AppIcon-1024x1024.png"))

    print("[2/4] Generating macOS iconset and AppIcon.icns...")
    iconset_dir = "/Users/nurulhasan/Developer/Miroo/MirooMac/Resources/AppIcon.iconset"
    os.makedirs(iconset_dir, exist_ok=True)

    sizes = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]

    for s, name in sizes:
        resized = macos_master.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, name))

    icns_path = "/Users/nurulhasan/Developer/Miroo/MirooMac/Resources/AppIcon.icns"
    subprocess.run(["iconutil", "-c", "icns", iconset_dir, "-o", icns_path], check=True)
    print(f"  ✓ Created {icns_path}")

    print("[3/4] Generating iOS AppIcon asset catalog...")
    ios_scales = [
        (40, "AppIcon-20x20@2x.png"),
        (60, "AppIcon-20x20@3x.png"),
        (58, "AppIcon-29x29@2x.png"),
        (87, "AppIcon-29x29@3x.png"),
        (80, "AppIcon-40x40@2x.png"),
        (120, "AppIcon-40x40@3x.png"),
        (120, "AppIcon-60x60@2x.png"),
        (180, "AppIcon-60x60@3x.png"),
        (1024, "AppIcon-1024x1024.png")
    ]

    for s, name in ios_scales:
        resized = ios_master.resize((s, s), Image.Resampling.LANCZOS)
        resized.save(os.path.join(ios_dir, name))

    # Write Contents.json for iOS AppIcon
    contents_json = """{
  "images" : [
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "20x20",
      "filename" : "AppIcon-20x20@2x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "20x20",
      "filename" : "AppIcon-20x20@3x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "29x29",
      "filename" : "AppIcon-29x29@2x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "29x29",
      "filename" : "AppIcon-29x29@3x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "40x40",
      "filename" : "AppIcon-40x40@2x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "40x40",
      "filename" : "AppIcon-40x40@3x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "2x",
      "size" : "60x60",
      "filename" : "AppIcon-60x60@2x.png"
    },
    {
      "idiom" : "iphone",
      "scale" : "3x",
      "size" : "60x60",
      "filename" : "AppIcon-60x60@3x.png"
    },
    {
      "idiom" : "ios-marketing",
      "scale" : "1x",
      "size" : "1024x1024",
      "filename" : "AppIcon-1024x1024.png"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}"""
    with open(os.path.join(ios_dir, "Contents.json"), "w") as f:
        f.write(contents_json)
    print(f"  ✓ Created {os.path.join(ios_dir, 'Contents.json')}")

    print("[4/4] Icon generation complete!")

if __name__ == "__main__":
    main()
