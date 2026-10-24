#ifndef FILETOX_COPENJPEG_H
#define FILETOX_COPENJPEG_H
#include <stddef.h>
#include <stdint.h>
// Interleaved native-endian 8/16-bit RGB(A)/gray(+alpha). malloc'ed output; caller frees.
// 0 = success, 1 = failure (message, 256 bytes), 2 = cancellation.
int ftx_j2k_encode(const void *samples, int width, int height, size_t stride, int channels,
                   int bits, int quality, unsigned char **data, size_t *length,
                   char *message, int (*cancelled)(void));
#endif
