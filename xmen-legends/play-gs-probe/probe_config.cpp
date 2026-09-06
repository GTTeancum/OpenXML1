#include "AppConfig.h"

fs::path CAppConfig::GetBasePath() const
{
    return fs::current_path();
}
