#include "WhispKernels.h"

#include <dispatch/dispatch.h>
#include <stddef.h>

#if defined(__aarch64__)
#include <arm_neon.h>

static inline float dot_row(const float16_t *w, const float *x, int n) {
    float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
    int i = 0;
    for (; i + 16 <= n; i += 16) {
        float16x8_t h0 = vld1q_f16(w + i), h1 = vld1q_f16(w + i + 8);
        a0 = vfmaq_f32(a0, vcvt_f32_f16(vget_low_f16(h0)), vld1q_f32(x + i));
        a1 = vfmaq_f32(a1, vcvt_high_f32_f16(h0), vld1q_f32(x + i + 4));
        a2 = vfmaq_f32(a2, vcvt_f32_f16(vget_low_f16(h1)), vld1q_f32(x + i + 8));
        a3 = vfmaq_f32(a3, vcvt_high_f32_f16(h1), vld1q_f32(x + i + 12));
    }
    float s = vaddvq_f32(vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3)));
    for (; i < n; i++) s += (float)w[i] * x[i];
    return s;
}

// Rows [from, to). Two rows per pass share the loads of x.
static void gemv_rows(const uint16_t *weights, int cols, const float *x, float *y,
                      int from, int to) {
    const float16_t *w = (const float16_t *)weights;
    int r = from;
    for (; r + 2 <= to; r += 2) {
        const float16_t *p = w + (size_t)r * cols, *q = p + cols;
        float32x4_t a0 = vdupq_n_f32(0), a1 = a0, a2 = a0, a3 = a0;
        float32x4_t b0 = a0, b1 = a0, b2 = a0, b3 = a0;
        int i = 0;
        for (; i + 16 <= cols; i += 16) {
            float32x4_t x0 = vld1q_f32(x + i), x1 = vld1q_f32(x + i + 4);
            float32x4_t x2 = vld1q_f32(x + i + 8), x3 = vld1q_f32(x + i + 12);
            float16x8_t p0 = vld1q_f16(p + i), p1 = vld1q_f16(p + i + 8);
            float16x8_t q0 = vld1q_f16(q + i), q1 = vld1q_f16(q + i + 8);
            a0 = vfmaq_f32(a0, vcvt_f32_f16(vget_low_f16(p0)), x0);
            a1 = vfmaq_f32(a1, vcvt_high_f32_f16(p0), x1);
            a2 = vfmaq_f32(a2, vcvt_f32_f16(vget_low_f16(p1)), x2);
            a3 = vfmaq_f32(a3, vcvt_high_f32_f16(p1), x3);
            b0 = vfmaq_f32(b0, vcvt_f32_f16(vget_low_f16(q0)), x0);
            b1 = vfmaq_f32(b1, vcvt_high_f32_f16(q0), x1);
            b2 = vfmaq_f32(b2, vcvt_f32_f16(vget_low_f16(q1)), x2);
            b3 = vfmaq_f32(b3, vcvt_high_f32_f16(q1), x3);
        }
        float s = vaddvq_f32(vaddq_f32(vaddq_f32(a0, a1), vaddq_f32(a2, a3)));
        float t = vaddvq_f32(vaddq_f32(vaddq_f32(b0, b1), vaddq_f32(b2, b3)));
        for (; i < cols; i++) {
            s += (float)p[i] * x[i];
            t += (float)q[i] * x[i];
        }
        y[r] += s;
        y[r + 1] += t;
    }
    for (; r < to; r++) y[r] += dot_row(w + (size_t)r * cols, x, cols);
}

#else

// Portable path (Intel builds): widen each half by hand.
static inline float widen(uint16_t h) {
    uint32_t sign = (uint32_t)(h & 0x8000) << 16;
    uint32_t exponent = (h >> 10) & 0x1f;
    uint32_t mantissa = h & 0x3ff;
    uint32_t bits;
    if (exponent == 0) {
        if (mantissa == 0) {
            bits = sign;
        } else {
            int shift = 0;
            while (!(mantissa & 0x400)) { mantissa <<= 1; shift++; }
            bits = sign | ((uint32_t)(113 - shift) << 23) | ((mantissa & 0x3ff) << 13);
        }
    } else if (exponent == 31) {
        bits = sign | 0x7f800000u | (mantissa << 13);
    } else {
        bits = sign | ((exponent + 112) << 23) | (mantissa << 13);
    }
    float f;
    __builtin_memcpy(&f, &bits, sizeof f);
    return f;
}

static void gemv_rows(const uint16_t *w, int cols, const float *x, float *y,
                      int from, int to) {
    for (int r = from; r < to; r++) {
        const uint16_t *row = w + (size_t)r * cols;
        float s = 0;
        for (int i = 0; i < cols; i++) s += widen(row[i]) * x[i];
        y[r] += s;
    }
}

#endif

struct job {
    const uint16_t *w[2];
    const float *x[2];
    float *y[2];
    int rows, cols, tasks, products;
};

static void run_slice(void *context, size_t index) {
    const struct job *job = context;
    int product = (int)index / job->tasks;
    int slice = (int)index % job->tasks;
    // Even row boundaries keep the two-row kernel on its fast path.
    int per = ((job->rows / job->tasks) + 1) & ~1;
    int from = slice * per;
    int to = slice == job->tasks - 1 ? job->rows : from + per;
    if (from > job->rows) from = job->rows;
    if (to > job->rows) to = job->rows;
    gemv_rows(job->w[product], job->cols, job->x[product], job->y[product], from, to);
}

static void run(struct job *job) {
    if (job->tasks < 1) job->tasks = 1;
    size_t count = (size_t)job->tasks * job->products;
    if (count == 1) {
        run_slice(job, 0);
        return;
    }
    dispatch_apply_f(count, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                     job, run_slice);
}

void whisp_gemv_f16(const uint16_t *w, int rows, int cols,
                    const float *x, float *y, int tasks) {
    struct job job = {{w, 0}, {x, 0}, {y, 0}, rows, cols, tasks, 1};
    run(&job);
}

void whisp_gemv2_f16(const uint16_t *w0, const float *x0, float *y0,
                     const uint16_t *w1, const float *x1, float *y1,
                     int rows, int cols, int tasks_each) {
    struct job job = {{w0, w1}, {x0, x1}, {y0, y1}, rows, cols, tasks_each, 2};
    run(&job);
}
