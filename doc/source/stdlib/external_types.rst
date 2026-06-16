.. _stdlib_vulkan_external_types_section:

##############
External types
##############

Types defined by the raw ``vulkan`` binding and the generated ``vulkan_structs``
view module that the documented boost surface references but does not own. The
raw layer mirrors the Vulkan C API 1:1 and is not re-documented here — see the
`Vulkan specification <https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html>`_
for the authoritative field-by-field reference. This page anchors the labels so
the generated boost pages can link without dangling references.

Core enums
==========

.. _enum-vulkan-vkresult:

``vulkan::VkResult``
--------------------

Return code for almost every Vulkan command. ``VK_SUCCESS`` is ``0``; negative
values are errors. The boost ``create_*`` / command wrappers run it through
``vk_check`` — left to default they panic on a non-success code, or forward it
to a caller-supplied ``var result : VkResult?``.

.. _enum-vulkan-vkformat:

``vulkan::VkFormat``
--------------------

Pixel / vertex-attribute format enum (``VK_FORMAT_R8G8B8A8_UNORM``, …). Passed to
image, image-view, render-pass, and swapchain creation.

.. _enum-vulkan-vkimagelayout:

``vulkan::VkImageLayout``
-------------------------

Image memory layout (``VK_IMAGE_LAYOUT_UNDEFINED``,
``VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL``, …) used in render passes and
barriers.

.. _enum-vulkan-vkpipelinebindpoint:

``vulkan::VkPipelineBindPoint``
-------------------------------

Selects which bind point a pipeline / descriptor set binds to —
``GRAPHICS`` or ``COMPUTE``. The trailing ``bind_point`` argument to
``cmd_bind_pipeline`` (defaults to ``GRAPHICS``).

.. _enum-vulkan-vkcompareop:

``vulkan::VkCompareOp``
-----------------------

Per-fragment comparison operator (``LESS``, ``LESS_OR_EQUAL``, ``EQUAL``,
``GREATER_OR_EQUAL``, …). Used by the depth-stencil state on a graphics
pipeline — the ``depth_compare_op`` argument to
``create_graphics_pipeline_v3d`` (defaults to ``LESS_OR_EQUAL`` for the
standard z-buffer convention).

Core handles and aliases
========================

.. _alias-vkphysicaldevice:

``vulkan::VkPhysicalDevice``
----------------------------

Raw non-owning handle for a physical GPU, returned by ``select_physical_device``
and consumed by device creation and memory queries. Has no RAII wrapper (it is
owned by the instance, not created or destroyed).

.. _alias-vkqueue:

``vulkan::VkQueue``
-------------------

Raw non-owning handle for a device queue, returned by ``get_device_queue``.
Owned by the device; no separate destroy.

.. _alias-vkmemorypropertyflags:

``vulkan::VkMemoryPropertyFlags``
---------------------------------

Bitfield of memory-property bits (``DEVICE_LOCAL``, ``HOST_VISIBLE``,
``HOST_COHERENT``, …) used by ``find_memory_type`` to pick a heap.

.. _alias-vkimage:

``vulkan::VkImage``
-------------------

Raw non-owning handle for an image. The owning RAII wrapper is ``Image``;
the swapchain's images and the raw handle handed to ``present_frame``'s
record block are bare ``VkImage`` handles.

.. _alias-vkaccessflags:

``vulkan::VkAccessFlags``
-------------------------

Bitfield of memory-access bits (``shader_write``, ``transfer_read``,
``transfer_write``, …). The source/destination access masks of a pipeline
barrier; consumed by ``transition_image``.

.. _alias-vkpipelinestageflags:

``vulkan::VkPipelineStageFlags``
--------------------------------

Bitfield of pipeline-stage bits (``top_of_pipe``, ``compute_shader``,
``transfer``, ``fragment_shader``, …). The source/destination stage masks of
a pipeline barrier; consumed by ``transition_image``.

.. _handle-vulkan-vkclearvalue:

``vulkan::VkClearValue``
------------------------

Union of a clear color or depth/stencil value. ``clear_color`` builds one;
``record_render_pass`` consumes it.

.. _handle-vulkan-vkrect2d:

``vulkan::VkRect2D``
--------------------

An ``offset`` + ``extent`` rectangle. ``full_area`` builds one covering the
whole target; used as the render-pass render area.

.. _handle-vulkan-vkvertexinputbindingdescription:

``vulkan::VkVertexInputBindingDescription``
-------------------------------------------

One per vertex buffer bound by ``vkCmdBindVertexBuffers``: the binding slot,
the stride between vertices, and whether the rate is per-vertex or
per-instance. Consumed by ``create_graphics_pipeline_v3d`` as
``vertex_bindings``.

.. _handle-vulkan-vkvertexinputattributedescription:

``vulkan::VkVertexInputAttributeDescription``
---------------------------------------------

One per per-vertex attribute the vertex shader reads (``@in @location = N``):
the location, the source binding slot, the format, and the byte offset
within the vertex. Consumed by ``create_graphics_pipeline_v3d`` as
``vertex_attributes``.

``vulkan_structs`` view structs
===============================

.. _struct-vulkan_structs-accelerationstructurecreateinfo2khr:
.. _struct-vulkan_structs-accelerationstructurecreateinfokhr:
.. _struct-vulkan_structs-buffercreateinfo:
.. _struct-vulkan_structs-bufferviewcreateinfo:
.. _struct-vulkan_structs-commandpoolcreateinfo:
.. _struct-vulkan_structs-cufunctioncreateinfonvx:
.. _struct-vulkan_structs-datagraphpipelinesessioncreateinfoarm:
.. _struct-vulkan_structs-descriptorpoolcreateinfo:
.. _struct-vulkan_structs-descriptorsetlayoutcreateinfo:
.. _struct-vulkan_structs-descriptorupdatetemplatecreateinfo:
.. _struct-vulkan_structs-displaymodecreateinfokhr:
.. _struct-vulkan_structs-displaysurfacecreateinfokhr:
.. _struct-vulkan_structs-eventcreateinfo:
.. _struct-vulkan_structs-externalcomputequeuecreateinfonv:
.. _struct-vulkan_structs-fencecreateinfo:
.. _struct-vulkan_structs-framebuffercreateinfo:
.. _struct-vulkan_structs-headlesssurfacecreateinfoext:
.. _struct-vulkan_structs-imagecreateinfo:
.. _struct-vulkan_structs-imageviewcreateinfo:
.. _struct-vulkan_structs-indirectcommandslayoutcreateinfoext:
.. _struct-vulkan_structs-indirectexecutionsetcreateinfoext:
.. _struct-vulkan_structs-memoryallocateinfo:
.. _struct-vulkan_structs-micromapcreateinfoext:
.. _struct-vulkan_structs-opticalflowsessioncreateinfonv:
.. _struct-vulkan_structs-pipelinelayoutcreateinfo:
.. _struct-vulkan_structs-privatedataslotcreateinfo:
.. _struct-vulkan_structs-querypoolcreateinfo:
.. _struct-vulkan_structs-samplercreateinfo:
.. _struct-vulkan_structs-samplerycbcrconversioncreateinfo:
.. _struct-vulkan_structs-semaphorecreateinfo:
.. _struct-vulkan_structs-shaderinstrumentationcreateinfoarm:
.. _struct-vulkan_structs-swapchaincreateinfokhr:
.. _struct-vulkan_structs-tensorviewcreateinfoarm:
.. _struct-vulkan_structs-videosessionparameterscreateinfokhr:

``vulkan_structs::*CreateInfo``
-------------------------------

The idiomatic *view* structs accepted by the ``create_*`` creators on the
:doc:`generated/vulkan_commands` page. Each shadows the matching Vulkan
``Vk*CreateInfo`` struct with daslang-friendly fields: ``array<T>`` instead of
count+pointer pairs, ``string`` instead of ``const char*``, boost handle types
instead of raw ones, and ``sType`` filled automatically. Because they are
generated 1:1 from ``vk.xml``, their fields are documented field-by-field in the
`Vulkan specification <https://registry.khronos.org/vulkan/specs/latest/html/vkspec.html>`_;
see :doc:`overview` for the view-struct mechanism.
