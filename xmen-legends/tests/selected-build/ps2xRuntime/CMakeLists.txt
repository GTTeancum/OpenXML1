add_library(selected_fixture STATIC selected.cpp retained.cpp)
add_executable(selected_runner main.cpp)
target_link_libraries(selected_runner PRIVATE selected_fixture)
