#include "AppConfig.h"

fs::path CAppConfig::GetBasePath() const
{
    const auto path = fs::current_path() / ".ps2recomp-vulkan";
    fs::create_directories(path);
    return path;
}
