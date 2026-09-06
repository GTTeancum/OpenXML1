#include "renderer_bridge.h"
#include "gs/GSH_Vulkan/GSH_VulkanOffscreen.h"
#include <cstring>

namespace PlayGs
{
    struct Renderer::Impl : CGSH_VulkanOffscreen
    {
        std::size_t pending = 0;
        void Snapshot(std::uint8_t* output)
        {
            Finish(true);
            pending = 0;
            SendGSCall([&] {
                SyncMemoryCache();
                std::memcpy(output, GetRam(), RAMSIZE);
            }, true);
        }
        void Import(const std::uint8_t* input)
        {
            Finish(true);
            pending = 0;
            SendGSCall([&] {
                std::memcpy(GetRam(), input, RAMSIZE);
                WriteBackMemoryCache();
            }, true);
        }
    };
    Renderer::Renderer() : impl(std::make_unique<Impl>())
    {
        impl->SetLoggingEnabled(false);
        impl->Initialize();
        impl->Reset();
    }
    Renderer::~Renderer() { impl->Release(); }
    void Renderer::Write(const Register* registers, std::size_t count)
    {
        for(std::size_t i = 0; i < count; ++i)
        {
            // Retire before reusing Play's bounded register buffers.
            if(impl->pending >= 0x100000)
            {
                impl->ProcessWriteBuffer(nullptr);
                impl->Finish(true);
                impl->pending = 0;
            }
            impl->WriteRegister({registers[i].address, registers[i].value});
            ++impl->pending;
        }
        impl->ProcessWriteBuffer(nullptr);
    }
    void Renderer::Upload(const std::uint8_t* data, std::uint32_t size) { impl->FeedImageData(data, size); }
    void Renderer::Flush() { impl->SubmitWriteBuffer(); }
    void Renderer::Snapshot(std::uint8_t* output) { impl->Snapshot(output); }
    void Renderer::Import(const std::uint8_t* input) { impl->Import(input); }
    void Renderer::Reset()
    {
        impl->Finish(true);
        impl->pending = 0;
        impl->Reset();
    }
}
