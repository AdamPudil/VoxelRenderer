#!/usr/bin/env python3
"""Export every Goxel layer to assets/blocks/<id>_<gox>_<layer>.{vox,block}.

Requires: python3 -m pip install Pillow
Goxel .gox format reference: https://github.com/guillaumechereau/goxel/blob/master/src/formats/gox.c
"""
from __future__ import annotations

import argparse
import io
import json
import re
import struct
import sys
from pathlib import Path
from PIL import Image

I32 = struct.Struct('<i')
U32 = struct.Struct('<I')
TILE_SIZE = 16


def identifier(text: str) -> str:
    text = re.sub(r'[^\w]+', '_', text.strip().lower(), flags=re.UNICODE)
    return text.strip('_') or 'unnamed'


def read_dict(data: bytes, offset: int) -> dict[str, bytes]:
    attrs = {}
    while offset < len(data):
        if offset + 4 > len(data):
            raise ValueError('Truncated GOX dictionary')
        n = I32.unpack_from(data, offset)[0]
        offset += 4
        if n == 0:
            break
        if n < 0 or offset + n + 4 > len(data):
            raise ValueError('Invalid GOX dictionary key')
        key = data[offset:offset+n].decode('utf-8', 'replace')
        offset += n
        length = I32.unpack_from(data, offset)[0]
        offset += 4
        if length < 0 or offset + length > len(data):
            raise ValueError('Invalid GOX dictionary value')
        attrs[key] = data[offset:offset+length]
        offset += length
    return attrs


def load_gox(path: Path):
    raw = path.read_bytes()
    if len(raw) < 8 or raw[:4] != b'GOX ':
        raise ValueError('Not a GOX file')
    version = I32.unpack_from(raw, 4)[0]
    if version not in (1, 2):
        raise ValueError(f'Unsupported GOX version: {version}')
    tiles: list[bytes] = []
    layers = []
    offset = 8
    while offset < len(raw):
        if offset + 12 > len(raw):
            raise ValueError('Truncated GOX chunk header')
        kind = raw[offset:offset+4]
        length = I32.unpack_from(raw, offset+4)[0]
        offset += 8
        if length < 0 or offset + length + 4 > len(raw):
            raise ValueError('Invalid GOX chunk length')
        body = raw[offset:offset+length]
        offset += length + 4  # Goxel does not check its chunk CRC
        if kind == b'BL16':
            with Image.open(io.BytesIO(body)) as image:
                if image.size != (64, 64):
                    raise ValueError(f'Unexpected tile PNG dimensions {image.size}')
                tiles.append(image.convert('RGBA').tobytes())
        elif kind == b'LAYR':
            if len(body) < 4:
                raise ValueError('Short LAYR chunk')
            count = I32.unpack_from(body)[0]
            if count < 0 or 4 + 20 * count > len(body):
                raise ValueError('Invalid LAYR tile count')
            entries = []
            for i in range(count):
                idx, x, y, z, _ = struct.unpack_from('<5i', body, 4 + i*20)
                if idx < 0 or idx >= len(tiles):
                    raise ValueError(f'Invalid GOX tile index {idx}')
                if version == 1:
                    x -= 8; y -= 8; z -= 8
                entries.append((idx, x, y, z))
            attrs = read_dict(body, 4 + count * 20)
            name = attrs.get('name', b'Layer').decode('utf-8', 'replace').strip('\0')
            # Non-raster layers need Goxel's renderer and cannot be extracted this way.
            if attrs.get('shape') or attrs.get('img-path') or int.from_bytes(attrs.get('base_id', b'\0'), 'little'):
                raise ValueError(f'Layer {name!r} uses procedural/clone/image content (unsupported)')
            layers.append((name, entries))
    return tiles, layers


def collect_voxels(tiles: list[bytes], entries: list[tuple[int, int, int, int]]):
    result: dict[tuple[int, int, int], tuple[int, int, int, int]] = {}
    for index, ox, oy, oz in entries:
        data = tiles[index]
        for z in range(16):
            for y in range(16):
                for x in range(16):
                    p = (x + 16 * y + 256 * z) * 4
                    rgba = tuple(data[p:p+4])
                    if rgba[3] != 0:
                        result[(ox+x, oy+y, oz+z)] = rgba
    return result


def vox_chunk(tag: bytes, content: bytes = b'', children: bytes = b'') -> bytes:
    return tag + struct.pack('<II', len(content), len(children)) + content + children


def make_vox(voxels: dict[tuple[int, int, int], tuple[int, int, int, int]]) -> tuple[bytes, tuple[int,int,int]]:
    coords = list(voxels)
    
    # Get actual occupied boundaries
    min_pos = tuple(min(p[a] for p in coords) for a in range(3))
    max_pos = tuple(max(p[a] for p in coords) for a in range(3))

    # Align boundaries to the 16-voxel block grid
    low = tuple((v // 16) * 16 for v in min_pos)
    high = tuple((v // 16) * 16 + 15 for v in max_pos)

    # Check actual dimensions of the occupied voxels
    actual_dims = tuple(high[a] - low[a] + 1 for a in range(3))

    if any(d > 16 for d in actual_dims):
        raise ValueError(
            f"Layer exceeds 16x16x16 voxel limit: "
            f"actual size {actual_dims[0]}x{actual_dims[1]}x{actual_dims[2]}"
        )
    dims = tuple(max(16, high[a] - low[a] + 1) for a in range(3))
    if any(d > 256 for d in dims):
        raise ValueError(f'Layer size {dims} exceeds a single VOX model (256 per axis)')
    palette = {}
    xyzi = bytearray()
    for pos, color in sorted(voxels.items()):
        # VOX palette supports 255 nonempty colors. Alpha zero means empty.
        if color not in palette:
            if len(palette) >= 255:
                raise ValueError('Layer uses over 255 distinct RGBA colors')
            palette[color] = len(palette) + 1
        xyz = [pos[a] - low[a] for a in range(3)]
        xyzi.extend(bytes((*xyz, palette[color])))
    rgba = bytearray(256*4)
    # RGBA stores color index 1 in its first slot, etc. Last slot reserved.
    for color, index in palette.items():
        rgba[(index-1)*4:index*4] = bytes(color)
    size_chunk = vox_chunk(b'SIZE', struct.pack('<III', *dims))
    xyzi_chunk = vox_chunk(b'XYZI', U32.pack(len(voxels)) + xyzi)
    rgba_chunk = vox_chunk(b'RGBA', rgba)
    main = vox_chunk(b'MAIN', b'', size_chunk + xyzi_chunk + rgba_chunk)
    return b'VOX ' + U32.pack(150) + main, dims


def load_manifest(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    obj = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(obj, dict) or any(not isinstance(k, str) or type(v) is not int or v < 100 for k,v in obj.items()):
        raise ValueError(f'Invalid manifest: {path}')
    if len(set(obj.values())) != len(obj):
        raise ValueError(f'Duplicate IDs in manifest: {path}')
    return obj


def preserved_rotation(path: Path) -> str:
    """Retain the authored placement mode when regenerating a descriptor."""
    if not path.exists():
        return ''
    rotation = None
    for line in path.read_text(encoding='utf-8').splitlines():
        key, colon, value = line.strip().partition(':')
        if not colon or key.strip().casefold() != 'rotation':
            continue
        if rotation is not None:
            raise ValueError(f'Duplicate rotation attribute: {path}')
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            value = value[1:-1]
        rotation = value.casefold()
        if rotation not in ('none', 'yaw'):
            raise ValueError(f'Invalid rotation attribute in {path}: {value!r}')
    return '' if rotation is None else f'rotation: {rotation}\n'


def run(args):
    source = args.source.resolve()
    dest = args.output.resolve()
    if not source.is_dir():
        raise ValueError(f'Input directory does not exist: {source}')
    inputs = sorted(source.rglob('*.gox'), key=lambda p: p.relative_to(source).as_posix().casefold())
    if not inputs:
        print(f'No .gox files found under {source}')
        return 0
    dest.mkdir(parents=True, exist_ok=True)
    manifest_file = dest / '.gox_block_ids.json'
    manifest = load_manifest(manifest_file)
    used = set(manifest.values())
    next_id = max(used | {99}) + 1
    exported = 0
    failures = 0
    filenames = set()
    for path in inputs:
        try:
            tiles, layers = load_gox(path)
        except (ValueError, OSError) as exc:
            print(f'ERROR {path}: {exc}', file=sys.stderr)
            failures += 1
            continue
        for layer_no, (layer_name, entries) in enumerate(layers):
            key = f'{path.relative_to(source).as_posix()}::{layer_no}'
            voxels = collect_voxels(tiles, entries)
            if not voxels:
                print(f'SKIP empty layer: {path.relative_to(source)} / {layer_name}')
                continue
            label = identifier(f'{path.stem}_{layer_name}')
            try:
                binary, dims = make_vox(voxels)
                block_id = manifest.get(key, next_id)
                if key not in manifest:
                    while block_id in used:
                        block_id += 1
                stem = f'{block_id}_{label}'
                if stem in filenames:
                    raise ValueError(f'Filename conflict: {stem} (rename a layer or GOX file)')
                filenames.add(stem)
                model_file = stem + '.vox'
                block_file = stem + '.block'
                rotation = preserved_rotation(dest / block_file)
                if not args.dry_run:
                    (dest / model_file).write_bytes(binary)
                    (dest / block_file).write_text(
                        f'name: {label.replace("_", " ").title()}\n'
                        f'variant: 0\n'
                        f'model: {model_file}\n'
                        f'{rotation}'
                        f'# Omit icon to render a 64x64 PNG with the engine.\n',
                        encoding='utf-8')
                    if key not in manifest:
                        manifest[key] = block_id
                        used.add(block_id)
                        next_id = block_id + 1
                print(f'{stem} ({len(voxels)} voxels, {dims})')
                exported += 1
            except (ValueError, OSError) as exc:
                print(f'ERROR {path.relative_to(source)} / {layer_name}: {exc}', file=sys.stderr)
                failures += 1
    if not args.dry_run:
        manifest_file.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(f'Exported {exported} blocks; {failures} errors. Output: {dest}')
    return 1 if failures else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path('assetDesign'), help='Root folder containing .gox files')
    parser.add_argument('--output', type=Path, default=Path('assets/blocks'), help='Destination folder')
    parser.add_argument('--dry-run', action='store_true', help='List exports without writing files')
    args = parser.parse_args()
    try:
        sys.exit(run(args))
    except (ValueError, OSError) as exc:
        parser.exit(1, f'Error: {exc}\n')
