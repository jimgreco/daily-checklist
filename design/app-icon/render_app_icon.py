#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import json
import math
import shutil

from PIL import Image, ImageDraw, ImageFilter


ROOT = Path(__file__).resolve().parents[2]
ICON_SET = ROOT / "Daily" / "Assets.xcassets" / "AppIcon.appiconset"
ICON_PACKAGE = ROOT / "Daily" / "AppIcon.icon"
DESIGN_DIR = Path(__file__).resolve().parent
SIZE = 1024
SCALE = 3
CANVAS = SIZE * SCALE


def sc(value: float) -> int:
    return round(value * SCALE)


def blank() -> Image.Image:
    return Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))


def rounded_mask(size: tuple[int, int], radius: int) -> Image.Image:
    mask = Image.new("L", size, 0)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def linear_gradient(stops: list[tuple[float, tuple[int, int, int]]]) -> Image.Image:
    image = Image.new("RGBA", (CANVAS, CANVAS))
    pixels = image.load()

    for y in range(CANVAS):
        for x in range(CANVAS):
            t = (0.62 * x + 0.78 * y) / (CANVAS * 1.4)
            t += 0.055 * math.sin((x + y) / CANVAS * math.pi)
            t = max(0.0, min(1.0, t))
            for index, (stop, color) in enumerate(stops):
                if t <= stop:
                    prev_stop, prev_color = stops[max(index - 1, 0)]
                    span = max(stop - prev_stop, 0.001)
                    local = (t - prev_stop) / span
                    r = round(prev_color[0] + (color[0] - prev_color[0]) * local)
                    g = round(prev_color[1] + (color[1] - prev_color[1]) * local)
                    b = round(prev_color[2] + (color[2] - prev_color[2]) * local)
                    pixels[x, y] = (r, g, b, 255)
                    break

    return image


def radial_glow(center: tuple[float, float], radius: float, color: tuple[int, int, int], opacity: int) -> Image.Image:
    layer = blank()
    pixels = layer.load()
    cx, cy = sc(center[0]), sc(center[1])
    r = sc(radius)

    for y in range(max(0, cy - r), min(CANVAS, cy + r)):
        for x in range(max(0, cx - r), min(CANVAS, cx + r)):
            distance = math.hypot(x - cx, y - cy) / r
            if distance <= 1:
                alpha = round(opacity * (1 - distance) ** 1.8)
                if alpha:
                    pixels[x, y] = (*color, alpha)

    return layer


def draw_soft_shadow(base: Image.Image, shape_mask: Image.Image, offset: tuple[int, int], blur: int, color: tuple[int, int, int, int]) -> None:
    alpha = Image.new("L", base.size, 0)
    alpha.paste(shape_mask, offset)
    shadow = Image.new("RGBA", base.size, color)
    shadow.putalpha(alpha.filter(ImageFilter.GaussianBlur(blur)))
    base.alpha_composite(shadow)


def make_background() -> Image.Image:
    base = linear_gradient([
        (0.0, (33, 37, 214)),
        (0.42, (77, 59, 235)),
        (0.72, (127, 82, 246)),
        (1.0, (238, 125, 230)),
    ])
    base.alpha_composite(radial_glow((240, 180), 520, (97, 244, 255), 68))
    base.alpha_composite(radial_glow((850, 880), 520, (255, 214, 124), 74))
    base.alpha_composite(radial_glow((840, 230), 420, (177, 137, 255), 82))
    return base


def make_glass_card() -> Image.Image:
    layer = blank()
    card_box = (sc(260), sc(225), sc(760), sc(790))
    card_size = (card_box[2] - card_box[0], card_box[3] - card_box[1])
    card_mask = rounded_mask(card_size, sc(90))

    draw_soft_shadow(layer, card_mask, (card_box[0] + sc(14), card_box[1] + sc(34)), sc(34), (30, 12, 106, 72))
    draw_soft_shadow(layer, card_mask, (card_box[0] - sc(10), card_box[1] - sc(4)), sc(22), (255, 255, 255, 36))

    card = Image.new("RGBA", card_size, (246, 248, 255, 218))
    card.alpha_composite(radial_glow((220, 80), 380, (255, 255, 255), 150).crop((0, 0, card_size[0], card_size[1])))
    card.alpha_composite(radial_glow((390, 455), 360, (151, 106, 255), 42).crop((0, 0, card_size[0], card_size[1])))
    card.putalpha(card_mask.point(lambda value: min(value, 224)))
    layer.alpha_composite(card, (card_box[0], card_box[1]))

    stroke = Image.new("RGBA", card_size, (0, 0, 0, 0))
    stroke_draw = ImageDraw.Draw(stroke)
    stroke_draw.rounded_rectangle(
        (sc(3), sc(3), card_size[0] - sc(3), card_size[1] - sc(3)),
        radius=sc(86),
        outline=(255, 255, 255, 172),
        width=sc(4),
    )
    layer.alpha_composite(stroke, (card_box[0], card_box[1]))
    return layer


def rounded_bar(draw: ImageDraw.ImageDraw, box: tuple[int, int, int, int], radius: int, fill: tuple[int, int, int, int]) -> None:
    draw.rounded_rectangle(box, radius=radius, fill=fill)


def make_list_lines() -> Image.Image:
    layer = blank()
    shadow = blank()
    shadow_draw = ImageDraw.Draw(shadow)
    bars = [
        (350, 337, 630, 367, 20, 184),
        (350, 423, 585, 453, 20, 176),
        (350, 509, 488, 539, 20, 166),
    ]

    for x0, y0, x1, y1, radius, opacity in bars:
        rounded_bar(shadow_draw, (sc(x0), sc(y0), sc(x1), sc(y1)), sc(radius), (61, 31, 180, 90))

    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(9)))
    layer.alpha_composite(shadow, (0, sc(8)))

    draw = ImageDraw.Draw(layer)
    for x0, y0, x1, y1, radius, opacity in bars:
        rounded_bar(draw, (sc(x0), sc(y0), sc(x1), sc(y1)), sc(radius), (114, 85, 221, opacity))
        rounded_bar(draw, (sc(x0), sc(y0), sc(x1), sc(y0 + 10)), sc(radius), (255, 255, 255, 72))

    return layer


def make_checkmark() -> Image.Image:
    layer = blank()
    path = [(402, 628), (490, 715), (790, 414)]
    scaled = [(sc(x), sc(y)) for x, y in path]

    shadow = blank()
    shadow_draw = ImageDraw.Draw(shadow)
    shadow_width = sc(78)
    shadow_draw.line(scaled, fill=(42, 19, 121, 112), width=shadow_width, joint="curve")
    for point in scaled:
        r = shadow_width // 2
        shadow_draw.ellipse((point[0] - r, point[1] - r, point[0] + r, point[1] + r), fill=(42, 19, 121, 112))
    shadow = shadow.filter(ImageFilter.GaussianBlur(sc(22)))
    layer.alpha_composite(shadow, (sc(20), sc(34)))

    under = ImageDraw.Draw(layer)
    under_width = sc(86)
    under.line(scaled, fill=(190, 176, 255, 112), width=under_width, joint="curve")
    for point in scaled:
        r = under_width // 2
        under.ellipse((point[0] - r, point[1] - r, point[0] + r, point[1] + r), fill=(190, 176, 255, 112))

    draw = ImageDraw.Draw(layer)
    main_width = sc(70)
    draw.line(scaled, fill=(255, 255, 255, 246), width=main_width, joint="curve")
    for point in scaled:
        r = main_width // 2
        draw.ellipse((point[0] - r, point[1] - r, point[0] + r, point[1] + r), fill=(255, 255, 255, 246))

    return layer


def make_highlights() -> Image.Image:
    layer = blank()
    draw = ImageDraw.Draw(layer)
    draw.rounded_rectangle((sc(300), sc(238), sc(725), sc(258)), radius=sc(12), fill=(255, 255, 255, 32))
    draw.ellipse((sc(722), sc(360), sc(836), sc(474)), fill=(255, 255, 255, 24))
    return layer.filter(ImageFilter.GaussianBlur(sc(0.35)))


def downsample(image: Image.Image) -> Image.Image:
    return image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def save_layer(name: str, image: Image.Image) -> None:
    downsample(image).save(DESIGN_DIR / name)


def write_icon_package(layer_names: list[str]) -> None:
    if ICON_PACKAGE.exists():
        shutil.rmtree(ICON_PACKAGE)

    assets_dir = ICON_PACKAGE / "Assets"
    assets_dir.mkdir(parents=True)

    for name in layer_names:
        shutil.copyfile(DESIGN_DIR / name, assets_dir / name)

    icon = {
        "color-space-for-untagged-svg-colors": "display-p3",
        "fill": {
            "automatic-gradient": "extended-srgb:0.21961,0.18824,0.87451,1.00000"
        },
        "groups": [
            {
                "layers": [
                    {
                        "name": "Specular highlights",
                        "image-name": "05-specular-highlights.png",
                        "glass": True,
                    },
                    {
                        "name": "Completion checkmark",
                        "image-name": "04-checkmark.png",
                        "glass": True,
                    },
                    {
                        "name": "Checklist lines",
                        "image-name": "03-list-lines.png",
                        "glass": True,
                    },
                    {
                        "name": "Frosted checklist card",
                        "image-name": "02-frosted-card.png",
                        "glass": True,
                    },
                    {
                        "name": "Background glow",
                        "image-name": "01-background.png",
                        "glass": False,
                    },
                ],
                "lighting": "combined",
                "shadow": {
                    "kind": "layer-color",
                    "opacity": 0.42,
                },
                "translucency": {
                    "enabled": True,
                    "value": 0.36,
                },
            }
        ],
        "supported-platforms": {
            "circles": ["watchOS"],
            "squares": "shared",
        },
    }

    (ICON_PACKAGE / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")


def main() -> None:
    background = make_background()
    layers = [
        ("01-background.png", background),
        ("02-frosted-card.png", make_glass_card()),
        ("03-list-lines.png", make_list_lines()),
        ("04-checkmark.png", make_checkmark()),
        ("05-specular-highlights.png", make_highlights()),
    ]

    composite = background.copy()
    for _, layer in layers[1:]:
        composite.alpha_composite(layer)

    for name, layer in layers:
        save_layer(name, layer)

    write_icon_package([name for name, _ in layers])

    ICON_SET.mkdir(parents=True, exist_ok=True)
    downsample(composite.convert("RGBA")).convert("RGB").save(ICON_SET / "AppIcon-1024.png")


if __name__ == "__main__":
    main()
