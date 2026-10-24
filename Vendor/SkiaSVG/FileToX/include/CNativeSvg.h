#ifndef FILETOX_NATIVE_SVG_H
#define FILETOX_NATIVE_SVG_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Synchronous RGBA8 premultiplied sRGB into caller-owned width*height*4 bytes.
   Width/height must equal ceil(viewport * scale). No pointers are retained. 0=success, 1=invalid bounds, 2=parse, 3=cancelled, 4=render/allocation.
   Cancellation is checked before/after parse and after drawing; drawing itself is not interruptible. */
int ftx_svg_render(const void *xml, size_t length, float viewport_width, float viewport_height,
                   float scale, int width, int height, void *pixels, size_t capacity,
                   int (*cancelled)(void *), void *context);
#ifdef __cplusplus
}
#endif
#endif
