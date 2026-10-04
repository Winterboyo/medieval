"""Original herringbone paving texture for the village paths (REALISM-TARGET.md).

Run inside Blender: exec this file, then bpy.app.driver_namespace["herringbone"]["render"](out_dir).
Writes Color.png, Normal.png and Roughness.png (1024 px, seamless) for a Roblox MaterialVariant.

Pattern: axis-aligned herringbone of 2 x 1 bricks. On a grid of unit cells, a horizontal brick
starts at every cell with (x - y) % 4 == 0 and covers (x, y), (x + 1, y); a vertical brick covers
(x, y) and (x, y - 1) for every cell with (x - y) % 4 == 2. This tiles the plane with period 4 in
both axes, so a texture CELLS wide (a multiple of 4) is seamless.

Colours aim at The Forge's plaza tile as rendered (lum ~108-130, sat ~0.16-0.20). The albedo is
cool on purpose: the Gritty preset's warm light scales R, G, B by about 0.93, 0.84, 0.69 (measured in
Studio on the first, neutral-grey version), so a blue-grey brick renders as neutral grey stone.
Mortar is recessed in the normal map.
"""
import bpy, os
import numpy as np

SIZE = 1024
CELLS = 16                  # cells across the texture; one brick = 2 x 1 cells
MORTAR = 0.07               # mortar half-width, in cells
BEVEL = 0.16                # brick edge bevel width, in cells
SEED = 20261003

BRICK = np.array([131, 136, 151], dtype=np.float64)    # sRGB
BRICK_LIGHT = np.array([150, 156, 172], dtype=np.float64)
BRICK_DARK = np.array([110, 114, 128], dtype=np.float64)
MORTAR_COL = np.array([80, 82, 92], dtype=np.float64)


def _hash(a, b):
    h = ((int(a) * 73856093) ^ (int(b) * 19349663) ^ SEED) & 0xFFFFFFFF
    h = ((h ^ (h >> 13)) * 1274126177) & 0xFFFFFFFF
    return ((h ^ (h >> 16)) & 0xFFFF) / 65535.0


def _value_noise(u, v, freq, seed):
    """Seamless value noise on the unit square, `freq` lattice cells across."""
    rng = np.random.default_rng(seed)
    lat = rng.random((freq, freq))
    x, y = u * freq, v * freq
    x0, y0 = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = x - x0, y - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    x0, y0, x1, y1 = x0 % freq, y0 % freq, (x0 + 1) % freq, (y0 + 1) % freq
    a = lat[y0, x0] * (1 - fx) + lat[y0, x1] * fx
    b = lat[y1, x0] * (1 - fx) + lat[y1, x1] * fx
    return a * (1 - fy) + b * fy


def build():
    px = (np.arange(SIZE) + 0.5) / SIZE
    u, v = np.meshgrid(px, px)                 # v down the image
    gx, gy = u * CELLS, v * CELLS
    cx, cy = np.floor(gx).astype(int), np.floor(gy).astype(int)
    r = (cx - cy) % 4
    # brick rectangle (x0, y0, w, h) in cells for every pixel
    x0 = np.where(r == 1, cx - 1, cx)
    y0 = np.where(r == 2, cy - 1, cy)
    w = np.where(r < 2, 2, 1)
    h = np.where(r < 2, 1, 2)
    # distance to the brick's edge, in cells
    d = np.minimum.reduce([gx - x0, x0 + w - gx, gy - y0, y0 + h - gy])
    # per-brick tone (wrapped ids keep it seamless)
    ids = np.vectorize(_hash)(x0 % CELLS, y0 % CELLS)
    tone = np.where(ids[..., None] < 0.5,
                    BRICK_DARK + (BRICK - BRICK_DARK) * (ids[..., None] * 2),
                    BRICK + (BRICK_LIGHT - BRICK) * ((ids[..., None] - 0.5) * 2))
    grain = _value_noise(u, v, 64, SEED + 1) * 0.6 + _value_noise(u, v, 256, SEED + 2) * 0.4
    wear = _value_noise(u, v, 6, SEED + 3)
    col = tone * (0.9 + 0.2 * grain[..., None])
    col = col * (0.94 + 0.1 * wear[..., None])
    in_mortar = d < MORTAR
    edge = np.clip((d - MORTAR) / BEVEL, 0, 1)
    col = np.where(in_mortar[..., None], MORTAR_COL * (0.9 + 0.2 * grain[..., None]), col * (0.82 + 0.18 * edge[..., None]))
    # height: mortar 0, bevel ramp, brick top 1 with slight grain
    height = np.where(in_mortar, 0.0, np.sqrt(edge) * (0.92 + 0.08 * grain))
    # normal from height (wrapping finite differences, so seamless)
    strength = 6.0
    dx = (np.roll(height, -1, axis=1) - np.roll(height, 1, axis=1)) * strength
    dy = (np.roll(height, -1, axis=0) - np.roll(height, 1, axis=0)) * strength
    n = np.stack([-dx, dy, np.ones_like(dx)], axis=-1)   # +Y up (OpenGL); image v runs down
    n /= np.linalg.norm(n, axis=-1, keepdims=True)
    normal = (n * 0.5 + 0.5) * 255
    rough = np.where(in_mortar, 0.95, 0.78 + 0.12 * grain) * 255
    return col, normal, np.repeat(rough[..., None], 3, axis=-1)


def _save(rgb, path):
    img = bpy.data.images.new(os.path.basename(path), SIZE, SIZE, alpha=False)
    rgba = np.concatenate([np.clip(rgb, 0, 255) / 255.0, np.ones((SIZE, SIZE, 1))], axis=-1)
    img.pixels.foreach_set(rgba[::-1].astype(np.float32).ravel())   # Blender rows run bottom-up
    img.filepath_raw = path
    img.file_format = "PNG"
    img.save()
    bpy.data.images.remove(img)


def render(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    col, normal, rough = build()
    _save(col, os.path.join(out_dir, "Color.png"))
    _save(normal, os.path.join(out_dir, "Normal.png"))
    _save(rough, os.path.join(out_dir, "Roughness.png"))
    return sorted(os.listdir(out_dir))


bpy.app.driver_namespace["herringbone"] = dict(build=build, render=render)
