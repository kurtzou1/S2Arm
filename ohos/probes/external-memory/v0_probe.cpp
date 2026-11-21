// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Standalone OHOS V0 host-memory experiment. NEVER call main inside the game process.
// No WSI, guest code, files, keys, resources or app state. 45 s process watchdog.
#define VK_USE_PLATFORM_OHOS
#include <vulkan/vulkan.h>
#include <native_buffer/native_buffer.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <unistd.h>
#include "transform_spv.h"

static constexpr uint32_t WORDS=4096;
static constexpr VkDeviceSize BYTES=WORDS*sizeof(uint32_t), CAP=16*1024*1024;
static constexpr int UNSUPPORTED=77;
static void watchdog(int) { const char s[]="V0 result=TIMEOUT watchdog=45s\n"; write(2,s,sizeof(s)-1); _exit(124); }
static void check(VkResult result,const char* name) {
    if(result!=VK_SUCCESS) { std::printf("V0 result=FAIL step=%s vkResult=%d\n",name,result); std::fflush(stdout); _exit(1); }
}
#define VK(call) check((call),#call)
static int unsupported(const char* why) { std::printf("V0 result=UNSUPPORTED reason=%s\n",why); return UNSUPPORTED; }
static VkDeviceSize rounded(VkDeviceSize n,VkDeviceSize a) { return (n+a-1)/a*a; }
static bool power2(VkDeviceSize n) { return n && !(n&(n-1)); }

struct State {
    VkInstance instance{}; VkPhysicalDevice physical{}; VkDevice device{}; VkQueue queue{};
    VkBuffer buffer{}; VkDeviceMemory memory{}; void* host{}; void* mapped{};
    VkShaderModule shader{}; VkDescriptorSetLayout setLayout{}; VkDescriptorPool descriptorPool{};
    VkPipelineLayout pipelineLayout{}; VkPipeline pipeline{}; VkCommandPool commandPool{};
    VkFence fence{}; uint32_t family{};
    ~State() {
        // Reached only before submission or after its fence succeeded. No unbounded WaitIdle.
        if(device) {
            if(fence) vkDestroyFence(device,fence,nullptr);
            if(commandPool) vkDestroyCommandPool(device,commandPool,nullptr);
            if(pipeline) vkDestroyPipeline(device,pipeline,nullptr);
            if(pipelineLayout) vkDestroyPipelineLayout(device,pipelineLayout,nullptr);
            if(descriptorPool) vkDestroyDescriptorPool(device,descriptorPool,nullptr);
            if(setLayout) vkDestroyDescriptorSetLayout(device,setLayout,nullptr);
            if(shader) vkDestroyShaderModule(device,shader,nullptr);
            if(mapped) vkUnmapMemory(device,memory);
            if(buffer) vkDestroyBuffer(device,buffer,nullptr);
            if(memory) vkFreeMemory(device,memory,nullptr);
            vkDestroyDevice(device,nullptr);
        }
        free(host); // imported allocation outlives VkDeviceMemory
        if(instance) vkDestroyInstance(instance,nullptr);
    }
};

static VkExternalMemoryProperties external_properties(State& s,VkExternalMemoryHandleTypeFlagBits type) {
    VkPhysicalDeviceExternalBufferInfo info{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO};
    info.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT; info.handleType=type;
    VkExternalBufferProperties p{VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES};
    vkGetPhysicalDeviceExternalBufferProperties(s.physical,&info,&p);
    std::printf("V0 external type=0x%x features=0x%x compatible=0x%x\n",type,
        p.externalMemoryProperties.externalMemoryFeatures,p.externalMemoryProperties.compatibleHandleTypes);
    return p.externalMemoryProperties;
}

static int native_metadata(State& s) {
    // This is deliberately a capability probe, NOT a substitute for existing-pool host import.
    auto props=reinterpret_cast<PFN_vkGetNativeBufferPropertiesOHOS>(vkGetDeviceProcAddr(s.device,"vkGetNativeBufferPropertiesOHOS"));
    if(!props) return unsupported("OHOS_NativeBuffer_entrypoint_missing");
    external_properties(s,VK_EXTERNAL_MEMORY_HANDLE_TYPE_OH_NATIVE_BUFFER_BIT_OHOS);
    OH_NativeBuffer_Config config{};
    config.width=static_cast<int32_t>(BYTES); config.height=1; config.format=NATIVEBUFFER_PIXEL_FMT_BLOB;
    config.usage=NATIVEBUFFER_USAGE_CPU_READ|NATIVEBUFFER_USAGE_CPU_WRITE|NATIVEBUFFER_USAGE_HW_RENDER;
    OH_NativeBuffer* native=OH_NativeBuffer_Alloc(&config);
    if(!native) return unsupported("NativeBuffer_BLOB_allocation_failed");
    VkNativeBufferPropertiesOHOS p{VK_STRUCTURE_TYPE_NATIVE_BUFFER_PROPERTIES_OHOS};
    VkResult vr=props(s.device,native,&p);
    OH_NativeBuffer_Config actual{}; OH_NativeBuffer_GetConfig(native,&actual);
    std::printf("V0 native_metadata vkResult=%d allocationSize=%llu memoryTypeBits=0x%x width=%d height=%d stride=%d format=%d\n",
        vr,static_cast<unsigned long long>(p.allocationSize),p.memoryTypeBits,actual.width,actual.height,actual.stride,actual.format);
    void* cpu=nullptr; int32_t mapped=OH_NativeBuffer_Map(native,&cpu);
    std::printf("V0 native_map result=%d pointer=%p pageRemainder=%llu\n",mapped,cpu,
        static_cast<unsigned long long>(reinterpret_cast<uintptr_t>(cpu)%static_cast<uintptr_t>(getpagesize())));
    if(mapped==0) std::printf("V0 native_unmap result=%d\n",OH_NativeBuffer_Unmap(native));
    std::printf("V0 native_unreference result=%d\n",OH_NativeBuffer_Unreference(native));
    return unsupported("NativeBuffer_metadata_only_cache_ownership_roundtrip_not_implemented");
}

static int host_roundtrip(State& s) {
    auto pointerProps=reinterpret_cast<PFN_vkGetMemoryHostPointerPropertiesEXT>(vkGetDeviceProcAddr(s.device,"vkGetMemoryHostPointerPropertiesEXT"));
    if(!pointerProps) return unsupported("host_pointer_entrypoint_missing");
    VkPhysicalDeviceExternalMemoryHostPropertiesEXT hostLimits{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT};
    VkPhysicalDeviceProperties2 properties{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; properties.pNext=&hostLimits;
    vkGetPhysicalDeviceProperties2(s.physical,&properties);
    VkDeviceSize minAlign=hostLimits.minImportedHostPointerAlignment;
    std::printf("V0 host_requirements hostPage=%d minImportedAlignment=%llu nonCoherentAtom=%llu\n",getpagesize(),
        static_cast<unsigned long long>(minAlign),static_cast<unsigned long long>(properties.properties.limits.nonCoherentAtomSize));
    if(!power2(minAlign)||minAlign>CAP) return unsupported("alignment_outside_bounded_probe");
    auto ext=external_properties(s,VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT);
    if(!(ext.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT)) return unsupported("HOST_ALLOCATION_storage_buffer_not_importable");
    VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
    external.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT;
    VkBufferCreateInfo bc{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; bc.pNext=&external; bc.size=BYTES;
    bc.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT; bc.sharingMode=VK_SHARING_MODE_EXCLUSIVE;
    VK(vkCreateBuffer(s.device,&bc,nullptr,&s.buffer));
    VkMemoryDedicatedRequirements dedicatedReq{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_REQUIREMENTS};
    VkMemoryRequirements2 req{VK_STRUCTURE_TYPE_MEMORY_REQUIREMENTS_2}; req.pNext=&dedicatedReq;
    VkBufferMemoryRequirementsInfo2 ri{VK_STRUCTURE_TYPE_BUFFER_MEMORY_REQUIREMENTS_INFO_2}; ri.buffer=s.buffer;
    vkGetBufferMemoryRequirements2(s.device,&ri,&req);
    // VUID-VkMemoryAllocateInfo-pNext-02806 forbids dedicated buffer/image chains
    // for host-pointer imports, so these requirements cannot be papered over.
    if(dedicatedReq.requiresDedicatedAllocation||(ext.externalMemoryFeatures&VK_EXTERNAL_MEMORY_FEATURE_DEDICATED_ONLY_BIT))
        return unsupported("host_import_conflicts_with_dedicated_requirement");
    if(req.memoryRequirements.size>CAP) return unsupported("memory_requirement_exceeds_bound");
    VkDeviceSize alignment=std::max({minAlign,req.memoryRequirements.alignment,static_cast<VkDeviceSize>(getpagesize())});
    if(!power2(alignment)||alignment>CAP) return unsupported("combined_alignment_outside_bound");
    VkDeviceSize size=rounded(req.memoryRequirements.size,alignment);
    if(size>CAP||size<BYTES) return unsupported("allocation_outside_16MiB_bound");
    if(posix_memalign(&s.host,static_cast<size_t>(alignment),static_cast<size_t>(size))) return unsupported("host_allocation_failed");
    std::memset(s.host,0xcd,static_cast<size_t>(size));
    VkMemoryHostPointerPropertiesEXT hp{VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT};
    VkResult result=pointerProps(s.device,VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT,s.host,&hp);
    std::printf("V0 host_pointer_query vkResult=%d pointer=%p allocation=%llu align=%llu hostBits=0x%x bufferBits=0x%x\n",
        result,s.host,static_cast<unsigned long long>(size),static_cast<unsigned long long>(alignment),hp.memoryTypeBits,req.memoryRequirements.memoryTypeBits);
    if(result==VK_ERROR_INVALID_EXTERNAL_HANDLE) return unsupported("host_pointer_platform_rejected");
    check(result,"vkGetMemoryHostPointerPropertiesEXT");
    VkPhysicalDeviceMemoryProperties mp{}; vkGetPhysicalDeviceMemoryProperties(s.physical,&mp);
    uint32_t type=UINT32_MAX; bool coherent=false;
    for(int preference=0;preference<2&&type==UINT32_MAX;preference++) for(uint32_t i=0;i<mp.memoryTypeCount;i++) {
        auto f=mp.memoryTypes[i].propertyFlags;
        if((hp.memoryTypeBits&req.memoryRequirements.memoryTypeBits&(1u<<i))&&(f&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)&&!(f&VK_MEMORY_PROPERTY_PROTECTED_BIT)
            &&(preference|| (f&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT))) { type=i; coherent=(f&VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)!=0; break; }
    }
    if(type==UINT32_MAX) return unsupported("no_intersecting_host_visible_type");
    VkImportMemoryHostPointerInfoEXT import{VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT};
    import.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT; import.pHostPointer=s.host;
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.pNext=&import; alloc.allocationSize=size; alloc.memoryTypeIndex=type;
    result=vkAllocateMemory(s.device,&alloc,nullptr,&s.memory);
    std::printf("V0 import vkResult=%d type=%u flags=0x%x dedicated=%d\n",result,type,mp.memoryTypes[type].propertyFlags,import.pNext!=nullptr);
    if(result==VK_ERROR_INVALID_EXTERNAL_HANDLE) return unsupported("host_import_platform_rejected");
    check(result,"vkAllocateMemory(host import)"); VK(vkBindBufferMemory(s.device,s.buffer,s.memory,0));
    VK(vkMapMemory(s.device,s.memory,0,VK_WHOLE_SIZE,0,&s.mapped));
    std::printf("V0 mapped pointer=%p sameCpuAddress=%d coherent=%d gpuAddressEquality=NOT_TESTED\n",s.mapped,s.host==s.mapped,coherent);
    // For non-coherent aliases, Vulkan cache operations cover the Vulkan mapping. Do not
    // assume they also flush an arbitrary different CPU alias used as the game pointer.
    if(!coherent&&s.host!=s.mapped) return unsupported("noncoherent_distinct_alias_cache_contract_unproven");

    VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; sm.codeSize=sizeof(transform_spv); sm.pCode=transform_spv;
    VK(vkCreateShaderModule(s.device,&sm,nullptr,&s.shader));
    VkDescriptorSetLayoutBinding binding{}; binding.binding=0; binding.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    binding.descriptorCount=1; binding.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT;
    VkDescriptorSetLayoutCreateInfo sl{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; sl.bindingCount=1; sl.pBindings=&binding;
    VK(vkCreateDescriptorSetLayout(s.device,&sl,nullptr,&s.setLayout));
    VkPipelineLayoutCreateInfo pl{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; pl.setLayoutCount=1; pl.pSetLayouts=&s.setLayout;
    VK(vkCreatePipelineLayout(s.device,&pl,nullptr,&s.pipelineLayout));
    VkComputePipelineCreateInfo pc{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO}; pc.layout=s.pipelineLayout;
    pc.stage.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO; pc.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;
    pc.stage.module=s.shader; pc.stage.pName="main";
    VK(vkCreateComputePipelines(s.device,VK_NULL_HANDLE,1,&pc,nullptr,&s.pipeline));
    VkDescriptorPoolSize ps{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,1};
    VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; dp.maxSets=1; dp.poolSizeCount=1; dp.pPoolSizes=&ps;
    VK(vkCreateDescriptorPool(s.device,&dp,nullptr,&s.descriptorPool));
    VkDescriptorSetAllocateInfo da{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; da.descriptorPool=s.descriptorPool; da.descriptorSetCount=1; da.pSetLayouts=&s.setLayout;
    VkDescriptorSet set{}; VK(vkAllocateDescriptorSets(s.device,&da,&set));
    VkDescriptorBufferInfo bi{s.buffer,0,BYTES}; VkWriteDescriptorSet wd{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET};
    wd.dstSet=set; wd.descriptorCount=1; wd.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; wd.pBufferInfo=&bi;
    vkUpdateDescriptorSets(s.device,1,&wd,0,nullptr);
    VkCommandPoolCreateInfo cp{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; cp.queueFamilyIndex=s.family;
    VK(vkCreateCommandPool(s.device,&cp,nullptr,&s.commandPool));
    VkCommandBufferAllocateInfo ca{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; ca.commandPool=s.commandPool; ca.commandBufferCount=1; ca.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    VkCommandBuffer command{}; VK(vkAllocateCommandBuffers(s.device,&ca,&command));
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; VK(vkBeginCommandBuffer(command,&begin));
    VkBufferMemoryBarrier barrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_HOST_WRITE_BIT;
    barrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT; barrier.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED; barrier.buffer=s.buffer; barrier.size=BYTES;
    vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_HOST_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,0,nullptr,1,&barrier,0,nullptr);
    vkCmdBindPipeline(command,VK_PIPELINE_BIND_POINT_COMPUTE,s.pipeline);
    vkCmdBindDescriptorSets(command,VK_PIPELINE_BIND_POINT_COMPUTE,s.pipelineLayout,0,1,&set,0,nullptr);
    vkCmdDispatch(command,WORDS/64,1,1);
    barrier.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT; barrier.dstAccessMask=VK_ACCESS_HOST_READ_BIT;
    vkCmdPipelineBarrier(command,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,0,nullptr,1,&barrier,0,nullptr);
    VK(vkEndCommandBuffer(command));
    VkFenceCreateInfo fc{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VK(vkCreateFence(s.device,&fc,nullptr,&s.fence));
    VkMappedMemoryRange range{VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE}; range.memory=s.memory; range.size=VK_WHOLE_SIZE;
    auto* data=static_cast<uint32_t*>(s.host);
    for(uint32_t round=0;round<2;round++) {
        uint32_t seed=0x183c5a79u^(round*0x9e3779b9u);
        for(uint32_t i=0;i<WORDS;i++) data[i]=seed^i;
        if(!coherent) VK(vkFlushMappedMemoryRanges(s.device,1,&range));
        VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&command;
        VK(vkQueueSubmit(s.queue,1,&submit,s.fence));
        result=vkWaitForFences(s.device,1,&s.fence,VK_TRUE,5'000'000'000ull);
        if(result==VK_TIMEOUT) { std::printf("V0 result=TIMEOUT step=fence limit=5s\n"); std::fflush(stdout); _exit(124); }
        check(result,"vkWaitForFences");
        if(!coherent) VK(vkInvalidateMappedMemoryRanges(s.device,1,&range));
        uint32_t wrong=0,first=0;
        for(uint32_t i=0;i<WORDS;i++) { uint32_t expected=((seed^i)*1664525u+1013904223u)^i; if(data[i]!=expected) {if(!wrong) first=i; wrong++;} }
        std::printf("V0 round=%u words=%u mismatches=%u firstMismatch=%u originalHostPointerRead=1\n",round,WORDS,wrong,first);
        if(wrong) { std::printf("V0 result=FAIL reason=visibility_or_compute\n"); return 1; }
        VK(vkResetFences(s.device,1,&s.fence));
    }
    std::printf("V0 result=PASS scope=allocated_host_pointer_16KiB_two_rounds stableGamePool=NOT_TESTED numericGpuAddressEquality=NOT_TESTED\n");
    return 0;
}

int main(int argc,char** argv) {
    setvbuf(stdout,nullptr,_IOLBF,0); signal(SIGALRM,watchdog); alarm(45);
    bool native=argc==2&&std::strcmp(argv[1],"--native-metadata")==0;
    if(argc>2||(argc==2&&!native&&std::strcmp(argv[1],"--host")!=0)) { std::puts("usage: v0_probe [--host|--native-metadata]"); return 2; }
    State s;
    VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO}; app.pApplicationName="S2Arm OHOS V0 isolated"; app.apiVersion=VK_API_VERSION_1_1;
    VkInstanceCreateInfo ic{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ic.pApplicationInfo=&app;
    VkResult result=vkCreateInstance(&ic,nullptr,&s.instance); if(result==VK_ERROR_INCOMPATIBLE_DRIVER) return unsupported("Vulkan_1_1_unavailable"); check(result,"vkCreateInstance");
    uint32_t count=0; VK(vkEnumeratePhysicalDevices(s.instance,&count,nullptr));
    if(!count||count>16) return unsupported("physical_device_count_outside_bound");
    VkPhysicalDevice devices[16]{}; VK(vkEnumeratePhysicalDevices(s.instance,&count,devices)); s.physical=devices[0];
    VkPhysicalDeviceProperties p{}; vkGetPhysicalDeviceProperties(s.physical,&p);
    std::printf("V0 device=%s api=%u.%u.%u driver=%u vendor=%u deviceId=%u physicalIndex=0 count=%u\n",p.deviceName,
        VK_VERSION_MAJOR(p.apiVersion),VK_VERSION_MINOR(p.apiVersion),VK_VERSION_PATCH(p.apiVersion),p.driverVersion,p.vendorID,p.deviceID,count);
    if(p.apiVersion<VK_API_VERSION_1_1) return unsupported("physical_device_Vulkan_1_1_unavailable");
    uint32_t ec=0; VK(vkEnumerateDeviceExtensionProperties(s.physical,nullptr,&ec,nullptr));
    if(ec>1024) return unsupported("extension_count_outside_bound");
    VkExtensionProperties extensions[1024]{}; VK(vkEnumerateDeviceExtensionProperties(s.physical,nullptr,&ec,extensions));
    bool hostExt=false,nativeExt=false,foreignExt=false;
    for(uint32_t i=0;i<ec;i++) { const char* n=extensions[i].extensionName;
        hostExt|=std::strcmp(n,VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME)==0;
        nativeExt|=std::strcmp(n,VK_OHOS_EXTERNAL_MEMORY_EXTENSION_NAME)==0;
        foreignExt|=std::strcmp(n,VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME)==0;
    }
    std::printf("V0 extensions external_memory_host=%d OHOS_external_memory=%d queue_family_foreign=%d\n",hostExt,nativeExt,foreignExt);
    if(native?(!nativeExt||!foreignExt):!hostExt) return unsupported(native?"NativeBuffer_extension_dependencies_absent":"external_memory_host_absent");
    uint32_t qc=0; vkGetPhysicalDeviceQueueFamilyProperties(s.physical,&qc,nullptr);
    if(!qc||qc>64) return unsupported("queue_count_outside_bound");
    VkQueueFamilyProperties queues[64]{}; vkGetPhysicalDeviceQueueFamilyProperties(s.physical,&qc,queues);
    s.family=UINT32_MAX; for(uint32_t i=0;i<qc;i++) if(queues[i].queueCount&&(queues[i].queueFlags&VK_QUEUE_COMPUTE_BIT)) {s.family=i;break;}
    if(s.family==UINT32_MAX) return unsupported("compute_queue_absent");
    float priority=1; VkDeviceQueueCreateInfo qi{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qi.queueFamilyIndex=s.family; qi.queueCount=1; qi.pQueuePriorities=&priority;
    const char* requested[]={native?VK_OHOS_EXTERNAL_MEMORY_EXTENSION_NAME:VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME,VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME};
    VkDeviceCreateInfo dc{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dc.queueCreateInfoCount=1; dc.pQueueCreateInfos=&qi;
    dc.enabledExtensionCount=native?2:1; dc.ppEnabledExtensionNames=requested;
    VK(vkCreateDevice(s.physical,&dc,nullptr,&s.device)); vkGetDeviceQueue(s.device,s.family,0,&s.queue);
    return native?native_metadata(s):host_roundtrip(s);
}
