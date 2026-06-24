#!/bin/bash
set -euo pipefail

INPUT=""
OUTPUT=""
JPEG_QUALITY="70"
MAX_SIZE="1024"
DECIMATE=""
BLENDER="/Applications/Blender.app/Contents/MacOS/Blender"
PREVIEW=0
CHECK=0
KEEP_WORK=0

usage() {
  cat <<'USAGE'
Usage:
  ./compress-usdz.sh -i input.usdz -o output.usdz [-jpeg 60] [-size 1024] [-decimate 0.5] [--preview] [--check]

Examples:
  ./compress-usdz.sh -i llama.usdz -o llama_texture.usdz -jpeg 60 -size 1024
  ./compress-usdz.sh -i llama.usdz -o llama_10.usdz -jpeg 65 -size 1024 -decimate 0.1
  ./compress-usdz.sh -i llama.usdz -o llama_10.usdz -jpeg 65 -size 1024 -decimate 0.1 --check --preview

Options:
  -i, --input       Input USDZ
  -o, --output      Output USDZ
  -jpeg             JPEG quality, 1-100. Default: 70
  -size             Max texture width/height. Default: 1024
  -decimate         Blender decimate ratio. Example: 0.1
  --preview         Open output file after processing
  --check           Run usdchecker after processing
  --keep-work       Keep the temp folder for debugging
  -h, --help        Show help

Requires:
  - usdzip
  - ImageMagick recommended
  - usdcat recommended for decimation path
  - Blender only when -decimate is used
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input) INPUT="$2"; shift 2 ;;
    -o|--output) OUTPUT="$2"; shift 2 ;;
    -jpeg|--jpeg) JPEG_QUALITY="$2"; shift 2 ;;
    -size|--size) MAX_SIZE="$2"; shift 2 ;;
    -decimate|--decimate) DECIMATE="$2"; shift 2 ;;
    --preview|--open) PREVIEW=1; shift ;;
    --check) CHECK=1; shift ;;
    --keep-work) KEEP_WORK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [ -z "$INPUT" ] || [ -z "$OUTPUT" ]; then
  usage
  exit 1
fi

if [ ! -f "$INPUT" ]; then
  echo "Input not found: $INPUT" >&2
  exit 1
fi

if ! command -v usdzip >/dev/null 2>&1; then
  echo "ERROR: usdzip is required. Install OpenUSD tools first." >&2
  exit 1
fi

INPUT="$(cd "$(dirname "$INPUT")" && pwd)/$(basename "$INPUT")"
OUTPUT="$(cd "$(dirname "$OUTPUT")" && pwd)/$(basename "$OUTPUT")"

size_mb() {
  python3 - "$1" <<'PY'
import os, sys
print(f"{os.path.getsize(sys.argv[1]) / (1024*1024):.1f} MB")
PY
}

echo "Input:  $INPUT ($(size_mb "$INPUT"))"
echo "Output: $OUTPUT"

WORKDIR="$(mktemp -d /tmp/compress-usdz.XXXXXX)"
SRC="$WORKDIR/src"
EXPORT="$WORKDIR/export"
mkdir -p "$SRC" "$EXPORT"

cleanup() {
  if [ "$KEEP_WORK" = "1" ]; then
    echo "Keeping work folder: $WORKDIR"
  else
    rm -rf "$WORKDIR"
  fi
}
trap cleanup EXIT

echo "Unpacking..."
unzip -q "$INPUT" -d "$SRC"

echo "Largest unpacked files:"
find "$SRC" -type f -print0 | xargs -0 du -h | sort -hr | head -10 | sed 's/^/  /'

echo "Finding root USD layer from original archive order..."
ROOT_LAYER=""
while IFS= read -r item; do
  lower="$(printf '%s' "$item" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    *.usd|*.usda|*.usdc)
      ROOT_LAYER="$item"
      break
      ;;
  esac
done < <(unzip -Z -1 "$INPUT")

if [ -z "$ROOT_LAYER" ] || [ ! -f "$SRC/$ROOT_LAYER" ]; then
  echo "Could not find a root .usd/.usda/.usdc layer." >&2
  exit 1
fi

echo "Root layer: $ROOT_LAYER"

echo "Optimizing textures: max ${MAX_SIZE}px, JPEG quality ${JPEG_QUALITY}"
if command -v magick >/dev/null 2>&1; then
  while IFS= read -r -d '' img; do
    ext="${img##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    tmp="$img.tmp"
    case "$ext" in
      jpg|jpeg)
        magick "$img" -auto-orient -resize "${MAX_SIZE}x${MAX_SIZE}>" -colorspace sRGB -interlace none -strip -quality "$JPEG_QUALITY" "$tmp"
        mv "$tmp" "$img"
        ;;
      png)
        magick "$img" -auto-orient -resize "${MAX_SIZE}x${MAX_SIZE}>" -strip "$tmp"
        mv "$tmp" "$img"
        ;;
    esac
  done < <(find "$SRC" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0)
else
  echo "ImageMagick not found; using sips fallback."
  while IFS= read -r -d '' img; do
    ext="${img##*.}"
    ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
    sips -Z "$MAX_SIZE" "$img" >/dev/null || true
    if [ "$ext" = "jpg" ] || [ "$ext" = "jpeg" ]; then
      sips -s format jpeg -s formatOptions "$JPEG_QUALITY" "$img" --out "$img" >/dev/null || true
    fi
  done < <(find "$SRC" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) -print0)
fi

copy_ref_asset() {
  ref="$1"
  clean_ref="$ref"

  # Remove leading ./ for filesystem matching.
  clean_ref="${clean_ref#./}"

  # Never package HDR for Apple/ARKit path.
  ext="${clean_ref##*.}"
  ext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
  if [ "$ext" = "hdr" ]; then
    return 0
  fi

  # 1. Already exported by Blender?
  if [ -f "$EXPORT/$clean_ref" ]; then
    return 0
  fi

  # 2. Exact path from source extraction?
  if [ -f "$SRC/$clean_ref" ]; then
    mkdir -p "$EXPORT/$(dirname "$clean_ref")"
    cp "$SRC/$clean_ref" "$EXPORT/$clean_ref"
    return 0
  fi

  # 3. Basename fallback. This handles Blender changing extracted_image_0.jpg
  #    into textures/extracted_image_0.jpg.
  base="$(basename "$clean_ref")"
  found="$(find "$SRC" -type f -name "$base" | head -1 || true)"
  if [ -n "$found" ] && [ -f "$found" ]; then
    mkdir -p "$EXPORT/$(dirname "$clean_ref")"
    cp "$found" "$EXPORT/$clean_ref"
    return 0
  fi

  echo "Warning: could not find referenced asset: $ref" >&2
  return 0
}

if [ -n "$DECIMATE" ]; then
  echo "Decimation requested: $DECIMATE"
  if [ ! -x "$BLENDER" ]; then
    echo "Blender not found at $BLENDER" >&2
    exit 1
  fi

  PY="$WORKDIR/decimate_export_usda.py"
  cat > "$PY" <<'PY'
import bpy
import sys
from pathlib import Path

src_dir = Path(sys.argv[-4])
root_layer = sys.argv[-3]
output_usda = Path(sys.argv[-2])
ratio = float(sys.argv[-1])

def clear_scene():
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete()

def tri_count():
    depsgraph = bpy.context.evaluated_depsgraph_get()
    total = 0
    for obj in bpy.context.scene.objects:
        if obj.type != "MESH":
            continue
        evaluated = obj.evaluated_get(depsgraph)
        mesh = evaluated.to_mesh()
        for poly in mesh.polygons:
            total += max(len(poly.vertices) - 2, 1)
        evaluated.to_mesh_clear()
    return total

def usd_export_kwargs(filepath):
    kwargs = {"filepath": str(filepath)}
    try:
        props = {p.identifier for p in bpy.ops.wm.usd_export.get_rna_type().properties}
    except Exception:
        props = set()

    wanted = {
        "selected_objects_only": False,
        "export_animation": False,
        "export_cameras": False,
        "export_lights": False,
        "export_materials": True,
        "generate_preview_surface": True,
        "export_textures": False,
        "relative_paths": True,
        "export_normals": False,
        "export_mesh_colors": False,
        "export_custom_properties": False,
        "merge_transform_and_shape": True,
    }

    for key, value in wanted.items():
        if key in props:
            kwargs[key] = value

    return kwargs

def scrub_hdr_images_from_blender():
    # Remove world nodes/cameras/lights so Blender doesn't emit environment HDRs.
    if bpy.context.scene.world:
        bpy.context.scene.world.use_nodes = False
        bpy.context.scene.world.color = (0.0, 0.0, 0.0)

    for obj in list(bpy.context.scene.objects):
        if obj.type in {"CAMERA", "LIGHT"}:
            bpy.data.objects.remove(obj, do_unlink=True)

    for mat in list(bpy.data.materials):
        if not mat.use_nodes or not mat.node_tree:
            continue

        nodes = mat.node_tree.nodes
        for node in list(nodes):
            if getattr(node, "image", None) is None:
                continue

            path = (node.image.filepath or "").lower()
            if path.endswith(".hdr"):
                print(f"Removing HDR image node from material {mat.name}: {path}")
                nodes.remove(node)

    for image in list(bpy.data.images):
        path = (image.filepath or image.name or "").lower()
        if path.endswith(".hdr"):
            print(f"Removing HDR image datablock: {image.name}")
            try:
                image.user_clear()
            except Exception:
                pass
            try:
                bpy.data.images.remove(image)
            except Exception:
                pass

clear_scene()
root_path = src_dir / root_layer
print(f"Importing USD root: {root_path}")
bpy.ops.wm.usd_import(filepath=str(root_path))

scrub_hdr_images_from_blender()

before = tri_count()
print(f"Triangles before: {before:,}")

for obj in list(bpy.context.scene.objects):
    if obj.type != "MESH":
        continue

    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj

    mesh = obj.data

    # Remove extra color attributes. Keep UVs/materials.
    try:
        while len(mesh.color_attributes):
            mesh.color_attributes.remove(mesh.color_attributes[0])
    except Exception:
        pass

    # Keep first UV set only.
    try:
        while len(mesh.uv_layers) > 1:
            mesh.uv_layers.remove(mesh.uv_layers[-1])
    except Exception:
        pass

    try:
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_all(action="SELECT")
        bpy.ops.mesh.remove_doubles(threshold=0.0001)
        bpy.ops.mesh.normals_make_consistent(inside=False)
        bpy.ops.object.mode_set(mode="OBJECT")
    except Exception as e:
        print(f"Cleanup skipped for {obj.name}: {e}")
        try:
            bpy.ops.object.mode_set(mode="OBJECT")
        except Exception:
            pass

    mod = obj.modifiers.new("compress-usdz_decimate", "DECIMATE")
    mod.ratio = ratio
    try:
        bpy.ops.object.modifier_apply(modifier=mod.name)
    except Exception as e:
        print(f"Decimate skipped for {obj.name}: {e}")

after = tri_count()
print(f"Triangles after:  {after:,}")

scrub_hdr_images_from_blender()

print(f"Exporting reduced USDA: {output_usda}")
kwargs = usd_export_kwargs(output_usda)
print("USD export kwargs:", kwargs)
bpy.ops.wm.usd_export(**kwargs)
PY

  REDUCED_USDA="$EXPORT/reduced_raw.usda"
  CLEAN_USDA="$EXPORT/reduced_clean.usda"
  REDUCED_ROOT="$EXPORT/reduced.usd"
  ROOT_TO_PACKAGE="reduced.usd"
  REFS_FILE="$WORKDIR/asset_refs.txt"

  "$BLENDER" --background --python "$PY" -- "$SRC" "$ROOT_LAYER" "$REDUCED_USDA" "$DECIMATE"

  echo "Scrubbing unsupported HDR references and collecting texture refs..."
  python3 - "$REDUCED_USDA" "$CLEAN_USDA" "$REFS_FILE" <<'PY'
import re
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst = Path(sys.argv[2])
refs_out = Path(sys.argv[3])

text = src.read_text(encoding="utf-8", errors="replace")

# Remove lines that reference HDR files. This usually comes from Blender's
# generated environment/constant-color texture behavior.
clean_lines = []
for line in text.splitlines():
    if re.search(r'@[^@]*\.hdr@', line, flags=re.IGNORECASE):
        continue
    clean_lines.append(line)

clean = "\n".join(clean_lines) + "\n"

refs = []
for match in re.findall(r'@([^@]+\.(?:jpg|jpeg|png|exr|avif))@', clean, flags=re.IGNORECASE):
    normalized = match.replace("\\", "/")
    if normalized.startswith("./"):
        normalized = normalized[2:]
    if normalized not in refs:
        refs.append(normalized)

dst.write_text(clean, encoding="utf-8")
refs_out.write_text("\n".join(refs) + ("\n" if refs else ""), encoding="utf-8")

print(f"Texture refs: {len(refs)}")
for ref in refs:
    print(f"  {ref}")
PY

  if command -v usdcat >/dev/null 2>&1; then
    echo "Converting scrubbed USDA to USDC..."
    usdcat "$CLEAN_USDA" --usdFormat usdc -o "$REDUCED_ROOT"
  else
    echo "usdcat not found; packaging USDA instead of USDC."
    cp "$CLEAN_USDA" "$EXPORT/reduced.usda"
    ROOT_TO_PACKAGE="reduced.usda"
  fi

  echo "Preparing referenced assets..."
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    copy_ref_asset "$ref"
  done < "$REFS_FILE"

  echo "Packaging with usdzip..."
  (
    cd "$EXPORT"
    files=("$ROOT_TO_PACKAGE")

    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      [ -f "$ref" ] || continue
      files+=("$ref")
    done < "$REFS_FILE"

    usdzip "$OUTPUT" "${files[@]}"
  )
else
  echo "Repackaging texture-optimized original with usdzip..."
  files=()
  files+=("$ROOT_LAYER")
  while IFS= read -r item; do
    [ "$item" = "$ROOT_LAYER" ] && continue
    [ -f "$SRC/$item" ] || continue
    files+=("$item")
  done < <(unzip -Z -1 "$INPUT")

  (
    cd "$SRC"
    usdzip "$OUTPUT" "${files[@]}"
  )
fi

echo "Done: $OUTPUT ($(size_mb "$OUTPUT"))"

echo "Package methods/order:"
unzip -lv "$OUTPUT" | sed -n '1,18p'

if [ "$CHECK" = "1" ]; then
  if command -v usdchecker >/dev/null 2>&1; then
    echo "Running usdchecker --arkit..."
    usdchecker --arkit "$OUTPUT" || true
    echo "Running usdchecker..."
    usdchecker "$OUTPUT" || true
  else
    echo "usdchecker not found; skipping validation."
  fi
else
  echo "Skipping usdchecker. Use --check to validate."
fi

if [ "$PREVIEW" = "1" ]; then
  echo "Opening in Quick Look/Preview..."
  open "$OUTPUT" >/dev/null 2>&1 || true
else
  echo "Skipping preview. Use --preview to open output."
fi
