Tutorials
=========

Runnable, self-verifying tutorials for authoring GPU shaders **in daslang** and
driving them through dasVulkan. Each shader is written in daslang and lowered to
SPIR-V at compile time by `dasSpirv <https://github.com/GaijinEntertainment/daScript>`_
(no GLSL, no glslang) -- the same language as the host, compute and graphics alike.

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
