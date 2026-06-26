# compress-usdz

**compress-usdz** is a small macOS command-line helper for reducing oversized `.usdz` files — especially AI-generated or Meshy-generated assets — so they are more practical for Apple Vision Pro, RealityKit, ARKit, Quick Look, spatial apps, and other USDZ workflows.

It was built after running into a common problem: Meshy can generate great-looking USDZ models, but the exported files may be **40 MB+** for simple assets. That is painful when you need to ship, share, preview, or iterate on multiple models.

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
- mesh data that can often be cleaned or simplified before export

`compress-usdz.sh` automates the reduction:

- unpack USDZ
- find the root USD/USD/C layer
- resize and recompress textures
- optionally run Blender headless to clean and/or decimate meshes
- remove unsupported generated HDR references
- repackage with `usdzip`
- optionally validate with `usdchecker`
- optionally open in Quick Look

## Requirements

### Required

Install OpenUSD tools so `usdzip` is available.

Verify:

```bash
command -v usdzip
command -v usdcat
command -v usdchecker
```

`usdzip` is required. The script intentionally does **not** fall back to ordinary `zip`, because ordinary zip packaging can break USDZ files.

`usdcat` is strongly recommended for the Blender cleanup/decimation path. The script uses it to convert cleaned USDA back to compact crate/binary USD before packaging.

### Recommended

Install ImageMagick for better texture conversion:

```bash
brew install imagemagick
```

If ImageMagick is not installed, the script falls back to macOS `sips`.

### Optional: Blender for mesh cleanup and decimation

Install Blender from blender.org, then confirm:

```bash
ls /Applications/Blender.app/Contents/MacOS/Blender
```

Blender is required when using:

- `-decimate`
- `--mesh-clean`
- `--aggressive-clean`
- `--fill-holes`

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
  [--mesh-clean] \
  [--no-mesh-clean] \
  [--aggressive-clean] \
  [--fill-holes] \
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
| `--mesh-clean` | Run the conservative Blender mesh cleanup pass even without `-decimate` |
| `--no-mesh-clean` | Skip the conservative cleanup pass during decimation |
| `--aggressive-clean` | Try more aggressive mesh cleanup, such as interior-face cleanup. Experimental |
| `--fill-holes` | Try to fill mesh holes. Experimental; may create untextured/new faces |
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

### Conservative mesh cleanup

Runs the Blender cleanup pass without decimation. This is useful when you want to remove obvious mesh cruft while preserving the overall shape.

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_clean.usdz \
  -jpeg 65 \
  -size 1024 \
  --mesh-clean
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

By default, the conservative cleanup pass runs before decimation.

### Decimation without mesh cleanup

If cleanup causes a visible issue, skip it:

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_10_no_cleanup.usdz \
  -jpeg 65 \
  -size 1024 \
  -decimate 0.1 \
  --no-mesh-clean
```

### Experimental aggressive cleanup

Use this only when a model has obvious internal geometry, bad manifold issues, or other mesh problems. Inspect the output carefully.

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_aggressive.usdz \
  -jpeg 65 \
  -size 1024 \
  -decimate 0.1 \
  --aggressive-clean \
  --check \
  --preview
```

### Experimental hole filling

This may help with visible holes, but new faces may not have useful UVs or textures.

```bash
./compress-usdz.sh \
  -i llama.usdz \
  -o llama_filled.usdz \
  -jpeg 65 \
  -size 1024 \
  --mesh-clean \
  --fill-holes \
  --preview
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

For cleanup without changing triangle count much:

```bash
-jpeg 65 -size 1024 --mesh-clean
```

## How texture compression works

The script unpacks the USDZ and looks for image files referenced by the asset. It can resize and recompress common texture formats while keeping the same file names and references.

When ImageMagick is installed, the script uses it to:

- auto-orient images
- resize images to the requested maximum width/height
- convert JPEGs to sRGB
- avoid progressive/interlaced JPEG output
- strip metadata
- apply the requested JPEG quality

The goal is to reduce texture weight without changing USD material references.

## How mesh cleanup works

When Blender is used, the script can run a conservative mesh cleanup pass before export.

The default cleanup pass is intended to be relatively safe for textured models:

1. deletes loose vertices/edges/faces
2. merges near-duplicate vertices
3. dissolves degenerate geometry where Blender can do so safely
4. recalculates normals outside
5. removes extra color attributes where possible
6. keeps the first UV set and removes duplicate UV maps where possible

The conservative cleanup pass is designed to remove common generated mesh cruft without rebuilding the model.

## How decimation works

When `-decimate` is used, the script runs Blender in background mode.

The Blender step:

1. imports the USD root layer
2. counts triangles
3. runs the conservative cleanup pass unless `--no-mesh-clean` is set
4. applies Blender’s Decimate modifier
5. exports a reduced USDA
6. strips unsupported HDR references
7. converts the cleaned result to crate/binary USD using `usdcat`
8. packages the result with `usdzip`

This is not a perfect optimizer. It is a practical reduction pipeline for app assets.

Always test the output.

## Experimental mesh repair

Some cleanup operations are useful when preparing a model for 3D printing, but risky when the goal is to preserve textured USDZ assets.

For that reason, the more destructive options are opt-in.

### `--aggressive-clean`

Attempts additional mesh cleanup such as removing interior faces.

This may help with generated internal geometry, but it can also remove surfaces you wanted to keep. Use it only when the default path is not enough.

### `--fill-holes`

Attempts to fill holes in the mesh.

This can help with visible gaps, but it may create new faces without useful UVs, which can appear untextured or oddly shaded.

### Not automatic

The script does **not** automatically run Boolean Union, Solidify, full Make Manifold, or broad remeshing operations by default.

Those tools can be useful in Blender, especially for 3D printing, but they can also rewrite geometry, damage UVs, change silhouettes, or create new untextured surfaces. If a model needs that level of repair, manual inspection is still the safer path.

## Important notes

### USDZ is not a normal zip

Do not unpack a USDZ, change files, and repackage it with normal `zip`.

A USDZ package needs uncompressed entries and USDZ-compatible layout/alignment. The script uses `usdzip` because it is built for USDZ packaging.

### Decimation is not lossless

A decimate ratio of `0.1` means the mesh is aggressively reduced. That may be fine for a small object, but it may be too aggressive for a model shown close up.

Test in:

- Quick Look
- Reality Composer Pro
- RealityKit
- your actual app or target viewer

### Mesh cleanup is not lossless either

Even conservative cleanup can change a model. If the output looks wrong, try:

```bash
--no-mesh-clean
```

or run texture-only compression first.

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

### `usdcat not found`

The script can still package USDA in some cases, but `usdcat` is recommended because it allows the cleaned USDA to be converted back into compact crate/binary USD.

Verify:

```bash
command -v usdcat
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

### Model looks broken after cleanup

Try disabling mesh cleanup:

```bash
--no-mesh-clean
```

or run texture-only compression:

```bash
./compress-usdz.sh -i input.usdz -o output.usdz -jpeg 65 -size 1024
```

If only the aggressive path broke the model, remove:

```bash
--aggressive-clean
```

or:

```bash
--fill-holes
```

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
7. Test in your target viewer or app.
8. Keep the smallest version that still looks good.

Example:

```bash
./compress-usdz.sh -i meshy_llama.usdz -o llama_texture.usdz -jpeg 60 -size 1024 --preview

./compress-usdz.sh -i meshy_llama.usdz -o llama_10.usdz -jpeg 65 -size 1024 -decimate 0.1 --check --preview
```

## What this is good for

- Meshy-generated USDZ models
- AI-generated USDZ models
- Apple Vision Pro prototypes
- RealityKit apps
- ARKit assets
- Quick Look previews
- spatial computing demos
- app bundles with many USDZ files
- reducing files before sharing or versioning

## What this is not

- a guaranteed lossless optimizer
- a replacement for manual retopology
- a production art pipeline for hero assets
- a magic “delete the inside but keep the perfect shell” tool
- a substitute for testing the final model in your target runtime

## Credits

This helper combines OpenUSD command-line tools, ImageMagick texture processing, and Blender headless mesh cleanup/decimation into a simple macOS workflow for shrinking USDZ files. 

Additional features added from post by `u/midvalePeak7` at [https://www.reddit.com/r/meshyai/s/AmJ7CryN1B](https://www.reddit.com/r/meshyai/s/AmJ7CryN1B)