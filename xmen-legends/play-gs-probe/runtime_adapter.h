#pragma once
#include "runtime/gs/gs_backend.h"
#include <memory>

// CPU delegate retains transfer bookkeeping and the existing display compositor.
std::unique_ptr<GSRasterBackend> MakePlayGsBackend(std::unique_ptr<GSRasterBackend> cpu);
