#include <cstdio>
int selected_value();
int retained_value();
int runner_extra();
#ifndef RUNNER_BUILD_BONUS
#define RUNNER_BUILD_BONUS 0
#endif
int main() { std::printf("%d\n", selected_value() + retained_value() + RUNNER_BUILD_BONUS + runner_extra()); }
