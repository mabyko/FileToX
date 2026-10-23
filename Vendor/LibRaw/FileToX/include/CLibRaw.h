// FileToX's C interface to LibRaw (not part of LibRaw): develops a camera RAW file exactly the way the C# helper did
// through Magick.NET, i.e. ImageMagick 7's DNG coder with Filee's read defines. See ../develop.c.

#ifndef FILETOX_CLIBRAW_H
#define FILETOX_CLIBRAW_H

/// A developed picture: 8-bit samples, rows top to bottom, not yet turned upright.
typedef struct {
    /// width × height × colors samples, malloc'ed: the caller frees them.
    unsigned char *pixels;
    int width;
    int height;
    /// 1 = gray, 3 = RGB (sRGB); 2 and 4 carry alpha last, like ImageMagick reads them.
    int colors;
    /// EXIF orientation ImageMagick records for the picture (0 = undefined), applied later by AutoOrient.
    int orientation;
} FTXRawImage;

/// Develops the RAW file at `path` (camera white balance, no auto white balance, sRGB, AHD, auto-brightness) into
/// 8 bits like ImageMagick Q8. Returns 0 or a LibRaw error code (see ftx_libraw_strerror); `image` is only filled on 0.
int ftx_libraw_develop(const char *path, FTXRawImage *image);

const char *ftx_libraw_strerror(int error);

/// "0.22.2-Release".
const char *ftx_libraw_version(void);

#endif
