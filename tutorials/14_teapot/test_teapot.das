options gen2
options indenting = 4

// Tutorial 14 pixel-oracle gate (lavapipe in CI when it advertises VK_EXT_mesh_shader, real GPU
// locally). Renders the GPU-tessellated Newell teapot offscreen and asserts the silhouette is lit
// with the ceramic material where the teapot is, and background where it isn't -- proving the whole
// mesh-shader path (task cull -> per-patch Bezier tessellation -> shading) end to end. Includes a
// lid-knob check that guards the collapsed-control-net-patch regression (the knob's apex rows are
// single points, which used to NaN the cull and drop the knob entirely).
//
// If the device lacks VK_EXT_mesh_shader (an older lavapipe), the test soft-skips rather than failing.

require dastest/testing_boost public
require teapot_tut

def private is_background(c : int3) : bool {
    return c.x < 30 && c.y < 30 && c.z < 30
}

//! The teapot is shaded with a warm ceramic (r > g > b) lit material; the background is dark blue-grey.
def private is_ceramic_lit(c : int3) : bool {
    return c.x > 120 && c.x > c.y && c.y > c.z
}

[test]
def test_teapot_render(t : T?) {
    if (!mesh_shader_available()) {
        feint("VK_EXT_mesh_shader not advertised by this device; skipping (CI lavapipe may predate 24.1)\n")
        return
    }
    var pixels <- render_teapot(0.7)
    // body / upper body / spout / handle are lit with the ceramic material -- proves the patches
    // tessellate + shade and that the backface cull did not punch holes in the visible surface.
    t |> success(is_ceramic_lit(px(pixels, 256, 290)), "teapot body is lit ceramic ({px(pixels, 256, 290)})")
    t |> success(is_ceramic_lit(px(pixels, 256, 255)), "teapot upper body is lit ceramic ({px(pixels, 256, 255)})")
    t |> success(is_ceramic_lit(px(pixels, 360, 235)), "teapot spout is lit ceramic ({px(pixels, 360, 235)})")
    t |> success(is_ceramic_lit(px(pixels, 110, 275)), "teapot handle is lit ceramic ({px(pixels, 110, 275)})")
    // lid knob present (collapsed-patch regression guard): the knob box is full, not background.
    var knob_lit = 0
    for (y in range(185, 212)) {
        for (x in range(238, 274)) {
            if (!is_background(px(pixels, x, y))) {
                knob_lit ++
            }
        }
    }
    t |> success(knob_lit > 200, "lid knob renders (knob-box lit pixels = {knob_lit}, expect ~500)")
    // background around the teapot
    t |> success(is_background(px(pixels, 10, 10)), "top-left corner is background")
    t |> success(is_background(px(pixels, 500, 500)), "bottom-right corner is background")
    t |> success(is_background(px(pixels, 256, 150)), "above the teapot is background")
    t |> success(is_background(px(pixels, 256, 475)), "below the teapot is background")
    delete pixels
}
