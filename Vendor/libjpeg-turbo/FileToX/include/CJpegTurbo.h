// FileToX's C interface to libjpeg-turbo (not part of libjpeg-turbo): writes a JPEG the way the C# helper's
// ImageMagick 7.1.2-32 (coders/jpeg.c, WriteJPEGImage) did with Filee's settings. See ../encode.c.

#ifndef FILETOX_CJPEGTURBO_H
#define FILETOX_CJPEGTURBO_H

#include <stddef.h>

/// What ImageMagick knew about the picture when it wrote it.
typedef struct {
    /// width × height × components 8-bit samples, rows top to bottom: 1 = gray, 3 = RGB.
    const unsigned char *pixels;
    int width;
    int height;
    int components;
    /// ImageMagick's image->quality, 1…100 (0 = undefined: ImageMagick's default 92).
    int quality;
    /// Resolution (image->resolution, image->units): 0 = none; unit 1 = per inch, 2 = per centimetre, 0 = undefined.
    double x_density;
    double y_density;
    int density_unit;
    /// Sampling factors of the source JPEG (ImageMagick's "jpeg:sampling-factor" property), h/v per component;
    /// sampling_count 0 when the picture did not come from a JPEG of the same colour type.
    int sampling_count;
    int h_sampling[4];
    int v_sampling[4];
    /// Profiles written as APP markers in ImageMagick's (alphabetical) order; NULL/0 when absent.
    /// `exif` includes the "Exif\0\0" header; `xmp` is the bare XMP packet.
    const unsigned char *exif;
    size_t exif_length;
    const unsigned char *icc;
    size_t icc_length;
    const unsigned char *xmp;
    size_t xmp_length;
    /// Nonzero: write like Skia's SkJpegEncoder (SkiaSharp 3.119, the C# helper's comic pages and PDF scans) instead
    /// of ImageMagick: always three components, 4:2:0, the slow integer DCT, optimized Huffman tables, JFIF with no
    /// density, no profiles. Only `pixels`, `width`, `height` and `quality` are read.
    int skia;
} FTXJpegImage;

/// Encodes `image`. On success returns 0 and a malloc'ed buffer in `*data` (the caller frees it); otherwise returns
/// nonzero and libjpeg's message in `message` (at least 200 bytes).
int ftx_jpeg_encode(const FTXJpegImage *image, unsigned char **data, unsigned long *length, char *message);

/// "3.2.0".
const char *ftx_jpeg_version(void);

#endif
