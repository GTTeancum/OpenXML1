#include "fmac.h"
#include <cmath>
#include <cstring>
#include <limits>
#include <emmintrin.h>
#include <intrin.h>
#if defined(FMAC_USE_AVX2)
#include <immintrin.h>
#endif

namespace
{
enum class Kind { Add, Subtract, Multiply, MultiplyAdd, MultiplySubtract, CrossMultiply, CrossSubtract };
enum class Source { X, Y, Z, W, Vector, Q, I };

#if defined(FMAC_USE_AVX2)
__m128 operands(__m128i bits)
{
    const auto sign = _mm_and_si128(bits, _mm_set1_epi32(static_cast<int>(0x80000000u)));
    const auto magnitude = _mm_and_si128(bits, _mm_set1_epi32(0x7fffffff));
    const auto small = _mm_cmpgt_epi32(_mm_set1_epi32(0x00800000), magnitude);
    const auto clamped = _mm_min_epi32(magnitude, _mm_set1_epi32(0x7f7fffff));
    return _mm_castsi128_ps(_mm_or_si128(sign, _mm_andnot_si128(small, clamped)));
}

uint32 packFlags(uint32 z, uint32 s, uint32 u, uint32 o, unsigned dest)
{
    // Reverse lane order in all four flag nibbles together.
    auto flags = z | (s << 4) | (u << 8) | (o << 12);
    flags = ((flags & 0x5555u) << 1) | ((flags >> 1) & 0x5555u);
    flags = ((flags & 0x3333u) << 2) | ((flags >> 2) & 0x3333u);
    return flags & (dest * 0x1111u);
}

struct Range
{
    __m256d small, large;
    uint32 flags;
};

// Keep the vector result in registers instead of returning a large struct through the ABI.
__forceinline Range classifyVector(__m256d exact, unsigned dest)
{
    const auto magnitude = _mm256_andnot_pd(_mm256_set1_pd(-0.0), exact);
    const auto small = _mm256_cmp_pd(magnitude, _mm256_set1_pd(std::numeric_limits<float>::min()), _CMP_LT_OQ);
    const auto large = _mm256_cmp_pd(magnitude, _mm256_set1_pd(std::numeric_limits<float>::max()), _CMP_GT_OQ);
    const auto zero = _mm256_cmp_pd(magnitude, _mm256_setzero_pd(), _CMP_EQ_OQ);
    const uint32 z = _mm256_movemask_pd(small);
    const uint32 s = _mm256_movemask_pd(exact);
    const uint32 u = _mm256_movemask_pd(_mm256_andnot_pd(zero, small));
    const uint32 o = _mm256_movemask_pd(large);
    return {small, large, packFlags(z, s, u, o, dest)};
}

__m128i narrowMask(__m256d mask)
{
    return _mm256_castsi256_si128(_mm256_permutevar8x32_epi32(_mm256_castpd_si256(mask),
        _mm256_setr_epi32(0,2,4,6,0,2,4,6)));
}

template<Kind kind, Source source, bool accumulator>
uint32 execute(CMIPS *cpu, uint32 opcode)
{
    auto &s = cpu->m_State;
    constexpr bool cross = kind == Kind::CrossMultiply || kind == Kind::CrossSubtract;
    constexpr bool productSum = kind == Kind::MultiplyAdd || kind == Kind::MultiplySubtract || kind == Kind::CrossSubtract;
    const unsigned dest = cross ? 14u : ((opcode >> 21) & 15u);
    const unsigned fd = (opcode >> 6) & 31u;
    auto &output = accumulator ? s.nCOP2A : s.nCOP2[fd ? fd : 32];
    auto left = operands(_mm_loadu_si128(reinterpret_cast<const __m128i *>(&s.nCOP2[(opcode >> 11) & 31])));
    __m128 right;
    if constexpr (source == Source::Q) right = operands(_mm_set1_epi32(s.nCOP2Q));
    else if constexpr (source == Source::I) right = operands(_mm_set1_epi32(s.nCOP2I));
    else
    {
        right = operands(_mm_loadu_si128(reinterpret_cast<const __m128i *>(&s.nCOP2[(opcode >> 16) & 31])));
        if constexpr (source != Source::Vector)
            right = _mm_shuffle_ps(right, right, static_cast<unsigned>(source) * 0x55);
    }
    if constexpr (cross)
    {
        left = _mm_shuffle_ps(left, left, _MM_SHUFFLE(3,0,2,1));
        right = _mm_shuffle_ps(right, right, _MM_SHUFFLE(3,1,0,2));
    }
    const auto a = _mm256_cvtps_pd(left), b = _mm256_cvtps_pd(right);
    __m256d exact;
    __m128 value;
    uint32 extra = 0;
    if constexpr (kind == Kind::Add) { exact = _mm256_add_pd(a,b); value = _mm_add_ps(left,right); }
    else if constexpr (kind == Kind::Subtract) { exact = _mm256_sub_pd(a,b); value = _mm_sub_ps(left,right); }
    else
    {
        const auto product = _mm256_mul_pd(a,b);
        value = _mm_mul_ps(left,right);
        if constexpr (productSum)
        {
            extra = classifyVector(product, dest).flags;
            const auto prior = operands(_mm_loadu_si128(reinterpret_cast<const __m128i *>(&s.nCOP2A)));
            if constexpr (kind == Kind::MultiplyAdd) { exact = _mm256_add_pd(_mm256_cvtps_pd(prior),product); value = _mm_add_ps(prior,value); }
            else { exact = _mm256_sub_pd(_mm256_cvtps_pd(prior),product); value = _mm_sub_ps(prior,value); }
        }
        else exact = product;
    }
    const auto range = classifyVector(exact,dest);
    const auto sign = _mm_and_si128(_mm256_castsi256_si128(_mm256_permutevar8x32_epi32(
        _mm256_castpd_si256(exact), _mm256_setr_epi32(1,3,5,7,1,3,5,7))), _mm_set1_epi32(static_cast<int>(0x80000000u)));
    const auto large = narrowMask(range.large);
    const auto saturated = _mm_or_si128(sign, _mm_and_si128(large,_mm_set1_epi32(0x7f7fffff)));
    value = _mm_blendv_ps(value,_mm_castsi128_ps(saturated),_mm_castsi128_ps(_mm_or_si128(narrowMask(range.small),large)));
    const auto laneBits = _mm_setr_epi32(8,4,2,1);
    const auto active = _mm_castsi128_ps(_mm_cmpeq_epi32(_mm_and_si128(_mm_set1_epi32(dest),laneBits),laneBits));
    const auto old = _mm_loadu_ps(reinterpret_cast<const float *>(&output));
    _mm_storeu_ps(reinterpret_cast<float *>(&output),_mm_blendv_ps(old,value,active));
    return range.flags | (extra << 16);
}
#else
float operand(uint32 bits)
{
    const auto magnitude = bits & 0x7fffffffu;
    if (magnitude < 0x00800000u) bits &= 0x80000000u;
    else if (magnitude > 0x7f7fffffu) bits = (bits & 0x80000000u) | 0x7f7fffffu;
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

uint32 classify(double exact)
{
    const double magnitude = std::fabs(exact);
    const uint32 sign = std::signbit(exact) ? 2u : 0u;
    if (magnitude == 0) return sign | 1u;
    if (magnitude < std::numeric_limits<float>::min()) return sign | 5u;
    if (magnitude > std::numeric_limits<float>::max()) return sign | 8u;
    return sign;
}

uint32 packLane(uint32 flags, unsigned lane)
{
    const unsigned shift = 3 - lane;
    return ((flags & 1) << shift) | ((flags & 2) << (shift + 3)) |
        ((flags & 4) << (shift + 6)) | ((flags & 8) << (shift + 9));
}

template<Kind kind, Source source, bool accumulator>
uint32 execute(CMIPS *cpu, uint32 opcode)
{
    auto &s = cpu->m_State;
    // Snapshot all sources before a masked destination can alias one of them.
    const auto fs = s.nCOP2[(opcode >> 11) & 31];
    const auto ft = s.nCOP2[(opcode >> 16) & 31];
    const auto acc = s.nCOP2A;
    constexpr bool cross = kind == Kind::CrossMultiply || kind == Kind::CrossSubtract;
    constexpr bool productSum = kind == Kind::MultiplyAdd || kind == Kind::MultiplySubtract || kind == Kind::CrossSubtract;
    const unsigned dest = cross ? 14u : ((opcode >> 21) & 15u);
    const unsigned fd = (opcode >> 6) & 31u;
    auto &output = accumulator ? s.nCOP2A : s.nCOP2[fd ? fd : 32];
    uint32 mac = 0, sticky = 0;
    for (unsigned lane = 0; lane < 4; ++lane)
    {
        if (!(dest & (8u >> lane))) continue;
        constexpr unsigned leftLane[] = {1, 2, 0, 3}, rightLane[] = {2, 0, 1, 3};
        const float left = operand(fs.nV[cross ? leftLane[lane] : lane]);
        uint32 rightBits;
        if constexpr (source == Source::Q) rightBits = s.nCOP2Q;
        else if constexpr (source == Source::I) rightBits = s.nCOP2I;
        else if constexpr (source == Source::Vector) rightBits = ft.nV[cross ? rightLane[lane] : lane];
        else rightBits = ft.nV[static_cast<unsigned>(source)];
        const float right = operand(rightBits);
        const double a = left, b = right;
        double exact;
        __m128 value;
        if constexpr (kind == Kind::Add)
        {
            exact = a + b;
            value = _mm_add_ss(_mm_set_ss(left), _mm_set_ss(right));
        }
        else if constexpr (kind == Kind::Subtract)
        {
            exact = a - b;
            value = _mm_sub_ss(_mm_set_ss(left), _mm_set_ss(right));
        }
        else
        {
            const double product = a * b;
            value = _mm_mul_ss(_mm_set_ss(left), _mm_set_ss(right));
            if constexpr (productSum)
            {
                sticky |= packLane(classify(product), lane);
                const float prior = operand(acc.nV[lane]);
                if constexpr (kind == Kind::MultiplyAdd)
                {
                    exact = double(prior) + product;
                    value = _mm_add_ss(_mm_set_ss(prior), value);
                }
                else
                {
                    exact = double(prior) - product;
                    value = _mm_sub_ss(_mm_set_ss(prior), value);
                }
            }
            else exact = product;
        }
        const uint32 flags = classify(exact);
        uint32 bits = static_cast<uint32>(_mm_cvtsi128_si32(_mm_castps_si128(value)));
        if (flags & 9u)
            bits = ((flags & 2u) ? 0x80000000u : 0u) | ((flags & 8u) ? 0x7f7fffffu : 0u);
        output.nV[lane] = bits;
        mac |= packLane(flags, lane);
    }
    return mac | (sticky << 16);
}
#endif

template<bool accumulator>
FmacOperation select(unsigned function)
{
    switch (function)
    {
#define BC(group, kind) \
    case group: return &execute<Kind::kind, Source::X, accumulator>; \
    case group + 1: return &execute<Kind::kind, Source::Y, accumulator>; \
    case group + 2: return &execute<Kind::kind, Source::Z, accumulator>; \
    case group + 3: return &execute<Kind::kind, Source::W, accumulator>;
    BC(0x00, Add)
    BC(0x04, Subtract)
    BC(0x08, MultiplyAdd)
    BC(0x0c, MultiplySubtract)
    BC(0x18, Multiply)
#undef BC
#define OP(code, kind, source) case code: return &execute<Kind::kind, Source::source, accumulator>;
    OP(0x1c, Multiply, Q) OP(0x1e, Multiply, I)
    OP(0x20, Add, Q) OP(0x21, MultiplyAdd, Q)
    OP(0x22, Add, I) OP(0x23, MultiplyAdd, I)
    OP(0x24, Subtract, Q) OP(0x25, MultiplySubtract, Q)
    OP(0x26, Subtract, I) OP(0x27, MultiplySubtract, I)
    OP(0x28, Add, Vector) OP(0x29, MultiplyAdd, Vector)
    OP(0x2a, Multiply, Vector) OP(0x2c, Subtract, Vector)
    OP(0x2d, MultiplySubtract, Vector)
#undef OP
    case 0x2e:
        if constexpr (accumulator) return &execute<Kind::CrossMultiply, Source::Vector, true>;
        else return &execute<Kind::CrossSubtract, Source::Vector, false>;
    default: return nullptr;
    }
}
}

#if defined(FMAC_USE_AVX2)
FmacOperation selectFmacAvx2(uint32 opcode)
#else
FmacOperation selectFmacScalar(uint32 opcode)
#endif
{
    const unsigned op = opcode & 63;
    return op >= 0x3c ? select<true>((opcode & 3) | ((opcode >> 4) & 0x7c)) : select<false>(op);
}

#if !defined(FMAC_USE_AVX2)
FmacOperation selectFmacAvx2(uint32 opcode);

bool fmacAvx2Available()
{
    static const bool supported = [] {
        int info[4];
        __cpuid(info,0);
        if (info[0] < 7) return false;
        __cpuidex(info,1,0);
        if ((info[2] & 0x18000000) != 0x18000000 || (_xgetbv(0) & 6) != 6) return false;
        __cpuidex(info,7,0);
        return (info[1] & 0x20) != 0;
    }();
    return supported;
}

FmacOperation selectFmac(uint32 opcode)
{
    return fmacAvx2Available() ? selectFmacAvx2(opcode) : selectFmacScalar(opcode);
}
#endif
