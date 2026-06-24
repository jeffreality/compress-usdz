# compress-usdz

**compress-usdz** is a small macOS command-line helper for reducing oversized `.usdz` files — especially AI-generated or Meshy-generated assets — so they are more practical for Apple Vision Pro, RealityKit, ARKit, Quick Look, and spatial apps.

It was built after running into a common problem: Meshy can generate great-looking USDZ models, but the exported files may be **40 MB+** for simple assets. That is painful when you need to ship a bundle of models inside an app.

In one test with a Meshy-generated plush llama:

| Version | Size | Notes |
|---|---:|---|
| Original USDZ | ~39.6 MiB / ~41.5 MB | 1,159,312 triangles, 4098px texture |
| Texture-only pass | 27.2 MB | Texture resized/recompressed |
| Texture + decimate `0.1` | 4.4 MB | 115,808 triangles, 1024px texture |

## Why this exists

A `.usdz` file is not a normal compressed zip. It is a package format designed for fast random access by USD/AR runtimes. That means you usually cannot fix file size by just zipping harder, and repackaging with the wrong zip tool can create files that look valid but fail in Quick Look, RealityKit, or `usdchecker`.

Most of the size in AI-generated USDZ files usually comes from:

- giant textures
- excessive triangle counts
- unused or duplicated material data
- generated references that are not useful for Apple/ARKit delivery

`compress-usdz.sh` automates the reduction:

- unpack USDZ
- find the root USD/USD/C layer
- resize and recompress textures
- optionally run Blender headless to decimate meshes
- remove unsupported generated HDR references
- repackage with `usdzip`
- optionally validate with `usdchecker`
- optionally open in Quick Look

## Requirements

### Required

Install OpenUSD tools so `usdzip` is available:

Verify:

```bash
command -v usdzip
command -v usdcat
command -v usdchecker
```

`usdzip` is required. The script intentionally does **not** fall back to ordinary `zip`, because ordinary zip packaging can break USDZ files.

### Recommended

Install ImageMagick for better texture conversion:

```bash
brew install imagemagick
```

If ImageMagick is not installed, the script falls back to macOS `sips`.

### Optional: Blender for mesh decimation

Install Blender from blender.org, then confirm:

```bash
ls /Applications/Blender.app/Contents/MacOS/Blender
```

Blender is only required when using `-decimate`.

## Installation

Clone or download this repository, then make the script executable:

```bash
chmod +x compress-usdz.sh
```

Optional: put it somewhere in your PATH:

```bash
sudo cp compress-usdz.sh /usr/local/bin/compress-usdz
```

Then run:

```bash
compress-usdz -h
```

## Usage

```bash
./compress-usdz.sh \
  -i input.usdz \
  -o output.usdz \
  [-jpeg 65] \
  [-size 1024] \
  [-decimate 0.1] \
  [--check] \
  [--preview]
```

### Options

| Option | Description |
|---|---|
| `-i`, `--input` | Input `.usdz` file |
| `-o`, `--output` | Output `.usdz` file |
| `-jpeg` | JPEG quality, 1–100. Default: `70` |
| `-size` | Maximum texture width/height. Default: `1024` |
| `-decimate` | Blender decimate ratio. Example: `0.1` keeps about 10% of faces |
| `--check` | Run `usdchecker --arkit` and `usdchecker` after export |
| `--preview` | Open the result in Quick Look / Preview |
| `--keep-work` | Keep the temporary working folder for debugging |

## Examples

### Texture-only compression

Good first pass. This is safest because it leaves the mesh alone.

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_texture.usdz \
  -jpeg 60 \
  -size 1024
```

### Texture compression + mesh decimation

Good for Meshy or AI-generated models with very high triangle counts.

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_10.usdz \
  -jpeg 65 \
  -size 1024 \
  -decimate 0.1
```

### Validate and preview

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_10.usdz \
  -jpeg 65 \
  -size 1024 \
  -decimate 0.1 \
  --check \
  --preview
```

---

## Suggested settings

For small models:

```bash
-jpeg 60 -size 1024 -decimate 0.1
```

For very high-poly Meshy models:

```bash
-jpeg 65 -size 1024 -decimate 0.05
```

For safer quality:

```bash
-jpeg 75 -size 2048 -decimate 0.25
```

For texture-only reduction:

```bash
-jpeg 60 -size 1024
```

## How decimation works

When `-decimate` is used, the script runs Blender in background mode.

The Blender step:

1. imports the USD root layer
2. counts triangles
3. removes duplicate vertices where possible
4. removes extra color attributes and duplicate UV maps where possible
5. applies Blender’s Decimate modifier
6. exports a reduced USDA
7. strips unsupported HDR references
8. converts the cleaned result to crate/binary USD using `usdcat`
9. packages the result with `usdzip`

This is not a perfect optimizer. It is a practical reduction pipeline for app assets.

Always test the output.

## Important notes

### USDZ is not a normal zip

Do not unpack a USDZ, change files, and repackage it with normal `zip`.

A USDZ package needs uncompressed entries and USDZ-compatible layout/alignment. The script uses `usdzip` because it is built for USDZ packaging.

### Decimation is not lossless

A decimate ratio of `0.1` means the mesh is aggressively reduced. That may be fine for a small background element, but it may be too aggressive for a hero object shown close up.

Test in:

- Quick Look
- Reality Composer Pro
- RealityKit
- your actual app

### Texture size matters

AI-generated assets often contain huge textures. A 4096px texture may be unnecessary for a small object in a mixed-reality scene. Try `1024` first, then go lower only if the model still looks good.

### Not all models survive automated cleanup

Some models have bad UVs, unusual material graphs, nested references, unsupported formats, or geometry that does not decimate cleanly. Use `--keep-work` if you need to inspect the temporary files.

## Troubleshooting

### `usdzip is required`

Install OpenUSD tools, then verify:

```bash
command -v usdzip
```

### Output does not open in Quick Look

Run with validation:

```bash
./compress-usdz.sh -i input.usdz -o output.usdz -jpeg 65 -size 1024 --check
```

If validation fails, rerun with:

```bash
--keep-work
```

Then inspect the temporary folder.

### File got bigger after Blender

This can happen. Blender may re-author the USD in a less compact form, especially at mild decimation ratios like `0.5`.

Try a stronger ratio:

```bash
-decimate 0.1
```

or:

```bash
-decimate 0.05
```

For very dense AI-generated models, `0.5` may still leave hundreds of thousands of triangles.

### Textures are missing

The script tries to copy texture files that are referenced by the cleaned USD layer. If a material uses unusual references or generated assets, it may need manual cleanup.

Use:

```bash
--keep-work
```

and inspect the exported `.usda`.

## Recommended workflow for Meshy USDZ assets

1. Generate/download the USDZ from Meshy.
2. Run a texture-only pass.
3. Preview it.
4. If still too large, run with `-decimate 0.1`.
5. Preview it.
6. Validate with `--check`.
7. Test in your app.
8. Keep the smallest version that still looks good.

Example:

```bash
./compress-usdz.sh -i meshy_llama.usdz -o llama_texture.usdz -jpeg 60 -size 1024 --preview

./compress-usdz.sh -i meshy_llama.usdz -o llama_10.usdz -jpeg 65 -size 1024 -decimate 0.1 --check --preview
```

## What this is good for

- Meshy-generated USDZ models
- Apple Vision Pro prototypes
- RealityKit apps
- ARKit assets
- Quick Look previews
- spatial computing demos
- app bundles with many USDZ files

## What this is not

- a guaranteed lossless optimizer
- a replacement for manual retopology
- a production art pipeline for hero assets
- a magic “delete the inside but keep the perfect shell” tool
- a substitute for testing the final model in your app

## Credits

This helper combines OpenUSD command-line tools, ImageMagick texture processing, and Blender headless mesh decimation into a simple macOS workflow for shrinking USDZ files.
