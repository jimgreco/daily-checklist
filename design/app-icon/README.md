# Ritual Cue App Icon

This folder contains the editable source layers for the Ritual Cue Liquid Glass app icon.

Run the renderer after changing the layer geometry or colors:

```sh
python3 design/app-icon/render_app_icon.py
```

The script writes:

- `01-background.png`
- `02-frosted-card.png`
- `03-list-lines.png`
- `04-checkmark.png`
- `05-specular-highlights.png`
- `Daily/AppIcon.icon`
- `Daily/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png`

`Daily/AppIcon.icon` is the layered Icon Composer package that Xcode 26 uses for the Liquid Glass app icon. The flattened `AppIcon-1024.png` remains in the asset catalog as the standard 1024px fallback/export image.

To preview the Icon Composer package without opening Xcode:

```sh
"/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool" \
  Daily/AppIcon.icon \
  --export-image \
  --output-file /tmp/ritual-cue-appicon-preview.png \
  --platform iOS \
  --rendition Default \
  --width 1024 \
  --height 1024 \
  --scale 1
```
