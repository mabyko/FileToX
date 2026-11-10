// FileToX bridge; settings from ImageMagick 7.1.2-32 coders/jp2.c, WriteJP2Image.
#include "COpenJPEG.h"
#include "openjpeg.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <limits.h>

typedef struct {
    unsigned char *data;
    size_t length, position, capacity;
    int (*cancelled)(void);
} Buffer;

static int reserve(Buffer *b, size_t end) {
    if (b->cancelled && b->cancelled()) return 0;
    if (end > b->capacity) {
        size_t capacity = end <= SIZE_MAX / 2 ? end * 2 : end;
        unsigned char *data = realloc(b->data, capacity);
        if (!data) return 0;
        b->data = data;
        b->capacity = capacity;
    }
    if (end > b->length) {
        memset(b->data + b->length, 0, end - b->length);
        b->length = end;
    }
    return 1;
}
static OPJ_SIZE_T write_bytes(void *data, OPJ_SIZE_T length, void *user) {
    Buffer *b = user;
    if (length > SIZE_MAX - b->position || !reserve(b, b->position + length)) return (OPJ_SIZE_T)-1;
    memcpy(b->data + b->position, data, length);
    b->position += length;
    return length;
}
static OPJ_BOOL seek_bytes(OPJ_OFF_T position, void *user) {
    Buffer *b = user;
    if (position < 0 || (uint64_t)position > SIZE_MAX || !reserve(b, (size_t)position)) return OPJ_FALSE;
    b->position = (size_t)position;
    return OPJ_TRUE;
}
static OPJ_OFF_T skip_bytes(OPJ_OFF_T count, void *user) {
    Buffer *b = user;
    if (b->position > INT64_MAX || (count > 0 && (uint64_t)count > INT64_MAX - b->position)) return -1;
    return seek_bytes((OPJ_OFF_T)b->position + count, user) ? count : -1;
}
static void error_message(const char *text, void *user) { snprintf(user, 256, "%s", text); }

int ftx_j2k_encode(const void *samples, int width, int height, size_t stride, int channels,
                   int bits, int quality, unsigned char **data, size_t *length,
                   char *message, int (*cancelled)(void)) {
    *data = NULL; *length = 0;
    snprintf(message, 256, "JPEG 2000 encoding failed.");
    if (!samples || width < 1 || height < 1 || channels < 1 || channels > 4 ||
        (bits != 8 && bits != 16) || quality < 1 || quality > 100 ||
        (size_t)width > SIZE_MAX / channels / (bits / 8) ||
        stride < (size_t)width * channels * (bits / 8) || (size_t)height > SIZE_MAX / stride) return 1;
    opj_cparameters_t parameters;
    opj_set_default_encoder_parameters(&parameters);
    parameters.numresolution = 1;
    while (parameters.numresolution < 6 && width >= (1 << parameters.numresolution) && height >= (1 << parameters.numresolution)) parameters.numresolution++;
    parameters.tcp_numlayers = 1;
    parameters.tcp_rates[0] = 0;
    parameters.cp_disto_alloc = quality == 100;
    parameters.cp_fixed_quality = quality != 100;
    parameters.tcp_distoratio[0] = quality == 100 ? 0 : (float)quality;
    parameters.tcp_mct = channels == 3;
    opj_image_cmptparm_t component[4] = {{0}};
    for (int c = 0; c < channels; c++) {
        component[c].w = width; component[c].h = height;
        component[c].dx = component[c].dy = 1;
        component[c].prec = bits;
    }
    opj_image_t *image = opj_image_create(channels, component, channels < 3 ? OPJ_CLRSPC_GRAY : OPJ_CLRSPC_SRGB);
    opj_codec_t *codec = NULL;
    opj_stream_t *stream = NULL;
    Buffer buffer = { .cancelled = cancelled };
    int status = 1;
    if (!image) goto cleanup;
    image->x1 = width; image->y1 = height;
    if (channels == 2 || channels == 4) image->comps[channels - 1].alpha = 1;
    for (int y = 0; y < height; y++) {
        if (cancelled && cancelled()) goto cleanup;
        const unsigned char *row = (const unsigned char *)samples + (size_t)y * stride;
        for (int x = 0; x < width; x++) for (int c = 0; c < channels; c++) {
            uint16_t value;
            if (bits == 16) memcpy(&value, row + ((size_t)x * channels + c) * 2, 2);
            else value = row[(size_t)x * channels + c];
            image->comps[c].data[(size_t)y * width + x] = value;
        }
    }
    codec = opj_create_compress(OPJ_CODEC_J2K);
    if (!codec) goto cleanup;
    opj_set_error_handler(codec, error_message, message);
    if (!opj_setup_encoder(codec, &parameters, image)) goto cleanup;
    stream = opj_stream_create(65536, OPJ_FALSE);
    if (!stream) goto cleanup;
    opj_stream_set_user_data(stream, &buffer, NULL);
    opj_stream_set_write_function(stream, write_bytes);
    opj_stream_set_skip_function(stream, skip_bytes);
    opj_stream_set_seek_function(stream, seek_bytes);
    if (!opj_start_compress(codec, image, stream) || !opj_encode(codec, stream) || !opj_end_compress(codec, stream)) goto cleanup;
    status = 0;
cleanup:
    if (stream) opj_stream_destroy(stream);
    if (codec) opj_destroy_codec(codec);
    if (image) opj_image_destroy(image);
    if (cancelled && cancelled()) status = 2;
    if (status == 0) { *data = buffer.data; *length = buffer.length; }
    else free(buffer.data);
    return status;
}
