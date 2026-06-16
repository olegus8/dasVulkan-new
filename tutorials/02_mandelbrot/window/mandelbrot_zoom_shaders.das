options gen2
options indenting = 4

// The animated viewer shader (live windows only -- the headless render + CI oracle use the static
// mandelbrot_tut_shaders.das). A port of Inigo Quilez's smooth-coloured Mandelbrot zoom
// (https://www.shadertoy.com/view/ldf3DN): the whole animation is driven by one float -- a
// @push_constant time -- from which the shader derives an oscillating zoom and a slow rotation about
// the seahorse-valley point (-0.745, 0.186). Continuous (smooth) iteration count kills the banding;
// an iq cosine palette colours it. Every line is daslang, lowered to SPIR-V by dasSpirv -- it uses
// imageSize (size off the bound image), module-scope `let` constants (MAX_ITER / ESCAPE2), the
// GLSL.std.450 math rail (cos/sin/pow/log2) and a compute push constant.

module mandelbrot_zoom_shaders shared public

require spirv/spirv_shader
require spirv/spirv_builtins public
require math

var @binding = 0 out_img : image2D

//! the square render resolution (multiple of 8). The host needs one number for the image extent.
let public ZOOM_DIM = 768
let MAX_ITER = 512
let ESCAPE2 = 65536.0f      // B*B with the iq bailout radius B = 256
let AA = 2                  // 2x2 supersampling: AA*AA colour samples per pixel, averaged

// the single animation parameter, pushed each frame from wall-clock time
struct Push {
    time : float
}
var @push_constant pc : Push

[compute_shader(local_size_x=8, local_size_y=8, name="mandelbrot_zoom_spv")]
def mandelbrot_zoom {
    let gid = gl_GlobalInvocationID
    let dim = imageSize(out_img)
    // animated zoom (oscillates) + slow rotation, both derived from time, shared by all subsamples
    let t = pc.time
    let zoo0 = 0.62f + 0.38f * cos(0.07f * t)
    let ang = 0.15f * (1.0f - zoo0) * t
    let coa = cos(ang)
    let sia = sin(ang)
    let zoo = pow(zoo0, 8.0f)
    // average AA*AA subpixel colour samples (supersampling antialiasing). Interior samples stay black
    // and contribute nothing, so set-boundary pixels soften correctly.
    var col = float3(0.0f, 0.0f, 0.0f)
    for (s in range(AA * AA)) {
        // subpixel offset within the pixel: a centred AAxAA grid
        let fx = float(gid.x) + (float(s % AA) + 0.5f) / float(AA)
        let fy = float(gid.y) + (float(s / AA) + 0.5f) / float(AA)
        // screen-normalised coords, y in [-1,1] (iq's p = (-res + 2*frag)/res.y), then zoom + rotate
        let px = (2.0f * fx - float(dim.x)) / float(dim.y)
        let py = (2.0f * fy - float(dim.y)) / float(dim.y)
        let xr = px * coa - py * sia
        let yr = px * sia + py * coa
        let cx = -0.745f + xr * zoo
        let cy = 0.186f + yr * zoo
        // cheap interior tests: skip the iteration inside the main cardioid and the period-2 bulb (iq)
        let c2 = cx * cx + cy * cy
        let interior = ((256.0f * c2 * c2 - 96.0f * c2 + 32.0f * cx - 3.0f < 0.0f) ||
                        (16.0f * (c2 + 2.0f * cx + 1.0f) - 1.0f < 0.0f))
        if (interior) {
            continue
        }
        // escape-time iteration with a large bailout radius (needed for smooth colouring)
        var zx = 0.0f
        var zy = 0.0f
        var n = 0
        while (n < MAX_ITER) {
            let nzx = zx * zx - zy * zy + cx
            let nzy = 2.0f * zx * zy + cy
            zx = nzx
            zy = nzy
            if (zx * zx + zy * zy > ESCAPE2) {
                break
            }
            n++
        }
        // bounded after the loop -> interior -> black (contributes nothing)
        let d = zx * zx + zy * zy
        if (d > ESCAPE2) {
            // continuous iteration count -> smooth bands, then the iq cosine palette
            let sn = float(n) - log2(log2(d)) + 4.0f
            let phase = 3.0f + sn * 0.15f
            col = col + float3(0.5f + 0.5f * cos(phase), 0.5f + 0.5f * cos(phase + 0.6f), 0.5f + 0.5f * cos(phase + 1.0f))
        }
    }
    let coord = int2(int(gid.x), int(gid.y))
    let avg = col * (1.0f / float(AA * AA))
    imageStore(out_img, coord, float4(avg, 1.0f))
}
