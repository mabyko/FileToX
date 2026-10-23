// FileToX shim (not part of LibRaw). The C# helper read camera RAW through Magick.NET 14.17.2 = ImageMagick 7.1.2-32
// Q8, whose coders/dng.c drives LibRaw. This repeats that coder call for call with Filee's read defines
// (dng:use-camera-wb, use-auto-wb=false, output-color=1, interpolation-quality=3, no-auto-bright=false): the order
// matters, e.g. Olympus colours change when the parameters are set before libraw_open_file like dcraw_emu does.

#include <stdlib.h>

#include "CLibRaw.h"
#include "libraw/libraw.h"

// ImageMagick's LibRawFlipToOrientation (LibRaw's flip 5 and 8 swapped, everything else taken as is).
static int orientation(int flip) {
    return flip == 5 ? 8 : flip == 8 ? 5 : flip;
}

int ftx_libraw_develop(const char *path, FTXRawImage *image) {
    // LIBRAW_SHLIB_CURRENT >= 23, so ImageMagick passes only this flag. Its data-error handler only adds warnings.
    libraw_data_t *raw = libraw_init(LIBRAW_OPIONS_NO_DATAERR_CALLBACK);
    if (raw == NULL) return LIBRAW_UNSPECIFIED_ERROR;
    int error = libraw_open_file(raw, path);
    int flip = raw->sizes.flip; // read right after opening, before unpacking (ImageMagick's image->orientation)
    if (error == LIBRAW_SUCCESS) error = libraw_unpack(raw);
    if (error == LIBRAW_SUCCESS) {
        // SetLibRawParams, after libraw_unpack.
        raw->rawparams.max_raw_memory_mb = 8192;
        raw->params.user_flip = 0; // not rotated here: AutoOrient turns the picture later
        raw->params.output_bps = 16;
        raw->params.use_camera_wb = 1;
        raw->params.use_auto_wb = 0;
        raw->params.no_auto_bright = 0;
        raw->params.output_color = 1; // sRGB
        raw->params.user_qual = 3;    // AHD
        error = libraw_dcraw_process(raw);
    }
    libraw_processed_image_t *developed = NULL;
    if (error == LIBRAW_SUCCESS) developed = libraw_dcraw_make_mem_image(raw, &error);
    libraw_close(raw); // the processed image is a separate allocation
    if (error == LIBRAW_SUCCESS && (developed == NULL || developed->type != LIBRAW_IMAGE_BITMAP || developed->bits != 16 ||
                                    developed->colors < 1 || developed->colors > 4))
        error = LIBRAW_UNSPECIFIED_ERROR;
    if (error == LIBRAW_SUCCESS) {
        size_t count = (size_t)developed->width * developed->height * developed->colors;
        unsigned char *pixels = malloc(count);
        if (pixels == NULL) {
            error = LIBRAW_UNSUFFICIENT_MEMORY;
        } else {
            const unsigned short *samples = (const unsigned short *)developed->data;
            // ScaleShortToQuantum of ImageMagick Q8 (no HDRI).
            for (size_t i = 0; i < count; i++) pixels[i] = (unsigned char)((samples[i] + 128u) / 257u);
            *image = (FTXRawImage){pixels, developed->width, developed->height, developed->colors, orientation(flip)};
        }
    }
    libraw_dcraw_clear_mem(developed);
    return error;
}

const char *ftx_libraw_strerror(int error) {
    return libraw_strerror(error);
}

const char *ftx_libraw_version(void) {
    return libraw_version();
}
