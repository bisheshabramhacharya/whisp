#ifndef WHISP_KERNELS_H
#define WHISP_KERNELS_H

#include <stdint.h>

/// y[r] += dot(w[r, :], x) for a row-major matrix stored as IEEE half floats.
///
/// The halves are widened to single precision as they are read (exact) and
/// summed in single precision, so the result matches the same product done on
/// a float copy of the matrix, while reading half the memory. `tasks` > 1
/// splits the rows across that many threads.
void whisp_gemv_f16(const uint16_t *w, int rows, int cols,
                    const float *x, float *y, int tasks);

/// Two independent products of the same shape, run side by side, each split
/// across `tasks_each` threads.
void whisp_gemv2_f16(const uint16_t *w0, const float *x0, float *y0,
                     const uint16_t *w1, const float *x1, float *y1,
                     int rows, int cols, int tasks_each);

#endif
