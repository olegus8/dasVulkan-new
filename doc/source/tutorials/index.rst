Tutorials
=========

Runnable, self-verifying tutorials for authoring GPU shaders **in daslang** and
driving them through dasVulkan. Each shader is written in daslang and lowered to
SPIR-V at compile time by `dasSpirv <https://github.com/GaijinEntertainment/daScript>`_
(no GLSL, no glslang) -- the same language as the host, compute and graphics alike.

The series builds **graphics → compute → 3D scene → instancing → environment →
GPU-driven scene → multi-pass**: :doc:`01_triangle` is the canonical hello-triangle,
:doc:`02_mandelbrot` and :doc:`03_sdf` swap to the compute pipeline, :doc:`04_cube`
takes graphics into 3D with depth + UBO + push constant + texture, :doc:`05_instancing`
draws 1000 cubes in one call, :doc:`06_skybox` wraps the scene in a cubemap,
:doc:`07_particles` hands the vertex stream itself to a compute shader, and
:doc:`08_shadow` runs two render passes per frame sharing one depth image.
Each tutorial's `Next` footer links to the one after.

Every tutorial lives in its own self-contained directory under ``tutorials/`` in
the repository: the shaders, the offscreen render, a **pixel-oracle test** that is
the lavapipe CI regression gate, and a recording driver that renders the embedded
``.mp4``. The render behind each video is pixel-checked **every CI run** by the
tutorial's oracle test; the ``.mp4`` is the documentation figure of that same
verified render, regenerated manually with the local recording driver (which needs
stbimage + audio + ffmpeg, so it does not run in CI).

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
