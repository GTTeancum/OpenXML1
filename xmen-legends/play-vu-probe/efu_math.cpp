#include "efu_math.h"
#include <cmath>
#include <cstring>
#include <limits>
#include <stdexcept>

namespace
{
uint32_t normalize(uint32_t bits)
{
    const auto exponent = (bits >> 23) & 255;
    if (!exponent) return bits & 0x80000000u;
    if (exponent == 255) return (bits & 0x80000000u) | 0x7f7fffffu;
    return bits;
}

float unpack(uint32_t bits)
{
    bits = normalize(bits);
    float value;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

float atanPolynomial(float value)
{
    constexpr float coefficients[] = {0.999999344348907f, -0.333298563957214f,
        0.199465364217758f, -0.13085337519646f, 0.096420042216778f,
        -0.055909886956215f, 0.021861229091883f, -0.004054057877511f};
    const float squared = value * value;
    float polynomial = coefficients[7];
    for (int i = 6; i >= 0; --i) polynomial = std::fma(squared, polynomial, coefficients[i]);
    return std::fma(value, polynomial, 0.785398185253143f);
}

float sinPolynomial(float value)
{
    constexpr float coefficients[] = {1.0f, -0.166666567325592f, 0.008333025500178f,
        -0.000198074136279f, 0.000002601886990f};
    const float squared = value * value;
    float polynomial = coefficients[4];
    for (int i = 3; i >= 0; --i) polynomial = std::fma(squared, polynomial, coefficients[i]);
    return value * polynomial;
}

float expPolynomial(float value)
{
    constexpr float coefficients[] = {0.249998688697815f, 0.031257584691048f,
        0.002591371303424f, 0.000171562001924f, 0.000005430199963f, 0.000000690600018f};
    float polynomial = coefficients[5];
    for (int i = 4; i >= 0; --i) polynomial = std::fma(value, polynomial, coefficients[i]);
    // The current runtime's /fp:fast lowering expands the first square this way.
    const float product = value * polynomial;
    polynomial = 1.0f + product;
    polynomial = std::fma(polynomial, product, polynomial);
    polynomial *= polynomial;
    return polynomial != 0.0f ? 1.0f / polynomial : std::numeric_limits<float>::max();
}
}

CompiledEfu::Result CompiledEfu::evaluateRuntimeFused(uint32_t function, unsigned component,
    const std::array<uint32_t, 4> &source)
{
    if (component >= 4) throw std::invalid_argument("Invalid EFU component");
    const float x = unpack(source[0]), y = unpack(source[1]), z = unpack(source[2]);
    const float value = unpack(source[component]);
    float result;
    uint32_t latency;
    switch (function)
    {
    case 0x70: result = std::fma(z, z, std::fma(y, y, x * x)); latency = 11; break;
    case 0x71:
        result = std::fma(z, z, std::fma(y, y, x * x));
        result = result != 0.0f ? 1.0f / result : result;
        latency = 18; break;
    case 0x72: result = std::sqrt(std::fma(z, z, std::fma(y, y, x * x))); latency = 18; break;
    case 0x73:
        result = std::sqrt(std::fma(z, z, std::fma(y, y, x * x)));
        result = result != 0.0f ? 1.0f / result : result;
        latency = 24; break;
    case 0x74: result = x != 0.0f ? atanPolynomial(y / x) : 0.0f; latency = 54; break;
    case 0x75: result = x != 0.0f ? atanPolynomial(z / x) : 0.0f; latency = 54; break;
    case 0x76:
        result = 0.0f;
        for (auto bits : source) result += unpack(bits);
        latency = 12; break;
    case 0x77:
        result = value;
        if (result >= 0.0f)
        {
            result = std::sqrt(result);
            if (result != 0.0f) result = 1.0f / result;
        }
        latency = 18; break;
    case 0x78: result = value >= 0.0f ? std::sqrt(value) : value; latency = 12; break;
    case 0x79: result = sinPolynomial(value); latency = 29; break;
    case 0x7a: result = value != 0.0f ? 1.0f / value : value; latency = 12; break;
    case 0x7c: result = atanPolynomial(value); latency = 54; break;
    case 0x7d: result = expPolynomial(value); latency = 44; break;
    default: throw std::invalid_argument("Unsupported EFU arithmetic function");
    }
    uint32_t bits;
    std::memcpy(&bits, &result, sizeof(bits));
    return {normalize(bits), latency};
}
