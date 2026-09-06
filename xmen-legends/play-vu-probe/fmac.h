#pragma once
#include "MIPS.h"

using FmacOperation = uint32 (*)(CMIPS *, uint32);
FmacOperation selectFmac(uint32 opcode);
FmacOperation selectFmacScalar(uint32 opcode);
FmacOperation selectFmacRuntimeFused(uint32 opcode);
FmacOperation selectFmacScalarFused(uint32 opcode);
bool fmacAvx2Available();
bool fmacFmaAvailable();
bool fmacTests();
