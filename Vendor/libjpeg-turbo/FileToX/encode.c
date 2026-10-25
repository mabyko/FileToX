// FileToX shim (not part of libjpeg-turbo). The C# helper wrote JPEG through Magick.NET 14.17.2 = ImageMagick
// 7.1.2-32 Q8 with libjpeg-turbo 3.2.0; this repeats coders/jpeg.c WriteJPEGImage_ for the settings Filee used
// (no jpeg:* defines, no interlace, image->quality from the preset): baseline, Huffman tables optimized, the IJG
// tables scaled by jpeg_set_quality, 4:4:4 from quality 90 (unless the source JPEG's sampling is kept), the fast
// integer DCT up to quality 90, JFIF density from the resolution, then the profiles.

#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <limits.h>

#include "jpeglib.h"
#include "CJpegTurbo.h"

typedef struct {
    struct jpeg_error_mgr pub;
    jmp_buf recovery;
    volatile int cancelled;
} ErrorManager;

typedef struct {
    struct jpeg_progress_mgr pub;
    int (*cancelled)(void);
} DecodeProgress;

static void decode_progress(j_common_ptr info) {
    DecodeProgress *progress = (DecodeProgress *)info->progress;
    if (progress->cancelled && progress->cancelled()) {
        ErrorManager *error = (ErrorManager *)info->err;
        error->cancelled = 1;
        longjmp(error->recovery, 1);
    }
}

static void error_exit(j_common_ptr info) {
    longjmp(((ErrorManager *)info->err)->recovery, 1);
}

// Warnings only become ImageMagick exceptions; the file is written anyway.
static void emit_message(j_common_ptr info, int level) {
    (void)info;
    (void)level;
}

static void write_marker(j_compress_ptr info, int marker, const unsigned char *data, size_t length, size_t chunk) {
    for (size_t i = 0; i < length; i += chunk)
        jpeg_write_marker(info, marker, data + i, (unsigned int)(length - i < chunk ? length - i : chunk));
}

// WriteProfiles: profiles in name order ("exif" < "icc" < "xmp"); ICC split into numbered APP2 chunks.
static void write_profiles(j_compress_ptr info, const FTXJpegImage *image) {
    if (image->exif && image->exif_length > 0 && image->exif_length <= 65533)
        jpeg_write_marker(info, JPEG_APP0 + 1, image->exif, (unsigned int)image->exif_length);
    if (image->icc && image->icc_length > 0) {
        unsigned char chunk[65535];
        memcpy(chunk, "ICC_PROFILE", 12);
        for (size_t i = 0; i < image->icc_length; i += 65519) {
            size_t length = image->icc_length - i < 65519 ? image->icc_length - i : 65519;
            chunk[12] = (unsigned char)(i / 65519 + 1);
            chunk[13] = (unsigned char)(image->icc_length / 65519 + (image->icc_length % 65519 != 0));
            memcpy(chunk + 14, image->icc + i, length);
            jpeg_write_marker(info, JPEG_APP0 + 2, chunk, (unsigned int)(length + 14));
        }
    }
    if (image->xmp && image->xmp_length > 0) {
        static const char namespace[] = "http://ns.adobe.com/xap/1.0/";
        size_t length = sizeof namespace + image->xmp_length;
        unsigned char *xmp = malloc(length);
        if (xmp == NULL) return;
        memcpy(xmp, namespace, sizeof namespace); // with its NUL
        memcpy(xmp + sizeof namespace, image->xmp, image->xmp_length);
        write_marker(info, JPEG_APP0 + 1, xmp, length, 65533);
        free(xmp);
    }
}

int ftx_jpeg_decode(const unsigned char *data, unsigned long length, unsigned char **pixels,
                    int *width, int *height, int *components, int (*cancelled)(void)) {
    struct jpeg_decompress_struct info;
    ErrorManager error;
    DecodeProgress progress = {0};
    error.cancelled = 0;
    memset(&info, 0, sizeof info);
    *pixels = NULL;
    *width = *height = *components = 0;
    info.err = jpeg_std_error(&error.pub);
    error.pub.error_exit = error_exit;
    error.pub.emit_message = emit_message;
    if (setjmp(error.recovery)) {
        jpeg_destroy_decompress(&info);
        free(*pixels);
        *pixels = NULL;
        return error.cancelled ? 2 : 1;
    }
    jpeg_create_decompress(&info);
    // Progressive entropy decoding happens inside start_decompress, before any output scanline exists.
    progress.pub.progress_monitor = decode_progress;
    progress.cancelled = cancelled;
    info.progress = &progress.pub;
    jpeg_mem_src(&info, data, length);
    jpeg_read_header(&info, TRUE);
    // Higher precision retains ImageIO; libjpeg exposes both CMYK and YCCK as four CMYK samples.
    if (info.data_precision != 8 || (info.out_color_space != JCS_RGB && info.out_color_space != JCS_GRAYSCALE && info.out_color_space != JCS_CMYK)) {
        jpeg_destroy_decompress(&info);
        return 1;
    }
    // ReadJPEGImage leaves DCT, fancy upsampling and block smoothing at libjpeg's defaults.
    jpeg_start_decompress(&info);
    size_t stride = (size_t)info.output_width * info.output_components;
    if (!stride || !info.output_height || info.output_width > INT_MAX || info.output_height > INT_MAX ||
        info.output_height > SIZE_MAX / stride || (*pixels = malloc(stride * info.output_height)) == NULL) {
        jpeg_destroy_decompress(&info);
        return 1;
    }
    while (info.output_scanline < info.output_height) {
        if (cancelled && cancelled()) {
            jpeg_destroy_decompress(&info);
            free(*pixels);
            *pixels = NULL;
            return 2;
        }
        JSAMPROW row = *pixels + (size_t)info.output_scanline * stride;
        jpeg_read_scanlines(&info, &row, 1);
        // Adobe JPEG stores inverted CMYK (including YCCK); CGImage holds conventional ink amounts.
        if (info.out_color_space == JCS_CMYK && info.saw_Adobe_marker)
            for (size_t i = 0; i < stride; i++) row[i] = 255 - row[i];
    }
    jpeg_finish_decompress(&info);
    *width = (int)info.output_width;
    *height = (int)info.output_height;
    *components = info.output_components;
    jpeg_destroy_decompress(&info);
    return 0;
}

int ftx_jpeg_encode(const FTXJpegImage *image, unsigned char **data, unsigned long *length, char *message) {
    struct jpeg_compress_struct info;
    ErrorManager error;
    memset(&info, 0, sizeof info);
    info.err = jpeg_std_error(&error.pub);
    error.pub.error_exit = error_exit;
    error.pub.emit_message = emit_message;
    *data = NULL;
    *length = 0;
    if (!image->skia && image->icc && image->icc_length > 65519u * 255u) {
        snprintf(message, 200, "ICC profile exceeds JPEG's 255 marker limit.");
        return 1;
    }
    if (setjmp(error.recovery)) {
        (*info.err->format_message)((j_common_ptr)&info, message);
        jpeg_destroy_compress(&info);
        free(*data);
        *data = NULL;
        return 1;
    }
    jpeg_create_compress(&info);
    jpeg_mem_dest(&info, data, length);
    info.image_width = (JDIMENSION)image->width;
    info.image_height = (JDIMENSION)image->height;
    info.input_components = image->skia ? 3 : image->components;
    info.in_color_space = info.input_components == 4 ? JCS_CMYK : info.input_components == 1 ? JCS_GRAYSCALE : JCS_RGB;
    info.data_precision = 8;
    jpeg_set_defaults(&info);
    if (info.in_color_space == JCS_CMYK) jpeg_set_colorspace(&info, JCS_YCCK);
    if (image->skia) {
        // SkJpegEncoderMgr::initializeRGB: defaults (4:2:0, JDCT_ISLOW, JFIF 1x1 with no unit), optimize_coding,
        // jpeg_set_quality(quality, TRUE). Skia feeds RGBA/BGRA; libjpeg-turbo converts those like RGB.
        info.optimize_coding = TRUE;
        jpeg_set_quality(&info, image->quality, TRUE);
        jpeg_start_compress(&info, TRUE);
        size_t stride = (size_t)image->width * 3;
        while (info.next_scanline < info.image_height) {
            JSAMPROW row = (JSAMPROW)(image->pixels + (size_t)info.next_scanline * stride);
            jpeg_write_scanlines(&info, &row, 1);
        }
        jpeg_finish_compress(&info);
        jpeg_destroy_compress(&info);
        return 0;
    }
    if (image->x_density > 0 && image->x_density < 32767 && image->y_density > 0 && image->y_density < 32767) {
        UINT16 x = (UINT16)image->x_density, y = (UINT16)image->y_density;
        if (x > 0 && y > 0) {
            info.write_JFIF_header = TRUE;
            info.X_density = x;
            info.Y_density = y;
            if (image->density_unit == 1 || image->density_unit == 2) info.density_unit = (UINT8)image->density_unit;
        }
    }
    // jpeg:optimize-coding is not set: ImageMagick optimizes whenever the memory resource allows it.
    info.optimize_coding = TRUE;
    int quality = image->quality >= 1 && image->quality <= 100 ? image->quality : 92;
    jpeg_set_quality(&info, quality, TRUE);
    if (quality <= 90) info.dct_method = JDCT_IFAST;
    if (image->sampling_count > 0) {
        int i = 0;
        for (; i < image->sampling_count && i < MAX_COMPONENTS; i++) {
            info.comp_info[i].h_samp_factor = image->h_sampling[i];
            info.comp_info[i].v_samp_factor = image->v_sampling[i];
        }
        for (; i < MAX_COMPONENTS; i++) info.comp_info[i].h_samp_factor = info.comp_info[i].v_samp_factor = 1;
    } else if (quality >= 90) {
        for (int i = 0; i < MAX_COMPONENTS; i++) info.comp_info[i].h_samp_factor = info.comp_info[i].v_samp_factor = 1;
    }
    jpeg_start_compress(&info, TRUE);
    write_profiles(&info, image);
    size_t stride = (size_t)image->width * (size_t)info.input_components;
    while (info.next_scanline < info.image_height) {
        JSAMPROW row = (JSAMPROW)(image->pixels + (size_t)info.next_scanline * stride);
        jpeg_write_scanlines(&info, &row, 1);
    }
    jpeg_finish_compress(&info);
    jpeg_destroy_compress(&info);
    return 0;
}

#define FTX_STRING(x) #x
#define FTX_VERSION(x) FTX_STRING(x)

const char *ftx_jpeg_version(void) {
    return FTX_VERSION(LIBJPEG_TURBO_VERSION);
}
