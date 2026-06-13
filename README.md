# dasVulkan

Vulkan bindings for [daslang](https://dascript.org/), generated from the Khronos `vk.xml` registry.

- **`vulkan`** — the raw binding: the full Vulkan API surface (core + extensions), generated as a daslang C++ module dispatching through [volk](https://github.com/zeux/volk).
- **`vulkan_boost`** — the ergonomic layer: ownership-tracking handles with `finalize`, idiomatic structs (arrays instead of count+pointer pairs, auto-filled `sType`), named arguments with defaults, and block-bracketing helpers.

The binding generator is itself written in daslang (`generator/`), parsing `vk.xml` with `dasPUGIXML`.

## Status

Early development. Nothing to see here yet.

## Vendored dependencies

| What | Version | License |
|---|---|---|
| [volk](https://github.com/zeux/volk) | vulkan-sdk-1.4.350.0 | MIT |
| [Vulkan-Headers](https://github.com/KhronosGroup/Vulkan-Headers) (headers + `registry/vk.xml`) | vulkan-sdk-1.4.350.0 | Apache-2.0 / MIT |

Building the module requires no Vulkan SDK — the vendored headers and volk's runtime loading cover it. The LunarG SDK (validation layers, glslang) is recommended for development.

## Acknowledgements

Two earlier daScript Vulkan binding projects informed the design (clean-room — patterns, not code):

- [e-dog/dasVulkan](https://github.com/e-dog/dasVulkan) — vk.xml-driven generation over volk.
- [olegus8/dasVulkan](https://github.com/olegus8/dasVulkan) — the boost-layer ergonomics (ownership-tracked handles, view structs, the simple-app frame loop).

## License

MIT
