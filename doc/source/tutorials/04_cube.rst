04 - The Synthwave Cube (graphics + depth)
==========================================

The first two tutorials drew with the **graphics** pipeline (triangle) and the
**compute** pipeline (Mandelbrot). This one is the first to need the whole
graphics-with-depth surface: a textured 3D cube, lit, with a depth attachment
so back faces are correctly hidden behind front faces. The headline rails:

- a **per-vertex buffer** with position + uv + normal -- ``a_pos`` / ``a_uv`` /
  ``a_normal`` flow in through ``@in @location`` stage inputs instead of being
  fabricated from ``gl_VertexIndex``;
- a **uniform buffer** with the view and projection matrices plus the camera
  position (and time);
- a **push constant** carrying the per-frame model matrix;
- a **combined image sampler** of a procedural synthwave horizon texture
  generated on the host at init;
- **depth test and write** (``D32_SFLOAT`` attachment, ``LESS_OR_EQUAL``);
- ``normalize`` / ``dot`` / ``pow`` from GLSL.std.450 for the rim + key lighting.

Every line of the shader is daslang, lowered to SPIR-V at compile time by dasSpirv.

.. video:: cube.mp4

The clip above is the headless recording: 30 seconds, 30 fps, captured into an
APNG and ffmpeg-muxed with a daStrudel supersaw-pad bed and a Kokoro voiceover.
The camera orbits the cube on a lemniscate (small vertical figure-8 over the
revolution) while the cube breathes via the push-constant scale; the texture's
sun-disk drifts via a UV scroll keyed off ``cam_time.w``. See
``skills/recording.md``.

The shaders
-----------

A struct UBO with two ``float4x4`` and one ``float4`` member is the canonical
std140 layout. The push constant is a single ``float4x4`` model matrix at offset
0 -- vertex-only, 64 bytes (well under the 128-byte push-constant minimum
guarantee). The fragment shader reads ``cam.cam_time`` to fold the camera
position into the view direction and the time into the UV scroll. The
``[vulkan_*_shader]`` annotations synthesise two host-side helpers from
``var @uniform cam : Camera`` and ``var @push_constant pc : ModelPC``:
``cube_vs_bind_uniform(device, memory)`` writes each std140 field at its
computed offset into a mapped UBO, and ``cube_vs_push_constants(cmd, layout)``
does the ``vkCmdPushConstants`` call. The host writes ``cam.* = ...`` and
``pc.model = ...`` and calls the helpers -- one source of truth for the
layout, no manual ``push_from`` / ``upload_bytes`` packing.

.. literalinclude:: ../../../tutorials/04_cube/cube_tut_shaders.das
   :language: das
   :start-at: module cube_tut_shaders

The render (headless)
---------------------

``render_synthwave_cube(time, camera_t)`` is the one-shot path used by the
test: build a fresh ``CubeContext`` and render one frame. The recording driver
uses ``build_cube_context()`` once and calls ``render_cube_frame(ctx, ...)`` in
a loop -- the long-lived state (instance, device, render pass, framebuffer,
vertex / index / UBO buffers, texture image+view+sampler, descriptor + pipeline
layouts, pipeline, readback buffer) is rebuilt once; the per-frame work is just
``cam.view = ...; cam.proj = ...; cam.cam_time = ...; cube_vs_bind_uniform(...)``
for the UBO and ``pc.model = ...; cube_vs_push_constants(...)`` for the
per-frame model matrix, then drawing 36 indexed vertices and copying the
colour attachment back. No window required.

.. literalinclude:: ../../../tutorials/04_cube/cube_tut.das
   :language: das
   :start-at: def public render_cube_frame
   :end-before: //! One-shot:

Self-verifying
--------------

The test is the CI regression gate (lavapipe in CI, a real GPU locally). The
cube has no analytic-symmetry shortcut the way Mandelbrot did; instead the
oracle asserts a handful of structural properties at a fixed (``time``,
``camera_t``): the frame corners are the dark clear colour, the central 200x200
box is dominantly the cube, and the lit region carries the synthwave palette
(at least one magenta-dominant pixel from the sky band, at least one
cyan-dominant pixel from the perspective grid).

.. literalinclude:: ../../../tutorials/04_cube/test_cube.das
   :language: das
   :start-at: [test]

Running it
----------

.. code-block:: bash

   # the CI pixel-oracle gate (lavapipe in CI, real GPU locally)
   daslang -load_module <dasVulkan> <daslang>/dastest/dastest.das -- \
       --test <dasVulkan>/tutorials/04_cube
