#pragma once
#include "MIPS.h"

bool emitDirectFmac(CMIPS *, CMipsJitter *, uint32 opcode, uint32 cycle, uint32 hints);
bool directFmacTests();
