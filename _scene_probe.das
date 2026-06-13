options gen2
require vulkan
require tests/integration/scene_helpers.das
[export]
def main() {
    if (volkInitialize() != 0) { print("no vk
"); return }
    var p <- render_triangle()
    print("got {length(p)} bytes
")
    delete p
    print("scene probe OK
")
}
