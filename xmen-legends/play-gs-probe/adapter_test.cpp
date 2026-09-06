#include "runtime_adapter.h"
#include "runtime/gs/gs_cpu_backend.h"
#include <cstdio>
#include <stdexcept>
#include <chrono>
#include <string_view>

int main(int argc, char** argv)
{
    try
    {
        std::vector<uint8_t> gpuRam(4 * 1024 * 1024), cpuRam(gpuRam.size());
        auto gpu = MakePlayGsBackend(std::make_unique<GSCpuBackend>());
        GSCpuBackend cpu;
        gpu->Initialize(gpuRam.data(), uint32_t(gpuRam.size()));
        cpu.Initialize(cpuRam.data(), uint32_t(cpuRam.size()));
        GSPrimitiveBatch batch{};
        batch.vertexCount = 2;
        auto& state = batch.state;
        state.prim.type = GS_PRIM_SPRITE;
        state.context.frame.fbw = 1;
        state.context.scissor = {0, 63, 0, 63};
        state.context.zbuf.zmask = true;
        state.context.test = (1 << 16) | (1 << 17);
        state.colclamp = 1;
        for(auto& v : batch.vertices) { v.r = 16; v.g = 32; v.b = 64; v.a = 128; }
        batch.vertices[1].x = 16;
        batch.vertices[1].y = 16;
        gpu->Submit(batch);
        cpu.Submit(batch);
        auto compare = [&](const char* label) {
            std::vector<uint8_t> actual, expected;
            gpu->SnapshotVram(actual);
            cpu.SnapshotVram(expected);
            if(actual != expected)
            {
                for(size_t i = 0; i < expected.size(); ++i)
                    if(actual[i] != expected[i]) {
                        std::fprintf(stderr, "[gs-adapter:failed] case=%s byte=%zu gpu=%02x cpu=%02x\n",
                                     label, i, actual[i], expected[i]);
                        break;
                    }
                throw std::runtime_error("GPU/CPU VRAM mismatch");
            }
            std::printf("[gs-adapter:case] name=%s bytes=%zu\n", label, actual.size());
        };
        compare("sprite");
        auto triangle = batch;
        triangle.vertexCount = 3;
        triangle.state.prim.type = GS_PRIM_TRISTRIP;
        triangle.vertices[0].x = 32; triangle.vertices[0].y = 0;
        triangle.vertices[1].x = 48; triangle.vertices[1].y = 0;
        triangle.vertices[2].x = 32; triangle.vertices[2].y = 16;
        gpu->Submit(triangle); cpu.Submit(triangle);
        compare("independent-strip-triangle");
        std::array<uint8_t, 256> indices;
        std::array<uint32_t, 256> palette;
        GSTransferCommand transfer{};
        transfer.direction = 0;
        transfer.bitbltbuf.dbw = 1;
        transfer.trxreg = {16, 16};
        auto upload = [&](uint32_t base, uint8_t psm, const void* data, uint32_t size) {
            transfer.bitbltbuf.dbp = base;
            transfer.bitbltbuf.dpsm = psm;
            gpu->BeginTransfer(transfer); cpu.BeginTransfer(transfer);
            const uint32_t first = psm == GS_PSM_T8 ? 31 : size;
            gpu->UploadImage(static_cast<const uint8_t*>(data), first);
            cpu.UploadImage(static_cast<const uint8_t*>(data), first);
            if(first < size)
            {
                gpu->UploadImage(static_cast<const uint8_t*>(data) + first, size - first);
                cpu.UploadImage(static_cast<const uint8_t*>(data) + first, size - first);
            }
        };
        for(unsigned i = 0; i < 256; ++i) { indices[i] = uint8_t(i); palette[i] = 0x80000000 | (i * 0x10203); }
        upload(256, GS_PSM_T8, indices.data(), uint32_t(indices.size()));
        upload(512, GS_PSM_CT32, palette.data(), uint32_t(sizeof(palette)));
        compare("upload");
        state.prim.tme = true;
        state.prim.fst = true;
        state.textureWidth = state.textureHeight = 16;
        state.context.tex0 = {256, 1, GS_PSM_T8, 4, 4, 1, 1, 512, GS_PSM_CT32, 0, 0, 1};
        batch.vertices[1].u = batch.vertices[1].v = 256;
        for(unsigned phase = 0; phase < 3; ++phase)
        {
            if(phase == 1)
            {
                for(auto& p : palette) p ^= 0x00ffffff;
                upload(512, GS_PSM_CT32, palette.data(), uint32_t(sizeof(palette)));
            }
            state.context.tex0.cld = phase == 1 ? 0 : 1;
            gpu->LoadClut(state.context.tex0, state.texclut);
            cpu.LoadClut(state.context.tex0, state.texclut);
            gpu->Submit(batch); cpu.Submit(batch);
            compare(phase == 0 ? "indexed" : phase == 1 ? "palette-skip" : "palette-reload");
        }
        transfer.direction = 2;
        transfer.bitbltbuf = {0, 1, GS_PSM_CT32, 0, 1, GS_PSM_CT32};
        transfer.trxpos = {0, 0, 32, 32, 0};
        gpu->BeginTransfer(transfer); cpu.BeginTransfer(transfer);
        compare("local-copy");
        transfer.direction = 1;
        transfer.trxpos = {32, 32, 0, 0, 0};
        gpu->BeginTransfer(transfer); cpu.BeginTransfer(transfer);
        std::array<uint8_t, 1024> gpuRead{}, cpuRead{};
        const auto gpuBytes = gpu->ConsumeLocalToHostBytes(gpuRead.data(), uint32_t(gpuRead.size()));
        const auto cpuBytes = cpu.ConsumeLocalToHostBytes(cpuRead.data(), uint32_t(cpuRead.size()));
        if(gpuBytes != 1024 || gpuBytes != cpuBytes || gpuRead != cpuRead)
            throw std::runtime_error("Local-to-host mismatch");
        std::puts("[gs-adapter:case] name=local-to-host bytes=1024");
        GSPresentationRequest request{};
        request.pmode = 1;
        request.dispfb1 = uint64_t(1) << 9;
        request.display1 = (uint64_t(63) << 32) | (uint64_t(63) << 44);
        const auto gpuFrame = gpu->Present(request);
        const auto cpuFrame = cpu.Present(request);
        if(!gpuFrame || gpuFrame.pixels != cpuFrame.pixels || gpuFrame.width != cpuFrame.width ||
           gpuFrame.height != cpuFrame.height || gpuFrame.sourceFbp != cpuFrame.sourceFbp)
            throw std::runtime_error("CPU display composition mismatch");
        std::puts("[gs-adapter:case] name=presentation match=1");
        if(!gpu->ClearFramebuffer(state.context, 0x80554433) ||
           !cpu.ClearFramebuffer(state.context, 0x80554433))
            throw std::runtime_error("Framebuffer clear failed");
        compare("cpu-clear-to-gpu");
        gpu->WriteVram(GS_PSM_CT32, 0, 1, 0, 0, 0x80776655);
        cpu.WriteVram(GS_PSM_CT32, 0, 1, 0, 0, 0x80776655);
        if(gpu->ReadVram(GS_PSM_CT32, 0, 1, 0, 0) != 0x80776655)
            throw std::runtime_error("Direct VRAM read mismatch");
        compare("cpu-write-to-gpu");
        gpu->Reset(); cpu.Reset();
        compare("reset-preserves-vram");
        if(argc == 2 && std::string_view(argv[1]) == "--benchmark")
        {
            upload(0x3000, GS_PSM_T8, indices.data(), uint32_t(indices.size()));
            upload(0x3800, GS_PSM_CT32, palette.data(), uint32_t(sizeof(palette)));
            state.context.tex0.tbp0 = 0x3000;
            state.context.tex0.cbp = 0x3800;
            state.context.tex0.cld = 1;
            gpu->LoadClut(state.context.tex0, state.texclut);
            cpu.LoadClut(state.context.tex0, state.texclut);
            state.context.frame.fbw = 10;
            state.context.scissor = {0, 639, 0, 447};
            batch.vertexCount = 3;
            state.prim.type = GS_PRIM_TRIANGLE;
            for(auto& vertex : batch.vertices) vertex.a = vertex.r = vertex.g = vertex.b = 128;
            auto run = [&](GSRasterBackend& backend, unsigned count, unsigned width, unsigned height) {
                const auto start = std::chrono::steady_clock::now();
                for(unsigned i = 0; i < count; ++i)
                {
                    const unsigned x = (i * 8) % (640 - width);
                    const unsigned y = ((i / 64) * 8) % (448 - height);
                    batch.vertices[0].x = float(x); batch.vertices[0].y = float(y);
                    batch.vertices[0].u = 0; batch.vertices[0].v = 0;
                    batch.vertices[1].x = float(x + width); batch.vertices[1].y = float(y);
                    batch.vertices[1].u = 256; batch.vertices[1].v = 0;
                    batch.vertices[2].x = float(x); batch.vertices[2].y = float(y + height);
                    batch.vertices[2].u = 0; batch.vertices[2].v = 256;
                    backend.Submit(batch);
                }
                const auto submitted = std::chrono::steady_clock::now();
                std::vector<uint8_t> snapshot;
                backend.SnapshotVram(snapshot);
                const auto finished = std::chrono::steady_clock::now();
                std::printf("[gs-adapter:timing-parts] draws=%u submit-ms=%.6f readback-ms=%.6f\n", count,
                    std::chrono::duration<double, std::milli>(submitted - start).count(),
                    std::chrono::duration<double, std::milli>(finished - submitted).count());
                return std::chrono::duration<double, std::milli>(finished - start).count();
            };
            // Warm both paths and their native shader caches before paired measurements.
            run(*gpu, 1, 8, 8); run(cpu, 1, 8, 8);
            for(unsigned workload = 0; workload < 2; ++workload)
            {
                const unsigned count = workload ? 512 : 23424;
                const unsigned width = workload ? 160 : 8;
                const unsigned height = workload ? 112 : 8;
                for(unsigned pair = 0; pair < 3; ++pair)
                {
                    double gpuMs, cpuMs;
                    if(pair & 1) { cpuMs = run(cpu, count, width, height); gpuMs = run(*gpu, count, width, height); }
                    else { gpuMs = run(*gpu, count, width, height); cpuMs = run(cpu, count, width, height); }
                    compare("benchmark-final-vram");
                    std::printf("[gs-adapter:benchmark] workload=%u pair=%u draws=%u gpu-ms=%.6f cpu-ms=%.6f\n",
                                 workload, pair, count, gpuMs, cpuMs);
                }
            }
            std::puts("[gs-adapter:benchmark-passed] pairs=6 gameplay-fps=unmeasured");
        }
        std::puts("[gs-adapter:passed] cases=12 windows=0");
        return 0;
    }
    catch(const std::exception& error)
    {
        std::fprintf(stderr, "[gs-adapter:failed] %s\n", error.what());
        return 1;
    }
}
