Tutorials
=========

Runnable, self-verifying tutorials for authoring GPU shaders **in daslang** and
driving them through dasVulkan. Each shader is written in daslang and lowered to
SPIR-V at compile time by `dasSpirv <https://github.com/GaijinEntertainment/daScript>`_
(no GLSL, no glslang) -- the same language as the host, compute and graphics alike.

The series builds **graphics → compute → 3D scene → instancing → environment →
GPU-driven scene → multi-pass → modern pipeline → mesh shaders → ray tracing**: :doc:`01_triangle` is the canonical
hello-triangle, :doc:`02_mandelbrot` and :doc:`03_sdf` swap to the compute pipeline,
:doc:`04_cube` takes graphics into 3D with depth + UBO + push constant + texture,
:doc:`05_instancing` draws 1000 cubes in one call, :doc:`06_skybox` wraps the scene in
a cubemap, :doc:`07_particles` hands the vertex stream itself to a compute shader,
:doc:`08_shadow` runs two render passes per frame sharing one depth image,
:doc:`09_msaa` drops VkRenderPass entirely in favour of Vulkan 1.3 dynamic rendering plus
4× MSAA with auto-resolve, :doc:`10_deferred` brings everything together
in a three-pass deferred renderer (sampled G-buffer) with SSAO + shadow + many lights,
and :doc:`11_hdr` adds an HDR offscreen target + Karis-style five-level bloom
pyramid + ACES tonemap composite for the post-process rail.
:doc:`12_gpu_driven` hands the draw decision to the GPU: a compute shader does
Hi-Z occlusion culling, compacts survivors into an indirect-draw buffer with a
GPU-written count, and ``cmd_draw_indexed_indirect_count`` draws them with bindless
materials. Finally
:doc:`13_mesh` and :doc:`14_teapot` drop the vertex buffer entirely for the
GPU-driven **mesh-shader** pipeline -- cluster culling, then on-GPU Bezier
tessellation of the Utah teapot. Finally :doc:`15_raytracing` leaves the
rasterizer behind for **hardware ray tracing**: acceleration structures, a
``VK_KHR_ray_tracing_pipeline``, and a traced shadow ray per hit -- raygen,
miss, and closest-hit shaders all authored in daslang.
Each tutorial's `Next` footer links to the one after.

Every tutorial lives in its own self-contained directory under ``tutorials/`` in
the repository: the shaders, the offscreen render, a **pixel-oracle test** that is
the lavapipe CI regression gate, and a recording driver that renders the embedded
``.mp4``. The render behind each video is pixel-checked **every CI run** by the
tutorial's oracle test; the ``.mp4`` is the documentation figure of that same
verified render, regenerated manually with the local recording driver (which needs
stbimage + audio + ffmpeg, so it does not run in CI). The mesh-shader tutorials
(:doc:`13_mesh`, :doc:`14_teapot`) soft-skip on CI's software renderer, which
lacks ``VK_EXT_mesh_shader``, and :doc:`15_raytracing` soft-skips there too
(no ``VK_KHR_ray_tracing_pipeline``); 13_mesh's figure is a still image rather
than a video.

.. toctree::
   :maxdepth: 1

   01_triangle
   02_mandelbrot
   03_sdf
   04_cube
   05_instancing
   06_skybox
   07_particles
   08_shadow
   09_msaa
   10_deferred
   11_hdr
   12_gpu_driven
   13_mesh
   14_teapot
   15_raytracing
