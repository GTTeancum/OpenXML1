#pragma once
#include <cstddef>
#include <cstdint>
#include <memory>

namespace PlayGs
{
    struct Register { std::uint8_t address; std::uint64_t value; };
    class Renderer
    {
    public:
        Renderer();
        ~Renderer();
        Renderer(const Renderer&) = delete;
        Renderer& operator=(const Renderer&) = delete;
        void Write(const Register*, std::size_t);
        void Upload(const std::uint8_t*, std::uint32_t);
        void Flush();
        void Snapshot(std::uint8_t*);
        void Import(const std::uint8_t*);
        void Reset();
    private:
        struct Impl;
        std::unique_ptr<Impl> impl;
    };
}
