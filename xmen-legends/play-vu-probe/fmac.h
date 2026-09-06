#pragma once
#include "MIPS.h"

using FmacOperation = uint32 (*)(CMIPS *, uint32);
FmacOperation selectFmac(uint32 opcode);
FmacOperation selectFmacScalar(uint32 opcode);
bool fmacAvx2Available();
bool fmacTests();
