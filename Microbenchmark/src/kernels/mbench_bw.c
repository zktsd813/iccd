#define _GNU_SOURCE

#include "mbench_kernels.h"

#include <errno.h>
#include <immintrin.h>
#include <stdbool.h>
#include <string.h>

static pthread_once_t g_bw_isa_once = PTHREAD_ONCE_INIT;
static enum mbench_isa g_bw_isa = MBENCH_ISA_SCALAR;

static inline bool mbench_is_aligned_64(const void *ptr)
{
    return (((uintptr_t)ptr) & 63U) == 0U;
}

static inline double mbench_reduce_avx2(__m256d v)
{
    double tmp[4] __attribute__((aligned(32)));

    _mm256_store_pd(tmp, v);
    return tmp[0] + tmp[1] + tmp[2] + tmp[3];
}

static inline double mbench_reduce_avx512(__m512d v)
{
    double tmp[8] __attribute__((aligned(64)));

    _mm512_store_pd(tmp, v);
    return tmp[0] + tmp[1] + tmp[2] + tmp[3] + tmp[4] + tmp[5] + tmp[6] + tmp[7];
}

static enum mbench_isa mbench_detect_bw_isa_uncached(void)
{
#if defined(__x86_64__) || defined(__i386__)
    __builtin_cpu_init();
#if defined(__AVX512F__)
    if (__builtin_cpu_supports("avx512f")) {
        return MBENCH_ISA_AVX512;
    }
#endif
#if defined(__AVX2__)
    if (__builtin_cpu_supports("avx2")) {
        return MBENCH_ISA_AVX2;
    }
#endif
#endif
    return MBENCH_ISA_SCALAR;
}

static void mbench_detect_bw_isa_once(void)
{
    g_bw_isa = mbench_detect_bw_isa_uncached();
}

enum mbench_isa mbench_detect_isa(void)
{
    (void)pthread_once(&g_bw_isa_once, mbench_detect_bw_isa_once);
    return g_bw_isa;
}

static double mbench_bw_scalar_read(const double *restrict src, size_t elements)
{
    double s0 = 0.0;
    double s1 = 0.0;
    double s2 = 0.0;
    double s3 = 0.0;
    size_t i = 0;

    for (; i + 3 < elements; i += 4) {
        s0 += src[i + 0];
        s1 += src[i + 1];
        s2 += src[i + 2];
        s3 += src[i + 3];
    }

    for (; i < elements; ++i) {
        s0 += src[i];
    }

    return s0 + s1 + s2 + s3;
}

static double mbench_bw_scalar_write(double *restrict dst, size_t elements, double value)
{
    size_t i = 0;

    for (; i + 3 < elements; i += 4) {
        dst[i + 0] = value;
        dst[i + 1] = value;
        dst[i + 2] = value;
        dst[i + 3] = value;
    }

    for (; i < elements; ++i) {
        dst[i] = value;
    }

    return value * (double)elements;
}

static double mbench_bw_scalar_copy(double *restrict dst, const double *restrict src, size_t elements)
{
    double checksum = 0.0;
    size_t i = 0;

    for (; i + 3 < elements; i += 4) {
        double v0 = src[i + 0];
        double v1 = src[i + 1];
        double v2 = src[i + 2];
        double v3 = src[i + 3];

        dst[i + 0] = v0;
        dst[i + 1] = v1;
        dst[i + 2] = v2;
        dst[i + 3] = v3;

        checksum += v0 + v1 + v2 + v3;
    }

    for (; i < elements; ++i) {
        double v = src[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}

static double mbench_bw_scalar_triad(double *restrict dst,
                                     const double *restrict src1,
                                     const double *restrict src2,
                                     size_t elements,
                                     double scalar)
{
    double checksum = 0.0;
    size_t i = 0;

    for (; i + 3 < elements; i += 4) {
        double v0 = src1[i + 0] + scalar * src2[i + 0];
        double v1 = src1[i + 1] + scalar * src2[i + 1];
        double v2 = src1[i + 2] + scalar * src2[i + 2];
        double v3 = src1[i + 3] + scalar * src2[i + 3];

        dst[i + 0] = v0;
        dst[i + 1] = v1;
        dst[i + 2] = v2;
        dst[i + 3] = v3;

        checksum += v0 + v1 + v2 + v3;
    }

    for (; i < elements; ++i) {
        double v = src1[i] + scalar * src2[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}

static bool mbench_bw_is_linear_pattern(const struct mbench_bw_job *job)
{
    return job->stride_elements <= 1U && job->block_elements >= job->elements;
}

static double mbench_bw_scalar_pattern_read(const double *restrict src,
                                            size_t elements,
                                            size_t block_elements,
                                            size_t stride_elements)
{
    double checksum = 0.0;

    for (size_t lane = 0; lane < block_elements; lane += stride_elements) {
        for (size_t block_start = 0; block_start < elements; block_start += block_elements) {
            size_t idx = block_start + lane;
            if (idx < elements) {
                checksum += src[idx];
            }
        }
    }
    return checksum;
}

static double mbench_bw_scalar_pattern_write(double *restrict dst,
                                             size_t elements,
                                             size_t block_elements,
                                             size_t stride_elements,
                                             double value)
{
    size_t touched = 0;

    for (size_t lane = 0; lane < block_elements; lane += stride_elements) {
        for (size_t block_start = 0; block_start < elements; block_start += block_elements) {
            size_t idx = block_start + lane;
            if (idx < elements) {
                dst[idx] = value;
                touched++;
            }
        }
    }
    return value * (double)touched;
}

static double mbench_bw_scalar_pattern_copy(double *restrict dst,
                                            const double *restrict src,
                                            size_t elements,
                                            size_t block_elements,
                                            size_t stride_elements)
{
    double checksum = 0.0;

    for (size_t lane = 0; lane < block_elements; lane += stride_elements) {
        for (size_t block_start = 0; block_start < elements; block_start += block_elements) {
            size_t idx = block_start + lane;
            if (idx < elements) {
                double v = src[idx];
                dst[idx] = v;
                checksum += v;
            }
        }
    }
    return checksum;
}

static double mbench_bw_scalar_pattern_triad(double *restrict dst,
                                             const double *restrict src1,
                                             const double *restrict src2,
                                             size_t elements,
                                             size_t block_elements,
                                             size_t stride_elements,
                                             double scalar)
{
    double checksum = 0.0;

    for (size_t lane = 0; lane < block_elements; lane += stride_elements) {
        for (size_t block_start = 0; block_start < elements; block_start += block_elements) {
            size_t idx = block_start + lane;
            if (idx < elements) {
                double v = src1[idx] + scalar * src2[idx];
                dst[idx] = v;
                checksum += v;
            }
        }
    }
    return checksum;
}

#if defined(__x86_64__) || defined(__i386__)
#if defined(__AVX2__)
static double mbench_bw_avx2_read(const double *restrict src, size_t elements)
{
    __m256d sumv = _mm256_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)3);

    for (; i < vec_end; i += 4) {
        __m256d v = _mm256_loadu_pd(src + i);
        sumv = _mm256_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx2(sumv);
    for (; i < elements; ++i) {
        checksum += src[i];
    }

    return checksum;
}

static double mbench_bw_avx2_write(double *restrict dst, size_t elements, double value)
{
    __m256d vec = _mm256_set1_pd(value);
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)3);

    for (; i < vec_end; i += 4) {
        _mm256_storeu_pd(dst + i, vec);
    }
    for (; i < elements; ++i) {
        dst[i] = value;
    }

    return value * (double)elements;
}

static double mbench_bw_avx2_copy(double *restrict dst, const double *restrict src, size_t elements)
{
    __m256d sumv = _mm256_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)3);

    for (; i < vec_end; i += 4) {
        __m256d v = _mm256_loadu_pd(src + i);
        _mm256_storeu_pd(dst + i, v);
        sumv = _mm256_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx2(sumv);
    for (; i < elements; ++i) {
        double v = src[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}

static double mbench_bw_avx2_triad(double *restrict dst,
                                   const double *restrict src1,
                                   const double *restrict src2,
                                   size_t elements,
                                   double scalar)
{
    __m256d scalar_vec = _mm256_set1_pd(scalar);
    __m256d sumv = _mm256_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)3);

    for (; i < vec_end; i += 4) {
        __m256d a = _mm256_loadu_pd(src1 + i);
        __m256d b = _mm256_loadu_pd(src2 + i);
        __m256d v = _mm256_add_pd(a, _mm256_mul_pd(scalar_vec, b));
        _mm256_storeu_pd(dst + i, v);
        sumv = _mm256_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx2(sumv);
    for (; i < elements; ++i) {
        double v = src1[i] + scalar * src2[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}
#endif

#if defined(__AVX512F__)
static double mbench_bw_avx512_read(const double *restrict src, size_t elements)
{
    __m512d sumv = _mm512_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)7);

    for (; i < vec_end; i += 8) {
        __m512d v = _mm512_loadu_pd(src + i);
        sumv = _mm512_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx512(sumv);
    for (; i < elements; ++i) {
        checksum += src[i];
    }

    return checksum;
}

static double mbench_bw_avx512_write(double *restrict dst, size_t elements, double value)
{
    __m512d vec = _mm512_set1_pd(value);
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)7);

    for (; i < vec_end; i += 8) {
        _mm512_storeu_pd(dst + i, vec);
    }
    for (; i < elements; ++i) {
        dst[i] = value;
    }

    return value * (double)elements;
}

static double mbench_bw_avx512_copy(double *restrict dst, const double *restrict src, size_t elements)
{
    __m512d sumv = _mm512_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)7);

    for (; i < vec_end; i += 8) {
        __m512d v = _mm512_loadu_pd(src + i);
        _mm512_storeu_pd(dst + i, v);
        sumv = _mm512_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx512(sumv);
    for (; i < elements; ++i) {
        double v = src[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}

static double mbench_bw_avx512_triad(double *restrict dst,
                                     const double *restrict src1,
                                     const double *restrict src2,
                                     size_t elements,
                                     double scalar)
{
    __m512d scalar_vec = _mm512_set1_pd(scalar);
    __m512d sumv = _mm512_setzero_pd();
    size_t i = 0;
    const size_t vec_end = elements & ~((size_t)7);

    for (; i < vec_end; i += 8) {
        __m512d a = _mm512_loadu_pd(src1 + i);
        __m512d b = _mm512_loadu_pd(src2 + i);
        __m512d v = _mm512_add_pd(a, _mm512_mul_pd(scalar_vec, b));
        _mm512_storeu_pd(dst + i, v);
        sumv = _mm512_add_pd(sumv, v);
    }

    double checksum = mbench_reduce_avx512(sumv);
    for (; i < elements; ++i) {
        double v = src1[i] + scalar * src2[i];
        dst[i] = v;
        checksum += v;
    }

    return checksum;
}
#endif
#endif

static int mbench_bw_run_scalar(const struct mbench_bw_job *job)
{
    double checksum = 0.0;
    const bool linear = mbench_bw_is_linear_pattern(job);

    for (size_t pass = 0; pass < job->passes; ++pass) {
        switch (job->kind) {
        case MBENCH_BW_READ:
            checksum += linear
                ? mbench_bw_scalar_read(job->src1, job->elements)
                : mbench_bw_scalar_pattern_read(job->src1,
                                                job->elements,
                                                job->block_elements,
                                                job->stride_elements);
            break;
        case MBENCH_BW_WRITE:
            checksum += linear
                ? mbench_bw_scalar_write(job->dst, job->elements, job->triad_scalar)
                : mbench_bw_scalar_pattern_write(job->dst,
                                                 job->elements,
                                                 job->block_elements,
                                                 job->stride_elements,
                                                 job->triad_scalar);
            break;
        case MBENCH_BW_COPY:
            checksum += linear
                ? mbench_bw_scalar_copy(job->dst, job->src1, job->elements)
                : mbench_bw_scalar_pattern_copy(job->dst,
                                                job->src1,
                                                job->elements,
                                                job->block_elements,
                                                job->stride_elements);
            break;
        case MBENCH_BW_TRIAD:
            checksum += linear
                ? mbench_bw_scalar_triad(job->dst,
                                         job->src1,
                                         job->src2,
                                         job->elements,
                                         job->triad_scalar)
                : mbench_bw_scalar_pattern_triad(job->dst,
                                                 job->src1,
                                                 job->src2,
                                                 job->elements,
                                                 job->block_elements,
                                                 job->stride_elements,
                                                 job->triad_scalar);
            break;
        default:
            return -EINVAL;
        }
    }

    if (job->sink != NULL) {
        *job->sink = checksum;
    }
    return 0;
}

#if defined(__x86_64__) || defined(__i386__)
#if defined(__AVX2__) || defined(__AVX512F__)
static int mbench_bw_run_vector(const struct mbench_bw_job *job, enum mbench_isa isa)
{
    const bool aligned_dst = job->dst == NULL || mbench_is_aligned_64(job->dst);
    const bool aligned_src1 = job->src1 == NULL || mbench_is_aligned_64(job->src1);
    const bool aligned_src2 = job->src2 == NULL || mbench_is_aligned_64(job->src2);
    double checksum = 0.0;

    for (size_t pass = 0; pass < job->passes; ++pass) {
        switch (job->kind) {
        case MBENCH_BW_READ:
#if defined(__AVX512F__)
            if (isa == MBENCH_ISA_AVX512) {
                checksum += aligned_src1 ? mbench_bw_avx512_read((const double *)__builtin_assume_aligned(job->src1, 64),
                                                                 job->elements)
                                         : mbench_bw_avx512_read(job->src1, job->elements);
                break;
            }
#endif
#if defined(__AVX2__)
            if (isa == MBENCH_ISA_AVX2) {
                checksum += aligned_src1 ? mbench_bw_avx2_read((const double *)__builtin_assume_aligned(job->src1, 64),
                                                               job->elements)
                                         : mbench_bw_avx2_read(job->src1, job->elements);
                break;
            }
#endif
            checksum += mbench_bw_scalar_read(job->src1, job->elements);
            break;

        case MBENCH_BW_WRITE:
#if defined(__AVX512F__)
            if (isa == MBENCH_ISA_AVX512) {
                checksum += aligned_dst ? mbench_bw_avx512_write((double *)__builtin_assume_aligned(job->dst, 64),
                                                                 job->elements,
                                                                 job->triad_scalar)
                                        : mbench_bw_avx512_write(job->dst, job->elements, job->triad_scalar);
                break;
            }
#endif
#if defined(__AVX2__)
            if (isa == MBENCH_ISA_AVX2) {
                checksum += aligned_dst ? mbench_bw_avx2_write((double *)__builtin_assume_aligned(job->dst, 64),
                                                               job->elements,
                                                               job->triad_scalar)
                                        : mbench_bw_avx2_write(job->dst, job->elements, job->triad_scalar);
                break;
            }
#endif
            checksum += mbench_bw_scalar_write(job->dst, job->elements, job->triad_scalar);
            break;

        case MBENCH_BW_COPY:
#if defined(__AVX512F__)
            if (isa == MBENCH_ISA_AVX512) {
                checksum += (aligned_dst && aligned_src1)
                                ? mbench_bw_avx512_copy((double *)__builtin_assume_aligned(job->dst, 64),
                                                        (const double *)__builtin_assume_aligned(job->src1, 64),
                                                        job->elements)
                                : mbench_bw_avx512_copy(job->dst, job->src1, job->elements);
                break;
            }
#endif
#if defined(__AVX2__)
            if (isa == MBENCH_ISA_AVX2) {
                checksum += (aligned_dst && aligned_src1)
                                ? mbench_bw_avx2_copy((double *)__builtin_assume_aligned(job->dst, 64),
                                                     (const double *)__builtin_assume_aligned(job->src1, 64),
                                                     job->elements)
                                : mbench_bw_avx2_copy(job->dst, job->src1, job->elements);
                break;
            }
#endif
            checksum += mbench_bw_scalar_copy(job->dst, job->src1, job->elements);
            break;

        case MBENCH_BW_TRIAD:
#if defined(__AVX512F__)
            if (isa == MBENCH_ISA_AVX512) {
                checksum += (aligned_dst && aligned_src1 && aligned_src2)
                                ? mbench_bw_avx512_triad((double *)__builtin_assume_aligned(job->dst, 64),
                                                         (const double *)__builtin_assume_aligned(job->src1, 64),
                                                         (const double *)__builtin_assume_aligned(job->src2, 64),
                                                         job->elements,
                                                         job->triad_scalar)
                                : mbench_bw_avx512_triad(job->dst,
                                                         job->src1,
                                                         job->src2,
                                                         job->elements,
                                                         job->triad_scalar);
                break;
            }
#endif
#if defined(__AVX2__)
            if (isa == MBENCH_ISA_AVX2) {
                checksum += (aligned_dst && aligned_src1 && aligned_src2)
                                ? mbench_bw_avx2_triad((double *)__builtin_assume_aligned(job->dst, 64),
                                                      (const double *)__builtin_assume_aligned(job->src1, 64),
                                                      (const double *)__builtin_assume_aligned(job->src2, 64),
                                                      job->elements,
                                                      job->triad_scalar)
                                : mbench_bw_avx2_triad(job->dst,
                                                      job->src1,
                                                      job->src2,
                                                      job->elements,
                                                      job->triad_scalar);
                break;
            }
#endif
            checksum += mbench_bw_scalar_triad(job->dst,
                                               job->src1,
                                               job->src2,
                                               job->elements,
                                               job->triad_scalar);
            break;

        default:
            return -EINVAL;
        }
    }

    if (job->sink != NULL) {
        *job->sink = checksum;
    }

    return 0;
}
#endif
#endif

int mbench_run_bw(const struct mbench_bw_job *job)
{
    if (job == NULL || job->passes == 0 || job->elements == 0) {
        return -EINVAL;
    }
    if (!mbench_bw_is_linear_pattern(job)) {
        return mbench_bw_run_scalar(job);
    }

    enum mbench_isa isa = mbench_detect_isa();

#if defined(__AVX2__) || defined(__AVX512F__)
    switch (isa) {
    case MBENCH_ISA_AVX512:
    case MBENCH_ISA_AVX2:
        return mbench_bw_run_vector(job, isa);
    case MBENCH_ISA_SCALAR:
    default:
        return mbench_bw_run_scalar(job);
    }
#else
    (void)isa;
    return mbench_bw_run_scalar(job);
#endif
}
