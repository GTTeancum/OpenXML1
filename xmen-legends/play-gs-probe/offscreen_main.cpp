#include "gs/GSH_Vulkan/GSH_VulkanOffscreen.h"
#include <cstdio>
#include <stdexcept>
#include <array>

namespace
{
    constexpr uint64 Frame = uint64(1) << 16;
    constexpr uint64 TextureBase = 0x100;
    constexpr uint64 PaletteBase = 0x200;

    uint64 Position(unsigned x, unsigned y)
    {
        return (uint64(y * 16) << 16) | (x * 16);
    }

    void Upload(CGSHandler& gs, uint64 base, unsigned psm, const void* data, unsigned bytes)
    {
        gs.WriteRegister({GS_REG_BITBLTBUF, (base << 32) | (uint64(1) << 48) | (uint64(psm) << 56)});
        gs.WriteRegister({GS_REG_TRXPOS, 0});
        gs.WriteRegister({GS_REG_TRXREG, 16 | (uint64(16) << 32)});
        gs.WriteRegister({GS_REG_TRXDIR, 0});
        gs.ProcessWriteBuffer(nullptr);
        gs.FeedImageData(data, bytes);
    }

    uint32 PaletteColor(unsigned index, bool changed)
    {
        const unsigned r = changed ? 255 - index : index;
        const unsigned g = (index * 13 + 7) & 255;
        const unsigned b = (index * 23 + (changed ? 81 : 19)) & 255;
        return r | (g << 8) | (b << 16) | 0x80000000;
    }

    template<typename Expected>
    unsigned Verify(CGSH_VulkanOffscreen& gs, const char* label, Expected expected)
    {
        gs.ProcessWriteBuffer(nullptr);
        gs.Finish(true);
        const auto bitmap = gs.GetFramebuffer(Frame);
        if(bitmap.GetWidth() != 64 || bitmap.GetHeight() != 1024 || bitmap.GetBitsPerPixel() != 32)
            throw std::runtime_error("Unexpected native framebuffer dimensions");
        for(unsigned y = 0; y < 64; y++)
        {
            for(unsigned x = 0; x < 64; x++)
            {
                const auto color = bitmap.GetPixel(x, y);
                // Play ReadImage32 exports BGRA bytes through CBitmap.
                const uint32 actual = color.b | (uint32(color.g) << 8) |
                                      (uint32(color.r) << 16) | (uint32(color.a) << 24);
                const uint32 wanted = expected(x, y);
                if(actual != wanted)
                {
                    std::fprintf(stderr, "[gs-gpu:failed] case=%s x=%u y=%u actual=%08x expected=%08x\n",
                                 label, x, y, actual, wanted);
                    throw std::runtime_error("GPU pixel mismatch");
                }
            }
        }
        std::printf("[gs-gpu:case] name=%s matched=4096\n", label);
        return 4096;
    }

    struct Renderer
    {
        CGSH_VulkanOffscreen gs;
        bool initialized = false;
        ~Renderer() { if(initialized) gs.Release(); }
    };
}

int main()
{
    try
    {
        Renderer renderer;
        auto& gs = renderer.gs;
        gs.SetLoggingEnabled(false);
        gs.Initialize();
        renderer.initialized = true;
        gs.Reset();
        std::puts("[gs-gpu:render] initialized=1 windows=0");
        std::fflush(stdout);
        gs.WriteRegister({GS_REG_PRMODECONT, 1});
        gs.WriteRegister({GS_REG_FRAME_1, Frame});
        gs.WriteRegister({GS_REG_ZBUF_1, uint64(1) << 32});
        gs.WriteRegister({GS_REG_SCISSOR_1, (uint64(63) << 16) | (uint64(63) << 48)});
        gs.WriteRegister({GS_REG_TEST_1, (uint64(1) << 16) | (uint64(1) << 17)});
        gs.WriteRegister({GS_REG_COLCLAMP, 1});
        gs.WriteRegister({GS_REG_PRIM, CGSHandler::PRIM_SPRITE});
        gs.WriteRegister({GS_REG_RGBAQ, 0x80402010});
        gs.WriteRegister({GS_REG_XYZ2, 0});
        gs.WriteRegister({GS_REG_XYZ2, (uint64(16 * 16) << 16) | (16 * 16)});
        gs.WriteRegister({GS_REG_PRIM, CGSHandler::PRIM_TRIANGLE});
        gs.WriteRegister({GS_REG_RGBAQ, 0x802060a0});
        for(const auto position : {Position(32, 0), Position(48, 0), Position(32, 16),
                                   Position(48, 0), Position(48, 16), Position(32, 16)})
            gs.WriteRegister({GS_REG_XYZ2, position});
        unsigned matched = Verify(gs, "sprite-triangles", [](unsigned x, unsigned y) -> uint32 {
            if(x < 16 && y < 16) return 0x80402010;
            if(x >= 32 && x < 48 && y < 16) return 0x802060a0;
            return 0;
        });

        std::array<uint8, 256> indices;
        std::array<uint32, 256> palette;
        for(unsigned phase = 0; phase < 4; phase++)
        {
            if(phase == 0 || phase == 3)
            {
                for(unsigned i = 0; i < 256; i++) indices[i] = uint8(phase == 3 ? 255 - i : i);
                Upload(gs, TextureBase, CGSHandler::PSMT8, indices.data(), unsigned(indices.size()));
            }
            if(phase <= 1)
            {
                for(unsigned i = 0; i < 256; i++)
                {
                    const unsigned clutIndex = (i & ~0x18) | ((i & 8) << 1) | ((i & 16) >> 1);
                    palette[i] = PaletteColor(clutIndex, phase == 1);
                }
                Upload(gs, PaletteBase, CGSHandler::PSMCT32, palette.data(), unsigned(sizeof(palette)));
            }
            const uint64 cld = (phase == 0 || phase == 2) ? 1 : 0;
            gs.WriteRegister({GS_REG_TEX0_1, TextureBase | (uint64(1) << 14) |
                (uint64(CGSHandler::PSMT8) << 20) | (uint64(4) << 26) | (uint64(4) << 30) |
                (uint64(1) << 34) | (uint64(CGSHandler::TEX0_FUNCTION_DECAL) << 35) |
                (PaletteBase << 37) | (cld << 61)});
            gs.WriteRegister({GS_REG_PRIM, CGSHandler::PRIM_SPRITE | (1 << 4) | (1 << 8)});
            gs.WriteRegister({GS_REG_UV, 0});
            gs.WriteRegister({GS_REG_XYZ2, Position(0, 0)});
            gs.WriteRegister({GS_REG_UV, Position(16, 16)});
            gs.WriteRegister({GS_REG_XYZ2, Position(16, 16)});
            const char* labels[] = {"indexed-load", "palette-skip", "palette-reload", "live-indices"};
            matched += Verify(gs, labels[phase], [phase](unsigned x, unsigned y) -> uint32 {
                if(x < 16 && y < 16)
                    return PaletteColor(phase == 3 ? 255 - (x + y * 16) : x + y * 16, phase >= 2);
                if(x >= 32 && x < 48 && y < 16) return 0x802060a0;
                return 0;
            });
        }
        std::printf("[gs-gpu:offscreen] matched=%u cases=5 rendering-tested=1 windows=0\n", matched);
        return 0;
    }
    catch(const std::exception& error)
    {
        std::fprintf(stderr, "[gs-gpu:failed] %s\n", error.what());
        return 1;
    }
}
