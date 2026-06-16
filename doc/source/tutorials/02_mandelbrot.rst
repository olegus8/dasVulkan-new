02 - The Mandelbrot Set (compute)
=================================

The first tutorial drew a triangle with the graphics pipeline. This one computes
an image with the **compute** pipeline: a ``[compute_shader]`` runs one invocation
per pixel, maps the pixel to a complex number *c*, iterates ``z = z*z + c`` until it
escapes or hits an iteration cap, and writes a colour into a storage image. Every
line is **daslang**, lowered to SPIR-V at compile time by dasSpirv -- the escape-time
loop exercises the compute tier's control flow (``while`` + ``break``) and float
arithmetic. Two newer dasSpirv rails show up here: ``imageSize`` (the shader sizes its
pixel→complex mapping off the bound image) and module-scope ``let`` constants (the
view rectangle and iteration cap live at module scope and are shared with the host).

The shader
----------

A single ``[compute_shader]`` with an ``8x8`` local size. The output storage image is a
``var @binding = 0 out_img : image2D``; ``imageStore`` writes one texel per invocation.
The escape-time loop is ordinary daslang.

.. literalinclude:: ../../../tutorials/02_mandelbrot/mandelbrot_tut_shaders.das
   :language: das
   :start-at: module mandelbrot_tut_shaders

The render (headless)
---------------------

``render_mandelbrot()`` feeds the emitted ``mandelbrot_spv`` blob to dasVulkan's
``compute_to_storage_image`` boost helper: it creates the storage image, the
descriptor set and the compute pipeline, dispatches ``DIM/8 x DIM/8``, and reads the
result back to RGBA8 pixels on the host -- a pure ``() -> image``. This is what the
CI test checks; no window required.

.. literalinclude:: ../../../tutorials/02_mandelbrot/mandelbrot_tut.das
   :language: das
   :start-at: def public render_mandelbrot

Self-verifying
--------------

The test is the CI regression gate (lavapipe in CI, a real GPU locally). Instead of a
golden image it uses an **analytic oracle**: points inside the set never escape (black),
points well outside escape (coloured), and because *c* and its conjugate escape
identically, the image is mirror-symmetric across the real axis -- a float-robust check
on deep in/out pairs and reflected coordinates.

.. literalinclude:: ../../../tutorials/02_mandelbrot/test_mandelbrot.das
   :language: das
   :start-at: [test]

See it live -- two ways to present a compute result
---------------------------------------------------

The compute shader wrote its result into a *storage image*, off-screen. A triangle draws
itself straight into the swapchain through a render pass; a compute result does not -- it
has to get from that storage image onto the screen. There are two standard ways, and this
tutorial ships a runnable viewer for each. Both open a GLFW window and run the compute
shader exactly once (the fractal is static); they differ only in how the image reaches the
swapchain. They live in a ``window/`` subfolder the CI gate skips (CI is headless and built
without GLFW).

Both share the compute-once-into-a-resident-image step -- ``run_mandelbrot_compute`` creates
the storage image (``STORAGE`` + ``TRANSFER_SRC`` + ``SAMPLED`` usage, so either path can
consume it), dispatches once, and hands back the GPU-resident result in the ``GENERAL`` layout:

.. literalinclude:: ../../../tutorials/02_mandelbrot/window/mandelbrot_compute.das
   :language: das
   :start-at: def public run_mandelbrot_compute

Method 1 -- blit
~~~~~~~~~~~~~~~~~

The most direct route: ``vkCmdBlitImage`` copies the storage image straight onto the
acquired swapchain image (scaled to the window, linear filter), with no graphics pipeline,
no render pass and no fragment shader -- just a transfer. The acquire→record→submit→present
boilerplate is vulkan_window's ``present_frame`` (the non-render-pass sibling of
``draw_frame``); the two layout transitions and the blit are the whole body.

.. literalinclude:: ../../../tutorials/02_mandelbrot/window/show_mandelbrot_blit.das
   :language: das
   :start-at: let ok = present_frame
   :end-before: if (!ok)

Method 2 -- sample as a texture
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

The other route reuses the entire graphics path: draw one full-screen triangle whose
fragment shader **samples** the storage image as a texture. This is the canonical "compute
writes, graphics reads" pattern -- it goes through the ordinary render pass, so it reuses
``draw_frame``, the framebuffers and the graphics pipeline wholesale, adding only a sampler,
one combined-image-sampler descriptor, and two tiny shaders:

.. literalinclude:: ../../../tutorials/02_mandelbrot/window/mandelbrot_view_shaders.das
   :language: das
   :start-at: var @out @location = 0 v_uv

The draw is then just bind-pipeline, bind-descriptor-set, draw three vertices through
``draw_frame``. Blit is fewer moving parts; sample-as-texture is the one to grow from (a
real post-process or UI pass samples the same way).

Running it
----------

.. code-block:: bash

   # the CI pixel-oracle gate (lavapipe in CI, real GPU locally)
   daslang -load_module <dasVulkan> <daslang>/dastest/dastest.das -- \
       --test <dasVulkan>/tutorials/02_mandelbrot

   # watch it live -- method 1: blit straight to the swapchain
   daslang -load_module <dasVulkan> \
       <dasVulkan>/tutorials/02_mandelbrot/window/show_mandelbrot_blit.das

   # watch it live -- method 2: sample the result as a texture
   daslang -load_module <dasVulkan> \
       <dasVulkan>/tutorials/02_mandelbrot/window/show_mandelbrot_sampled.das
