#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;
[[ stitchable ]] half4 tint(float2 p, half4 c, float t) {
    return half4(half(fract(p.x / 100 + t)), half(0.5), half(0.2), 1);
}
