#include "runtime_adapter.h"
#include "renderer_bridge.h"
#include "runtime/runtime_profile.h"
#include <bit>
#include <mutex>
#include <stdexcept>
#include <cstring>
#include <cmath>
#include <cstdio>

namespace
{
    constexpr std::size_t RamSize = 4 * 1024 * 1024;
    std::uint64_t Tex0(const GSTex0Reg& t, bool load)
    {
        return t.tbp0 | (uint64_t(t.tbw) << 14) | (uint64_t(t.psm) << 20) |
            (uint64_t(t.tw) << 26) | (uint64_t(t.th) << 30) | (uint64_t(t.tcc) << 34) |
            (uint64_t(t.tfx) << 35) | (uint64_t(t.cbp) << 37) | (uint64_t(t.cpsm) << 51) |
            (uint64_t(t.csm) << 55) | (uint64_t(t.csa) << 56) | (uint64_t(load ? t.cld : 0) << 61);
    }
    std::uint64_t TexClut(const GSTexClutReg& t)
    {
        return t.cbw | (uint64_t(t.cou) << 6) | (uint64_t(t.cov) << 12);
    }
    class Backend final : public GSRasterBackend
    {
        std::unique_ptr<GSRasterBackend> cpu;
        mutable std::mutex mutex;
        mutable std::unique_ptr<PlayGs::Renderer> renderer;
        uint8_t* vram = nullptr;
        std::array<uint64_t, 128> values{};
        std::array<bool, 128> valid{};
        GSRasterDebugCounters counters{};
        std::vector<PlayGs::Register> registers;

        void State(std::vector<PlayGs::Register>& out, uint8_t address, uint64_t value)
        {
            if(!valid[address] || values[address] != value)
            {
                out.push_back({address, value});
                values[address] = value;
                valid[address] = true;
            }
        }
        void SnapshotUnlocked() const { renderer->Snapshot(vram); }
    public:
        explicit Backend(std::unique_ptr<GSRasterBackend> delegate) : cpu(std::move(delegate))
        {
            if(!cpu) throw std::invalid_argument("GPU backend requires a CPU display/transfer delegate");
            registers.reserve(40);
        }
        void Initialize(uint8_t* memory, uint32_t size) override
        {
            std::lock_guard lock(mutex);
            if(!memory || size != RamSize) throw std::invalid_argument("GPU backend requires 4 MiB GS memory");
            vram = memory;
            cpu->Initialize(memory, size);
            renderer = std::make_unique<PlayGs::Renderer>();
            renderer->Import(memory);
            valid.fill(false);
            counters = {};
        }
        void Reset() override
        {
            std::lock_guard lock(mutex);
            if(!renderer) { cpu->Reset(); valid.fill(false); return; }
            SnapshotUnlocked();
            renderer->Reset();
            renderer->Import(vram);
            cpu->Reset();
            valid.fill(false);
        }
        void Submit(const GSPrimitiveBatch& batch) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            const auto& s = batch.state;
            const auto& c = s.context;
            const auto& p = s.prim;
            unsigned type = p.type;
            if(type == GS_PRIM_TRISTRIP || type == GS_PRIM_TRIFAN) type = GS_PRIM_TRIANGLE;
            if(type == GS_PRIM_LINESTRIP) type = GS_PRIM_LINE;
            const unsigned required = type == GS_PRIM_POINT ? 1 : type == GS_PRIM_TRIANGLE ? 3 : 2;
            if(batch.vertexCount != required || type > GS_PRIM_SPRITE)
                throw std::runtime_error("Invalid GPU primitive batch");
            for(unsigned i = 0; i < required; ++i)
            {
                const auto& v = batch.vertices[i];
                if(!std::isfinite(v.x) || !std::isfinite(v.y) || !std::isfinite(v.z) ||
                   v.x < 0 || v.x > 4095.9375f || v.y < 0 || v.y > 4095.9375f ||
                   v.z < 0 || v.z > 4294967295.0)
                    throw std::runtime_error("GPU vertex is outside GS register range");
            }
            auto& regs = registers;
            regs.clear();
            State(regs, GS_REG_PRMODECONT, 1);
            State(regs, GS_REG_FRAME_1, c.frame.fbp | (uint64_t(c.frame.fbw) << 16) |
                (uint64_t(c.frame.psm) << 24) | (uint64_t(c.frame.fbmsk) << 32));
            State(regs, GS_REG_ZBUF_1, c.zbuf.zbp | (uint64_t(c.zbuf.psm & 15) << 24) | (uint64_t(c.zbuf.zmask) << 32));
            State(regs, GS_REG_XYOFFSET_1, c.xyoffset.ofx | (uint64_t(c.xyoffset.ofy) << 32));
            State(regs, GS_REG_SCISSOR_1, c.scissor.x0 | (uint64_t(c.scissor.x1) << 16) |
                (uint64_t(c.scissor.y0) << 32) | (uint64_t(c.scissor.y1) << 48));
            State(regs, GS_REG_TEX0_1, Tex0(c.tex0, false));
            State(regs, GS_REG_TEX1_1, c.tex1);
            State(regs, GS_REG_MIPTBP1_1, c.miptbp1);
            State(regs, GS_REG_MIPTBP2_1, c.miptbp2);
            State(regs, GS_REG_CLAMP_1, c.clamp);
            State(regs, GS_REG_ALPHA_1, c.alpha);
            State(regs, GS_REG_TEST_1, c.test);
            State(regs, GS_REG_FBA_1, c.fba);
            State(regs, GS_REG_TEXA, s.texa.ta0 | (uint64_t(s.texa.aem) << 15) | (uint64_t(s.texa.ta1) << 32));
            State(regs, GS_REG_TEXCLUT, TexClut(s.texclut));
            State(regs, GS_REG_PABE, s.pabe);
            State(regs, GS_REG_SCANMSK, s.scanmsk);
            State(regs, GS_REG_DIMX, s.dimx);
            State(regs, GS_REG_DTHE, s.dthe);
            State(regs, GS_REG_COLCLAMP, s.colclamp);
            State(regs, GS_REG_FOGCOL, s.fogR | (uint64_t(s.fogG) << 8) | (uint64_t(s.fogB) << 16));
            regs.push_back({GS_REG_PRIM, type | (uint64_t(p.iip) << 3) | (uint64_t(p.tme) << 4) |
                (uint64_t(p.fge) << 5) | (uint64_t(p.abe) << 6) | (uint64_t(p.aa1) << 7) |
                (uint64_t(p.fst) << 8) | (uint64_t(p.fix) << 10)});
            for(unsigned i = 0; i < required; ++i)
            {
                const auto& v = batch.vertices[i];
                State(regs, GS_REG_RGBAQ, v.r | (uint64_t(v.g) << 8) | (uint64_t(v.b) << 16) |
                    (uint64_t(v.a) << 24) | (uint64_t(std::bit_cast<uint32_t>(v.q)) << 32));
                State(regs, GS_REG_ST, std::bit_cast<uint32_t>(v.s) | (uint64_t(std::bit_cast<uint32_t>(v.t)) << 32));
                State(regs, GS_REG_UV, v.u | (uint64_t(v.v) << 16));
                State(regs, GS_REG_FOG, uint64_t(v.fog) << 56);
                regs.push_back({GS_REG_XYZ2, uint16_t(v.x * 16) | (uint64_t(uint16_t(v.y * 16)) << 16) |
                    (uint64_t(uint32_t(v.z)) << 32)});
            }
            renderer->Write(regs.data(), regs.size());
            ++counters.submits;
            ++counters.primitiveSubmits[p.type];
            if(counters.submits == 1) std::fprintf(stderr, "[gs:play-vulkan] active=1\n");
        }
        void LoadClut(const GSTex0Reg& tex0, const GSTexClutReg& texclut) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            const PlayGs::Register regs[] = {{GS_REG_TEXCLUT, TexClut(texclut)}, {GS_REG_TEX0_1, Tex0(tex0, true)}};
            renderer->Write(regs, 2);
            valid[GS_REG_TEX0_1] = valid[GS_REG_TEXCLUT] = false;
        }
        void BeginTransfer(const GSTransferCommand& t) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            if(t.direction == 1) SnapshotUnlocked();
            cpu->BeginTransfer(t);
            // CPU local-to-host extraction preserves existing byte/padding semantics.
            if(t.direction == 1) return;
            const auto& b = t.bitbltbuf;
            const auto& p = t.trxpos;
            const PlayGs::Register regs[] = {
                {GS_REG_BITBLTBUF, b.sbp | (uint64_t(b.sbw) << 16) | (uint64_t(b.spsm) << 24) |
                    (uint64_t(b.dbp) << 32) | (uint64_t(b.dbw) << 48) | (uint64_t(b.dpsm) << 56)},
                {GS_REG_TRXPOS, p.ssax | (uint64_t(p.ssay) << 16) | (uint64_t(p.dsax) << 32) |
                    (uint64_t(p.dsay) << 48) | (uint64_t(p.dir) << 59)},
                {GS_REG_TRXREG, t.trxreg.rrw | (uint64_t(t.trxreg.rrh) << 32)},
                {GS_REG_TRXDIR, t.direction}};
            renderer->Write(regs, 4);
        }
        void UploadImage(const uint8_t* data, uint32_t bytes) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            cpu->UploadImage(data, bytes);
            renderer->Upload(data, bytes);
        }
        void Flush() override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            if(renderer) renderer->Flush();
        }
        void TextureFlush() override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            const PlayGs::Register reg{GS_REG_TEXFLUSH, 0};
            renderer->Write(&reg, 1);
        }
        void Sync(GSSyncReason) override { Flush(); }
        PresentationFrame Present(const GSPresentationRequest& request) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            SnapshotUnlocked();
            auto frame = cpu->Present(request);
            ++counters.presents;
            const auto display = cpu->GetDebugCounters();
            counters.lastPresentNonblackPixels = display.lastPresentNonblackPixels;
            counters.lastDisplayFbp = display.lastDisplayFbp;
            counters.lastSourceFbp = display.lastSourceFbp;
            if(counters.presents == 1 || (counters.presents % 128) == 0)
                std::fprintf(stderr, "[gs:play-vulkan-present] presents=%llu submits=%llu nonblack=%llu\n",
                    static_cast<unsigned long long>(counters.presents),
                    static_cast<unsigned long long>(counters.submits),
                    static_cast<unsigned long long>(counters.lastPresentNonblackPixels));
            return frame;
        }
        bool ClearFramebuffer(const GSContext& context, uint32_t rgba) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            SnapshotUnlocked();
            const bool result = cpu->ClearFramebuffer(context, rgba);
            if(result) renderer->Import(vram);
            return result;
        }
        uint32_t ConsumeLocalToHostBytes(uint8_t* dst, uint32_t bytes) override
        {
            std::lock_guard lock(mutex);
            return cpu->ConsumeLocalToHostBytes(dst, bytes);
        }
        uint32_t ReadVram(uint32_t psm, uint32_t base, uint32_t bw, uint32_t x, uint32_t y) const override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            SnapshotUnlocked();
            return cpu->ReadVram(psm, base, bw, x, y);
        }
        void WriteVram(uint32_t psm, uint32_t base, uint32_t bw, uint32_t x, uint32_t y, uint32_t value) override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            SnapshotUnlocked();
            cpu->WriteVram(psm, base, bw, x, y, value);
            renderer->Import(vram);
        }
        void SnapshotVram(std::vector<uint8_t>& out) const override
        {
            RuntimeProfile::Scope profile(RuntimeProfile::Phase::Gs);
            std::lock_guard lock(mutex);
            out.resize(RamSize);
            renderer->Snapshot(out.data());
        }
        GSTransferSnapshot GetTransferSnapshot() const override
        {
            std::lock_guard lock(mutex);
            return cpu->GetTransferSnapshot();
        }
        GSRasterDebugCounters GetDebugCounters() const override
        {
            std::lock_guard lock(mutex);
            return counters;
        }
    };
}

std::unique_ptr<GSRasterBackend> MakePlayGsBackend(std::unique_ptr<GSRasterBackend> cpu)
{
    return std::make_unique<Backend>(std::move(cpu));
}
