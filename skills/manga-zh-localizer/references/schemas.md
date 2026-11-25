# JSON Schemas & Examples for `manga-zh-localizer`

## 1. `crops.json` (Optional input for `grid_inspect.ps1 -CropsJson`)

```json
[
  { "name": "crop_detail_inset.png", "x": 0, "y": 0, "w": 266, "h": 358 },
  { "name": "panel2_16x9.png", "x": 0, "y": 417, "w": 740, "h": 416 }
]
```

---

## 2. `clean_plan.json` (Input for `clean_bubbles.ps1`)

Each operation targets pixel box `[x0, y0, x1, y1]` (inclusive):

```json
{
  "operations": [
    {
      "id": "narration_box",
      "type": "solid_rect",
      "box": [656, 0, 739, 322],
      "rgb": [255, 255, 255]
    },
    {
      "id": "flat_grey_auto_sample",
      "type": "solid_rect",
      "box": [120, 4032, 1480, 4260],
      "sample": [130, 4040]
    },
    {
      "id": "tight_glow_polygon",
      "type": "poly_fill",
      "points": [[60, 140], [150, 140], [142, 230], [58, 224]],
      "rgb": [230, 230, 230]
    },
    {
      "id": "vertical_gradient_or_rim",
      "type": "copy_col",
      "box": [410, 1980, 560, 2140],
      "src_x": 405
    },
    {
      "id": "horizontal_stripe_or_wall",
      "type": "copy_row",
      "points": [[200, 300], [340, 300], [340, 360], [200, 360]],
      "src_y": 295
    },
    {
      "id": "sfx_over_speedlines",
      "type": "copy_along_dir",
      "points": [[820, 1660], [990, 1640], [1005, 1735], [835, 1755]],
      "dir": [1.0, -0.118],
      "side": "pos",
      "only_dark": false,
      "dark_thresh": 185,
      "dilate": 2,
      "max_steps": 260
    },
    {
      "id": "screentone_phase_patch",
      "type": "patch_copy",
      "box": [420, 610, 510, 740],
      "offset": [96, 0],
      "auto_align": true,
      "search_radius": 4,
      "only_dark": false
    },
    {
      "id": "repair_broken_bubble_rim",
      "type": "draw_lines",
      "lines": [
        {
          "points": [[1117, 480], [1148, 534], [1182, 591]],
          "width": 3.2,
          "rgb": [0, 0, 0],
          "smooth": true
        }
      ]
    },
    {
      "id": "beige_sfx",
      "type": "interp_v",
      "box": [594, 22, 628, 68],
      "pad": 4
    },
    {
      "id": "main_white_bubble",
      "type": "white_bubble",
      "box": [234, 86, 344, 318],
      "seed": [295, 105],
      "thresh": 220
    },
    {
      "id": "edge_cropped_white_bubble",
      "type": "white_bubble",
      "box": [9, 48, 56, 198],
      "seed": [28, 62],
      "thresh": 215,
      "open_side": "left"
    },
    {
      "id": "black_bubble_keep_sweat",
      "type": "black_bubble",
      "box": [45, 20, 103, 138],
      "seed": [70, 26],
      "thresh": 80,
      "fill_rgb": [10, 10, 10],
      "keep_rects": [
        [76, 89, 12, 13],
        [70, 111, 13, 14]
      ]
    },
    {
      "id": "colored_bubble_example",
      "type": "color_flood",
      "box": [100, 200, 300, 400],
      "seed": [150, 250],
      "tol": 32
    },
    {
      "id": "dark_translucent_bubble_anchored",
      "type": "translucent_anchored",
      "box": [698, 1030, 834, 1665],
      "black_max": 70,
      "halo_radius": 11,
      "iters": 420,
      "dir": [0.0, 0.0]
    },
    {
      "id": "light_translucent_bubble_dark_text",
      "type": "translucent_dark",
      "box": [928, 840, 988, 1390],
      "dark_thresh": 175,
      "dilate": 4,
      "iters": 420,
      "dir": [0.2, 1.0]
    }
  ]
}
```

Field notes for v4 clean ops:
- `solid_rect`: accepts either explicit `"rgb": [r, g, b]` or `"sample": [x, y]` (picks exact pixel color from the image).
- `poly_fill`: fills the polygon defined by `"points": [[x, y], ...]` with explicit `"rgb"` (defaults to `[255, 255, 255]`); ideal for tightly hugging strokes or two-tone grey/white glow curves.
- `copy_col` / `copy_row`: accepts `"box"` or `"points"`; copies every pixel vertically from column `"src_x"` (preserves horizontal lines & vertical gradients) or horizontally from row `"src_y"` (preserves vertical lines & horizontal gradients).
- `copy_along_dir`: accepts `"box"` or `"points"`; traces along `"dir": [dx, dy]` to the clean exterior on `"side": "pos" | "neg" | "both"` (`max_steps` default `260`) using bilinear sampling to restore uninterrupted speedlines or slanted wall lines. Set `"only_dark": true` to replace only dark glyph strokes (`dark_thresh` default `185`, `dilate` default `2`).
- `patch_copy`: accepts `"box"` or `"points"`; copies a 2D texture/screentone patch from `(x + offset[0], y + offset[1])`. With `"auto_align": true` (default), automatically searches `[-search_radius..+search_radius]` (default `4`) along the 3px clean exterior ring to phase-lock halftone dot grids with zero moiré/seams. Optional `"only_dark": true` (`dark_thresh`, `dilate`) replaces only dark glyph pixels.
- `draw_lines`: draws anti-aliased polylines or smooth splines (`"smooth": true` uses GDI+ `DrawCurve`) for each item in `"lines"` (`points`, `width`, `rgb`), ideal for repairing tiny broken bubble borders after erasing overlapping SFX.
- Pass `-DiffOut <diff.jpg>` to `clean_bubbles.ps1` to emit a pixel-diff heatmap (magenta = strong edit `>=45`, cyan = subtle tonal shift `10..44` such as grey-bubble bleaching).

---

## 3. `rois.json` (Input for `roi_composite.ps1`)

- `mode: "glyph_diff"` (default): Detects only removed text strokes inside `box: [x0, y0, x1, y1]`, dilates by `dilate` px, and feathers smoothly onto the original lossless image. Supports `"polarity": "dark"` (default, dark text on light bg), `"light"` (white text on dark bg), or `"both"`.
- `mode: "full_roi"`: Feathers the entire rectangle (`feather` px edge blend), ideal when an AI image editor redrew stylized Chinese art titles or large SFX.

```json
{
  "rois": [
    { "name": "panel2_left_text",  "box": [0, 430, 118, 724],   "mode": "glyph_diff", "dilate": 5, "inner": 3.2 },
    { "name": "panel2_right_text", "box": [428, 430, 554, 708], "mode": "glyph_diff", "dilate": 5, "inner": 3.2 }
  ]
}
```

---

## 4. `layout.json` (Input for `render_typeset.ps1`)

- `rect`: `[x, y, width, height]` in exact image pixel coordinates.
- `direction`: `"vertical"` (default, Japanese manga right-to-left columns) or `"horizontal"`.
- `preset`: `"dialogue"` (`YaHei` 700) | `"narration"` (`YaHei` 700) | `"scream"` (`SimHei` 700) | `"serif"` (`STZhongsong` 400) | `"handwritten"` (`STKaiti` 400) | `"round"` (`YouYuan` 400, soft OS / chibi) | `"brush"` (`STXingkai` 400, dramatic calligraphy) | `"note"` (`YaHei` 400). Recommended defaults: `line_height` `1.20–1.33` (default `1.30`), `letter_spacing` `0`.
- `align`: `"center"` (default) or `"top"` (vertical align inside rect).
- `halo`: `true` or CSS rgba string for soft background glow on pastel/bokeh overlays.
- `optical_center`: `true` enables C# `LockBits` post-render optical ink centering (compensates for `vertical-rl` font metric asymmetry, `letter-spacing`, and `col_offsets`, while strictly excluding neighboring block rects). When `snap_to_bubble` is enabled (default), it also detects the enclosed single bubble cavity in `clean.png` via Chamfer 3-4 Distance Transform and collision-safely snaps ink center onto the true cavity optical center (`cav=(x,y)`), reporting `WARN_OFFCENTER` if offset exceeds 6px.
- `snap_to_bubble`: `true` (default when `optical_center: true`) or `false`. Set `false` ONLY for unclosed radial/open-background bubbles (which might enclose against a distant panel wall), asymmetric narrow vertical scream bubbles with an upper bulge, or manually split multi-lobe ("snowman") chambers; when `false`, `optical_center` snaps strictly to `rect` center and suppresses spurious `WARN_OFFCENTER`.
- `stroke`: `{"color": "#ffffff", "width": 2}` for spike-free 24-angle 0-blur circular outline (rendered at 2× SS; pass `"style": "miter"` only if sharp `-webkit-text-stroke` joins are explicitly desired).
- `col_offsets`: per-column pixel top-padding (vertical) or left-padding (horizontal) to match organic bubble contours.
- Vertical punctuation (`「」『』（）【】《》……—～`) and double marks (`⁉`, `‼`, `！？`) are auto-formatted by `render_typeset.ps1`.

```json
{
  "meta": {
    "title": "Sample Comic Chapter 01",
    "series": "sample-series"
  },
  "blocks": [
    {
      "id": 1,
      "rect": [656, 12, 83, 306],
      "align": "top",
      "preset": "narration",
      "font_size": 30,
      "line_height": 1.26,
      "letter_spacing": 6,
      "lines": ["放学后的", "咖啡馆日常"]
    },
    {
      "id": 2,
      "rect": [598, 24, 26, 48],
      "preset": "handwritten",
      "font_size": 18,
      "color": "#2b2623",
      "letter_spacing": 0,
      "rotate": -8,
      "text": "唔…"
    },
    {
      "id": 3,
      "rect": [240, 102, 98, 204],
      "preset": "dialogue",
      "font_size": 21.5,
      "line_height": 1.30,
      "optical_center": true,
      "col_offsets": [12, 0, 14],
      "lines": ["呜呜……", "汤汁果然还是", "溅出来了呢"]
    },
    {
      "id": 4,
      "rect": [438, 438, 112, 254],
      "align": "top",
      "preset": "narration",
      "font_size": 25.5,
      "line_height": 1.32,
      "letter_spacing": 1.5,
      "halo": true,
      "lines": ["怎么了", "怕弄脏衣服", "不敢吃了吗？"]
    }
  ]
}
```
