#include <Windows.h>
#include <vulkan/vulkan.h>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <vector>

namespace
{
void check(VkResult result, const char *operation)
{
    if (result != VK_SUCCESS)
    {
        std::fprintf(stderr, "[gs-gpu:error] operation=%s result=%d\n", operation, int(result));
        throw std::runtime_error(operation);
    }
}

template<typename T>
T entry(PFN_vkGetInstanceProcAddr get, VkInstance instance, const char *name)
{
    const auto result = reinterpret_cast<T>(get(instance, name));
    if (!result) throw std::runtime_error(name);
    return result;
}
}

int main()
{
    HMODULE library = LoadLibraryExW(L"vulkan-1.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!library)
    {
        std::fprintf(stderr, "[gs-gpu:error] System Vulkan loader unavailable\n");
        return 1;
    }
    VkInstance instance = VK_NULL_HANDLE;
    PFN_vkDestroyInstance destroy = nullptr;
    int status = 0;
    try
    {
        const auto get = reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(library, "vkGetInstanceProcAddr"));
        if (!get) throw std::runtime_error("vkGetInstanceProcAddr");
        const auto create = entry<PFN_vkCreateInstance>(get, VK_NULL_HANDLE, "vkCreateInstance");
        VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
        app.pApplicationName = "OpenXML1 offscreen capability check";
        app.apiVersion = VK_API_VERSION_1_1;
        VkInstanceCreateInfo info{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        info.pApplicationInfo = &app;
        check(create(&info, nullptr, &instance), "create-instance");
        destroy = entry<PFN_vkDestroyInstance>(get, instance, "vkDestroyInstance");
        const auto enumerate = entry<PFN_vkEnumeratePhysicalDevices>(get, instance, "vkEnumeratePhysicalDevices");
        const auto properties = entry<PFN_vkGetPhysicalDeviceProperties>(get, instance, "vkGetPhysicalDeviceProperties");
        const auto extensions = entry<PFN_vkEnumerateDeviceExtensionProperties>(get, instance, "vkEnumerateDeviceExtensionProperties");
        const auto features = entry<PFN_vkGetPhysicalDeviceFeatures2>(get, instance, "vkGetPhysicalDeviceFeatures2");
        const auto queues = entry<PFN_vkGetPhysicalDeviceQueueFamilyProperties>(get, instance, "vkGetPhysicalDeviceQueueFamilyProperties");
        uint32_t count = 0;
        check(enumerate(instance, &count, nullptr), "device-count");
        if (!count || count > 64) throw std::runtime_error("Invalid physical device count");
        std::vector<VkPhysicalDevice> devices(count);
        check(enumerate(instance, &count, devices.data()), "devices");
        uint32_t interlockDevices = 0;
        uint32_t rendererDevices = 0;
        for (uint32_t i = 0; i < count; ++i)
        {
            VkPhysicalDeviceProperties props{};
            properties(devices[i], &props);
            uint32_t extensionCount = 0;
            check(extensions(devices[i], nullptr, &extensionCount, nullptr), "extension-count");
            if (extensionCount > 65536) throw std::runtime_error("Invalid extension count");
            std::vector<VkExtensionProperties> list(extensionCount);
            check(extensions(devices[i], nullptr, &extensionCount, list.data()), "extensions");
            bool interlock = false, rasterOrder = false, swapchain = false;
            for (const auto &extension : list)
            {
                interlock |= std::strcmp(extension.extensionName, VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME) == 0;
                rasterOrder |= std::strcmp(extension.extensionName, VK_EXT_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_EXTENSION_NAME) == 0;
                swapchain |= std::strcmp(extension.extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
            }
            VkPhysicalDeviceFragmentShaderInterlockFeaturesEXT ordering{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FRAGMENT_SHADER_INTERLOCK_FEATURES_EXT};
            VkPhysicalDeviceFeatures2 supported{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2};
            VkPhysicalDevice16BitStorageFeatures storage16{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_16BIT_STORAGE_FEATURES};
            VkPhysicalDeviceVulkan12Features version12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES};
            supported.pNext = &storage16;
            if (props.apiVersion >= VK_API_VERSION_1_2)
            {
                storage16.pNext = &version12;
                if (interlock) version12.pNext = &ordering;
            }
            else if (interlock) storage16.pNext = &ordering;
            features(devices[i], &supported);
            uint32_t queueCount = 0;
            queues(devices[i], &queueCount, nullptr);
            if (!queueCount || queueCount > 1024) throw std::runtime_error("Invalid queue count");
            std::vector<VkQueueFamilyProperties> queueProperties(queueCount);
            queues(devices[i], &queueCount, queueProperties.data());
            const auto requiredQueues = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
            const bool queueZero = queueProperties[0].queueCount &&
                (queueProperties[0].queueFlags & requiredQueues) == requiredQueues;
            const bool pixelInterlock = interlock && ordering.fragmentShaderPixelInterlock;
            interlockDevices += pixelInterlock ? 1u : 0u;
            const bool rendererFeatures = pixelInterlock && swapchain && queueZero &&
                supported.features.fragmentStoresAndAtomics && supported.features.shaderInt16 &&
                version12.shaderInt8 && version12.storageBuffer8BitAccess && version12.uniformAndStorageBuffer8BitAccess &&
                storage16.storageBuffer16BitAccess && storage16.uniformAndStorageBuffer16BitAccess;
            rendererDevices += rendererFeatures ? 1u : 0u;
            std::printf("[gs-gpu:device] index=%u name=%s api=%u.%u.%u pixel-interlock=%u raster-order-extension=%u fragment-stores=%u shader-int16=%u\n",
                i, props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion), VK_API_VERSION_MINOR(props.apiVersion),
                VK_API_VERSION_PATCH(props.apiVersion), pixelInterlock ? 1u : 0u, rasterOrder ? 1u : 0u,
                supported.features.fragmentStoresAndAtomics, supported.features.shaderInt16);
            std::printf("[gs-gpu:play-features] index=%u shader-int8=%u storage8=%u uniform-storage8=%u storage16=%u uniform-storage16=%u swapchain=%u queue-zero=%u supported=%u\n",
                i, version12.shaderInt8, version12.storageBuffer8BitAccess, version12.uniformAndStorageBuffer8BitAccess,
                storage16.storageBuffer16BitAccess, storage16.uniformAndStorageBuffer16BitAccess,
                swapchain ? 1u : 0u, queueZero ? 1u : 0u, rendererFeatures ? 1u : 0u);
        }
        std::printf("[gs-gpu:capabilities] devices=%u pixel-interlock-devices=%u play-feature-devices=%u rendering-tested=0 windows=0\n",
            count, interlockDevices, rendererDevices);
    }
    catch (const std::exception &error)
    {
        std::fprintf(stderr, "[gs-gpu:error] %s\n", error.what());
        status = 1;
    }
    if (instance && destroy) destroy(instance, nullptr);
    FreeLibrary(library);
    return status;
}
