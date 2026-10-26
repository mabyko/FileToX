// FileToXAvifEncoder: writes one AVIF for the FileToX engine with libavif 1.4.2 + libaom 3.14.1 (Vendor/LibAVIF).
// A separate process because the libaom encode is one call with no abort hook: the engine's ProcessRunner kills this
// process to cancel, and the codec's memory and globals stay out of the engine.
//
// Usage: FileToXAvifEncoder <input> <output>
// <input> is a private hand-off file: a 64-byte little-endian header, then straight (not premultiplied) 8-bit RGB or
// RGBA samples, rows top to bottom, then the ICC profile, Exif (TIFF header first) and XMP bytes:
//   0 "FTXAVIF\0"   8 version (1)   12 width   16 height   20 channels (3 or 4)   24 quality (1-100)
//   28 flags (0)    32 ICC bytes (u64)   40 Exif bytes (u64)   48 XMP bytes (u64)   56 reserved (0, u64)
// <output> must not exist; it is created only after the encode succeeded.
// Exit status: 0 written, 2 invalid arguments or input, 3 out of memory, 4 encoding failed, 5 read or write failed.

#include "avif/avif.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { HEADER_SIZE = 64 };
// Larger than any real profile or metadata block (a JPEG carries at most 16.7 MB of ICC).
static const uint64_t maxMetadata = 64u << 20;

static uint32_t u32(const uint8_t * p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t u64(const uint8_t * p) { return (uint64_t)u32(p) | (uint64_t)u32(p + 4) << 32; }

static int fail(int status, const char * message, const char * detail)
{
    fprintf(stderr, "FileToXAvifEncoder: %s%s%s\n", message, detail && *detail ? ": " : "", detail ? detail : "");
    return status;
}

static int readAll(int fd, uint8_t * buffer, size_t size)
{
    while (size > 0) {
        ssize_t count = read(fd, buffer, size > (1u << 30) ? (1u << 30) : size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        buffer += count;
        size -= (size_t)count;
    }
    return 1;
}

static int writeAll(int fd, const uint8_t * buffer, size_t size)
{
    while (size > 0) {
        ssize_t count = write(fd, buffer, size > (1u << 30) ? (1u << 30) : size);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return 0;
        buffer += count;
        size -= (size_t)count;
    }
    return 1;
}

int main(int argc, char ** argv)
{
    if (argc != 3) return fail(2, "usage: FileToXAvifEncoder <input> <output>", NULL);

    int fd = open(argv[1], O_RDONLY | O_CLOEXEC);
    if (fd < 0) return fail(5, "cannot open the input", strerror(errno));
    struct stat info;
    uint8_t header[HEADER_SIZE];
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || !readAll(fd, header, HEADER_SIZE)) {
        close(fd);
        return fail(2, "the input has no header", NULL);
    }
    const uint32_t width = u32(header + 12), height = u32(header + 16), channels = u32(header + 20), quality = u32(header + 24);
    const uint64_t iccSize = u64(header + 32), exifSize = u64(header + 40), xmpSize = u64(header + 48);
    // libavif's default decoder limits, so every reader with default settings can open the result.
    if (memcmp(header, "FTXAVIF\0", 8) != 0 || u32(header + 8) != 1 || u32(header + 28) != 0 || u64(header + 56) != 0 ||
        width == 0 || height == 0 || width > AVIF_DEFAULT_IMAGE_DIMENSION_LIMIT || height > AVIF_DEFAULT_IMAGE_DIMENSION_LIMIT ||
        (uint64_t)width * height > AVIF_DEFAULT_IMAGE_SIZE_LIMIT || (channels != 3 && channels != 4) || quality < 1 || quality > 100 ||
        iccSize > maxMetadata || exifSize > maxMetadata || xmpSize > maxMetadata) {
        close(fd);
        return fail(2, "the input header is invalid", NULL);
    }
    // At most 2^30 sample bytes plus 3 * 2^26 metadata bytes: no overflow in 64 bits.
    const uint64_t sampleSize = (uint64_t)width * height * channels;
    const uint64_t payloadSize = sampleSize + iccSize + exifSize + xmpSize;
    if (info.st_size < 0 || (uint64_t)info.st_size != HEADER_SIZE + payloadSize) {
        close(fd);
        return fail(2, "the input size does not match its header", NULL);
    }
    uint8_t * payload = malloc((size_t)payloadSize);
    if (!payload) {
        close(fd);
        return fail(3, "out of memory", NULL);
    }
    const int complete = readAll(fd, payload, (size_t)payloadSize);
    close(fd);
    if (!complete) {
        free(payload);
        return fail(5, "cannot read the input", NULL);
    }
    const uint8_t * icc = payload + sampleSize;
    const uint8_t * exif = icc + iccSize;
    const uint8_t * xmp = exif + exifSize;

    int status = 4;
    const char * stage = "";
    avifResult result = AVIF_RESULT_OK;
    avifRWData encoded = AVIF_DATA_EMPTY;
    avifEncoder * encoder = NULL;
    avifImage * image = avifImageCreate(width, height, 8, AVIF_PIXEL_FORMAT_YUV444);
    if (!image) {
        free(payload);
        return fail(3, "out of memory", NULL);
    }
    image->yuvRange = AVIF_RANGE_FULL;
    image->matrixCoefficients = AVIF_MATRIX_COEFFICIENTS_BT601;
    // With a profile the colour comes from it (the nclx box then only describes the YUV matrix and range); without one
    // the samples are sRGB.
    image->colorPrimaries = iccSize ? AVIF_COLOR_PRIMARIES_UNSPECIFIED : AVIF_COLOR_PRIMARIES_BT709;
    image->transferCharacteristics = iccSize ? AVIF_TRANSFER_CHARACTERISTICS_UNSPECIFIED : AVIF_TRANSFER_CHARACTERISTICS_SRGB;
    if (iccSize && (result = avifImageSetProfileICC(image, icc, (size_t)iccSize)) != AVIF_RESULT_OK) {
        stage = "ICC profile";
        goto done;
    }
    if (exifSize) {
        if ((result = avifImageSetMetadataExif(image, exif, (size_t)exifSize)) != AVIF_RESULT_OK) {
            stage = "Exif";
            goto done;
        }
        // libavif turns the Exif orientation into irot/imir; the engine already wrote the pixels upright.
        image->transformFlags &= ~(avifTransformFlags)(AVIF_TRANSFORM_IROT | AVIF_TRANSFORM_IMIR);
    }
    if (xmpSize && (result = avifImageSetMetadataXMP(image, xmp, (size_t)xmpSize)) != AVIF_RESULT_OK) {
        stage = "XMP";
        goto done;
    }
    avifRGBImage rgb;
    avifRGBImageSetDefaults(&rgb, image);
    rgb.format = channels == 4 ? AVIF_RGB_FORMAT_RGBA : AVIF_RGB_FORMAT_RGB;
    rgb.depth = 8;
    rgb.pixels = payload;
    rgb.rowBytes = width * channels;
    if ((result = avifImageRGBToYUV(image, &rgb)) != AVIF_RESULT_OK) {
        stage = "colour conversion";
        goto done;
    }
    // The samples and metadata are copied into the image: release them before the encoder's own buffers.
    free(payload);
    payload = NULL;

    encoder = avifEncoderCreate();
    if (!encoder) {
        status = 3;
        stage = "encoder setup";
        result = AVIF_RESULT_OUT_OF_MEMORY;
        goto done;
    }
    encoder->codecChoice = AVIF_CODEC_CHOICE_AOM;
    // More threads shorten libaom's encode; at most eight are used. libaom's test/ethread_test.cc finds the same bitstream
    // with 2, 4 and 64 row-multithreaded threads for one 640x480 4:2:0 clip at all-intra speed 6, cq-level 18: evidence
    // for, not proof of, output that does not depend on the count with 4:4:4 colour, alpha or other sizes.
    const long processors = sysconf(_SC_NPROCESSORS_ONLN);
    encoder->maxThreads = processors < 2 ? 2 : processors > 8 ? 8 : (int)processors;
    encoder->speed = 6;
    // The preset quality keeps the AV1 quantizers of ImageIO's AVIF encoder, which this replaces: colour
    // floor((100 - quality) * 63 / 100), alpha 7 at every quality. Alpha follows colour where colour is finer. libavif's
    // quality of quantizer n is ((63 - n) * 100 + 31) / 63 (avif.h), which maps back to n exactly.
    const int colourQuantizer = (100 - (int)quality) * 63 / 100, alphaQuantizer = colourQuantizer < 7 ? colourQuantizer : 7;
    encoder->quality = ((63 - colourQuantizer) * 100 + 31) / 63;
    encoder->qualityAlpha = ((63 - alphaQuantizer) * 100 + 31) / 63;
    // Explicit SSIM tuning keeps that linear map for colour; libavif's default IQ tuning has its own coarser table,
    // quantization matrices and chroma delta-q. Alpha keeps libavif's PSNR tuning.
    if ((result = avifEncoderSetCodecSpecificOption(encoder, "color:tune", "ssim")) != AVIF_RESULT_OK) {
        stage = "encoder setup";
        goto done;
    }
    if ((result = avifEncoderWrite(encoder, image, &encoded)) != AVIF_RESULT_OK) {
        stage = "encoding";
        goto done;
    }

    fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
    if (fd < 0) {
        status = 5;
        stage = "creating the output";
        goto done;
    }
    const int written = writeAll(fd, encoded.data, encoded.size);
    if (close(fd) != 0 || !written) {
        unlink(argv[2]);
        status = 5;
        stage = "writing the output";
        goto done;
    }
    status = 0;

done:
    if (status != 0) {
        const char * detail = encoder && encoder->diag.error[0] ? encoder->diag.error : result != AVIF_RESULT_OK ? avifResultToString(result) : strerror(errno);
        fprintf(stderr, "FileToXAvifEncoder: %s failed: %s\n", stage, detail);
    }
    avifRWDataFree(&encoded);
    if (encoder) avifEncoderDestroy(encoder);
    avifImageDestroy(image);
    free(payload);
    return status;
}
