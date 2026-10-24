#include "include/CNativeSvg.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkColorSpace.h"
#include "include/core/SkSurface.h"
#include "include/core/SkStream.h"
#include "modules/svg/include/SkSVGDOM.h"
#include <cmath>
#include <cstdint>
#include <cstddef>
#include <exception>
extern "C" int ftx_svg_render(const void* xml, size_t length, float viewport_width, float viewport_height,
                             float scale, int width, int height, void* pixels, size_t capacity,
                             int (*cancelled)(void*), void* context) {
    if (!xml || !pixels || length == 0 || length > 8*1024*1024 ||
        !std::isfinite(viewport_width) || !std::isfinite(viewport_height) || !std::isfinite(scale) ||
        viewport_width <= 0 || viewport_height <= 0 || scale <= 0 || width <= 0 || height <= 0 ||
        width > 16384 || height > 16384 || int64_t(width)*height > 100000000 ||
        size_t(width)*4*size_t(height) > capacity) return 1;
    const float pixel_width = std::ceil(viewport_width * scale), pixel_height = std::ceil(viewport_height * scale);
    if (!std::isfinite(pixel_width) || !std::isfinite(pixel_height) || pixel_width != width || pixel_height != height) return 1;
    auto is_cancelled = [&] { return cancelled && cancelled(context); };
    try {
        if (is_cancelled()) return 3;
        SkMemoryStream input(xml, length, false);
        // The default provider cannot read files or network resources; Swift admits only self-contained primitives.
        auto dom = SkSVGDOM::Builder().make(input);
        if (!dom) return 2;
        if (is_cancelled()) return 3;
        dom->getRoot()->setWidth(SkSVGLength(viewport_width));
        dom->getRoot()->setHeight(SkSVGLength(viewport_height));
        dom->setContainerSize(SkSize::Make(viewport_width, viewport_height));
        const auto info = SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType, SkColorSpace::MakeSRGB());
        auto surface = SkSurfaces::WrapPixels(info, pixels, size_t(width)*4);
        if (!surface) return 4;
        auto canvas = surface->getCanvas();
        canvas->clear(SK_ColorTRANSPARENT);
        canvas->scale(scale, scale);
        dom->render(canvas);
        return is_cancelled() ? 3 : 0;
    } catch (...) { return 4; }
}
