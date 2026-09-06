#include "fmac_emitter.h"
#include "MipsJitter.h"
#include "ee/VUShared.h"
#include <cstddef>

namespace
{
enum class Operation { Add, Subtract, Multiply };
struct Operand { size_t offset; bool expand; };

void push(CMipsJitter *jitter, Operand operand)
{
    if (operand.expand) { jitter->PushRel(operand.offset); jitter->MD_ExpandW(); }
    else jitter->MD_PushRel(operand.offset);
}

void magnitude(CMipsJitter *jitter, Operand operand)
{
    push(jitter, operand);
    jitter->MD_PushCstExpandW(0x7fffffff);
    jitter->MD_And();
}

void outsideRange(CMipsJitter *jitter, Operand operand)
{
    magnitude(jitter, operand);
    jitter->MD_PushCstExpandW(0x4f800000);
    jitter->MD_CmpGtW();
    jitter->MD_PushCstExpandW(0x2f800000);
    magnitude(jitter, operand);
    jitter->MD_CmpGtW();
    magnitude(jitter, operand);
    jitter->MD_PushCstExpandW(0);
    jitter->MD_CmpEqW();
    jitter->MD_Not();
    jitter->MD_And();
    jitter->MD_Or();
}
}

bool emitDirectFmac(CMIPS *cpu, CMipsJitter *jitter, uint32 opcode, uint32 cycle, uint32 hints)
{
    const uint32 mask = (opcode >> 21) & 15;
    if (!mask || !cpu->m_vuFmacCompiler) return false;
    const auto fallback = cpu->m_vuFmacCompiler(opcode);
    if (!fallback) return false;
    const bool accumulator = (opcode & 63) >= 0x3c;
    const uint32 function = accumulator ? (opcode & 3) | ((opcode >> 4) & 0x7c) : opcode & 63;
    const uint32 fs = (opcode >> 11) & 31, ft = (opcode >> 16) & 31, fd = (opcode >> 6) & 31;
    Operand left{offsetof(CMIPS, m_State.nCOP2) + fs * 16, false};
    Operand right{offsetof(CMIPS, m_State.nCOP2) + ft * 16, false};
    Operation operation;
    if (function < 8 || (function >= 0x18 && function <= 0x1b))
    {
        operation = function < 4 ? Operation::Add : function < 8 ? Operation::Subtract : Operation::Multiply;
        right.offset += (function & 3) * 4;
        right.expand = true;
    }
    else if (function == 0x1c || function == 0x1e || function == 0x20 || function == 0x22 || function == 0x24 || function == 0x26)
    {
        operation = function < 0x20 ? Operation::Multiply : function < 0x24 ? Operation::Add : Operation::Subtract;
        right = {(function & 2) ? offsetof(CMIPS, m_State.nCOP2I) : offsetof(CMIPS, m_State.nCOP2Q), true};
    }
    else if (function == 0x28 || function == 0x2a || function == 0x2c)
        operation = function == 0x28 ? Operation::Add : function == 0x2c ? Operation::Subtract : Operation::Multiply;
    else return false;

    const size_t output = accumulator ? offsetof(CMIPS, m_State.nCOP2A) :
        offsetof(CMIPS, m_State.nCOP2) + (fd ? fd : 32) * 16;
    hints &= ~VUShared::COMPILEHINT_SKIP_FMAC_UPDATE;

    // Zeros or operands in [2^-32, 2^32] cannot underflow/overflow these three
    // operations. Their float result has the exact sign/zero classification.
    // Other values use the established normalization and widened flag helper.
    outsideRange(jitter, left);
    outsideRange(jitter, right);
    jitter->MD_Or();
    jitter->MD_MakeSignZero();
    jitter->PushCst(mask << 4);
    jitter->And();
    jitter->PushCst(0);
    jitter->BeginIf(Jitter::CONDITION_EQ);
    {
        push(jitter, left);
        push(jitter, right);
        if (operation == Operation::Add) jitter->MD_AddS();
        else if (operation == Operation::Subtract) jitter->MD_SubS();
        else jitter->MD_MulS();
        VUShared::PullVector(jitter, static_cast<uint8>(mask), output);
        VUShared::TestSZFlags(jitter, static_cast<uint8>(mask), output, cycle, hints);
    }
    jitter->Else();
    {
        jitter->PushCtx();
        jitter->PushCst(opcode);
        jitter->Call(reinterpret_cast<void *>(fallback), 2, Jitter::CJitter::RETURN_VALUE_32);
        VUShared::QueueFmacFlags(jitter, cycle, hints);
    }
    jitter->EndIf();
    return true;
}
