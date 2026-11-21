// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Original, asset-free GPU contract test for DirectMeshSpirv and its GLSL fixtures.
// This is not game acceptance. Run after spirv-val, on an exclusively locked device.
#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static FILE *mesh_probe_log;
#define OK(call) do { VkResult r=(call); if(r!=VK_SUCCESS) { fprintf(mesh_probe_log ? mesh_probe_log : stderr,"FAIL line %d VkResult=%d\n",__LINE__,r); return 1; } } while(0)
#define CHECK(x) do { if(!(x)) { fprintf(mesh_probe_log ? mesh_probe_log : stderr,"FAIL line %d: %s\n",__LINE__,#x); return 1; } } while(0)
static uint32_t bits(float x) { uint32_t u; memcpy(&u,&x,4); return u; }
static void barrier(VkCommandBuffer cmd, VkPipelineStageFlags dst, VkAccessFlags access) {
    VkMemoryBarrier b={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT,.dstAccessMask=access};
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,dst,0,1,&b,0,NULL,0,NULL);
}
#include "mesh_raster_probe.inc"

int main(int argc,char **argv) {
    CHECK(argc>=2);
    int negative=argc>2&&!strcmp(argv[2],"--negative-first");
    VkApplicationInfo app={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="S2Arm mesh contract",.apiVersion=VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.pApplicationInfo=&app};
    VkInstance instance; OK(vkCreateInstance(&ici,NULL,&instance));
    uint32_t n=0; OK(vkEnumeratePhysicalDevices(instance,&n,NULL)); CHECK(n>0);
    VkPhysicalDevice physical[8]; n=n>8?8:n; OK(vkEnumeratePhysicalDevices(instance,&n,physical));
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(physical[0],&props); fprintf(mesh_probe_log ? mesh_probe_log : stdout,"device=%s\n",props.deviceName);
    uint32_t nf=0; vkGetPhysicalDeviceQueueFamilyProperties(physical[0],&nf,NULL); CHECK(nf<=32);
    VkQueueFamilyProperties family[32]; vkGetPhysicalDeviceQueueFamilyProperties(physical[0],&nf,family);
    uint32_t q=0; while(q<nf&&(family[q].queueFlags&(VK_QUEUE_COMPUTE_BIT|VK_QUEUE_GRAPHICS_BIT))!=(VK_QUEUE_COMPUTE_BIT|VK_QUEUE_GRAPHICS_BIT)) q++; CHECK(q<nf);
    float priority=1; VkDeviceQueueCreateInfo qi={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=q,.queueCount=1,.pQueuePriorities=&priority};
    VkDeviceCreateInfo di={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&qi};
    VkDevice device; OK(vkCreateDevice(physical[0],&di,NULL,&device)); VkQueue queue; vkGetDeviceQueue(device,q,0,&queue);
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(physical[0],&mp);
    VkBuffer buf[3]; VkDeviceMemory mem[3]; uint32_t *map[3]; VkDeviceSize sizes[3]={128,4096,65536};
    for(int k=0;k<3;k++) {
        VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=sizes[k],.usage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};
        OK(vkCreateBuffer(device,&bi,NULL,&buf[k])); VkMemoryRequirements mr; vkGetBufferMemoryRequirements(device,buf[k],&mr);
        uint32_t mt=0; VkMemoryPropertyFlags need=VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        while(mt<mp.memoryTypeCount&&(!(mr.memoryTypeBits&(1u<<mt))||(mp.memoryTypes[mt].propertyFlags&need)!=need)) mt++; CHECK(mt<mp.memoryTypeCount);
        VkMemoryAllocateInfo ai={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=mt};
        OK(vkAllocateMemory(device,&ai,NULL,&mem[k])); OK(vkBindBufferMemory(device,buf[k],mem[k],0)); OK(vkMapMemory(device,mem[k],0,sizes[k],0,(void **)&map[k]));
    }
    VkDescriptorSetLayoutBinding bindings[3]; memset(bindings,0,sizeof bindings);
    for(int i=0;i<3;i++) bindings[i]=(VkDescriptorSetLayoutBinding){.binding=(uint32_t)i,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.descriptorCount=1,.stageFlags=VK_SHADER_STAGE_COMPUTE_BIT|VK_SHADER_STAGE_VERTEX_BIT};
    VkDescriptorSetLayout layouts[2]; VkDescriptorSetLayoutCreateInfo li={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
    OK(vkCreateDescriptorSetLayout(device,&li,NULL,&layouts[0])); li.bindingCount=3; li.pBindings=bindings; OK(vkCreateDescriptorSetLayout(device,&li,NULL,&layouts[1]));
    VkPipelineLayoutCreateInfo pli={.sType=VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,.setLayoutCount=2,.pSetLayouts=layouts};
    VkPipelineLayout layout; OK(vkCreatePipelineLayout(device,&pli,NULL,&layout));
    VkDescriptorPoolSize ps={VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,3};
    VkDescriptorPoolCreateInfo pci={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,.maxSets=1,.poolSizeCount=1,.pPoolSizes=&ps};
    VkDescriptorPool dp; OK(vkCreateDescriptorPool(device,&pci,NULL,&dp));
    VkDescriptorSetAllocateInfo dai={.sType=VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,.descriptorPool=dp,.descriptorSetCount=1,.pSetLayouts=&layouts[1]};
    VkDescriptorSet set; OK(vkAllocateDescriptorSets(device,&dai,&set));
    VkDescriptorBufferInfo bis[3]; VkWriteDescriptorSet writes[3];
    for(int i=0;i<3;i++) {
        bis[i]=(VkDescriptorBufferInfo){buf[i],0,sizes[i]};
        writes[i]=(VkWriteDescriptorSet){.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,.dstSet=set,.dstBinding=(uint32_t)i,.descriptorCount=1,.descriptorType=VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,.pBufferInfo=&bis[i]};
    }
    vkUpdateDescriptorSets(device,3,writes,0,NULL);
    const char *names[]={"prepare-task","task","mesh","prepare-mesh","plain"}; VkPipeline pipelines[5];
    for(int i=0;i<5;i++) {
        char path[1024]; snprintf(path,sizeof path,"%s/%s.spv",argv[1],names[i]); FILE *f=fopen(path,"rb"); CHECK(f);
        CHECK(!fseek(f,0,SEEK_END)); long bytes=ftell(f); CHECK(bytes>20&&bytes%4==0); rewind(f);
        uint32_t *words=malloc((size_t)bytes); CHECK(words&&fread(words,1,(size_t)bytes,f)==(size_t)bytes); fclose(f);
        VkShaderModuleCreateInfo mi={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=(size_t)bytes,.pCode=words};
        VkShaderModule module; OK(vkCreateShaderModule(device,&mi,NULL,&module)); free(words);
        VkComputePipelineCreateInfo pi={.sType=VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,.layout=layout,
            .stage={.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,.stage=VK_SHADER_STAGE_COMPUTE_BIT,.module=module,.pName="main"}};
        OK(vkCreateComputePipelines(device,VK_NULL_HANDLE,1,&pi,NULL,&pipelines[i])); vkDestroyShaderModule(device,module,NULL);
    }
    VkCommandPoolCreateInfo cpi={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,.queueFamilyIndex=q};
    VkCommandPool pool; OK(vkCreateCommandPool(device,&cpi,NULL,&pool));
    VkCommandBufferAllocateInfo cai={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
    VkCommandBuffer cmd; OK(vkAllocateCommandBuffers(device,&cai,&cmd));
    VkFenceCreateInfo fi={.sType=VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence fence; OK(vkCreateFence(device,&fi,NULL,&fence));
    unsigned checked=0;
    for(int test=0;test<4;test++) {
        int task=test!=1; uint32_t first=task?7:9, count=test==2?5:3, cap=test==3?5:8;
        for(int i=0;i<3;i++) memset(map[i],0,(size_t)sizes[i]);
        uint32_t *ctl=map[0],*payload=map[1],*out=map[2]; ctl[8]=378; ctl[12]=cap; ctl[13]=4; ctl[14]=256; ctl[24]=count; ctl[25]=negative?0:first;
        OK(vkResetCommandBuffer(cmd,0)); VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; OK(vkBeginCommandBuffer(cmd,&begin));
        vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,layout,1,1,&set,0,NULL);
        vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipelines[task?0:3]); vkCmdDispatch(cmd,1,1,1);
        barrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
        if(task) {
            vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipelines[1]); vkCmdDispatchIndirect(cmd,buf[0],16);
            barrier(cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT|VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT|VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
        }
        vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipelines[task?2:4]); vkCmdDispatchIndirect(cmd,buf[0],0);
        barrier(cmd,VK_PIPELINE_STAGE_HOST_BIT,VK_ACCESS_HOST_READ_BIT); OK(vkEndCommandBuffer(cmd));
        OK(vkResetFences(device,1,&fence)); VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};
        OK(vkQueueSubmit(queue,1,&si,fence)); OK(vkWaitForFences(device,1,&fence,VK_TRUE,5000000000ull));
        uint32_t expected=test==0?6:test==1?3:test==2?0:4;
        CHECK(ctl[0]==expected&&ctl[9]==expected&&ctl[15]==(uint32_t)(test>=2)); checked+=3;
        for(uint32_t group=0;group<expected;group++) {
            uint32_t parent=task?payload[256+group*2]:0, local=task?payload[257+group*2]:group;
            CHECK(!task||(parent<3&&local<2));
            uint32_t *words=out+group*1188;
            CHECK(words[0]==(task?local:first+group)); CHECK(words[1092]==(1u<<24)); CHECK(words[1093]==0x00020100u); checked+=4;
            for(uint32_t v=0;v<3;v++) {
                CHECK(words[68+v]==bits(v==1?1.0f:0.0f)); CHECK(words[100+v]==bits(v==2?1.0f:0.0f));
                CHECK(words[164+v]==bits(1.0f));
                CHECK(words[196+v]==bits((float)(task?first+parent+100+local:first+group)+0.25f));
                CHECK(words[228+v]==bits((float)local)); checked+=5;
            }
        }
        fprintf(mesh_probe_log ? mesh_probe_log : stdout,"case=%d groups=%u overflow=%u checked=%u\n",test,ctl[0],ctl[15],checked); fflush(mesh_probe_log ? mesh_probe_log : stdout);
        if(test==1) CHECK(mesh_raster_probe(device,physical[0],queue,cmd,fence,layout,set,buf[0],argv[1])==0);
    }
    fprintf(mesh_probe_log ? mesh_probe_log : stdout,"PASS mesh GPU contract %u checks (no game or raster acceptance)\n",checked);
    vkDestroyFence(device,fence,NULL); vkDestroyCommandPool(device,pool,NULL);
    for(int i=0;i<5;i++) vkDestroyPipeline(device,pipelines[i],NULL);
    vkDestroyDescriptorPool(device,dp,NULL); vkDestroyPipelineLayout(device,layout,NULL);
    for(int i=0;i<2;i++) vkDestroyDescriptorSetLayout(device,layouts[i],NULL);
    for(int i=0;i<3;i++) { vkUnmapMemory(device,mem[i]); vkDestroyBuffer(device,buf[i],NULL); vkFreeMemory(device,mem[i],NULL); }
    vkDestroyDevice(device,NULL); vkDestroyInstance(instance,NULL); return 0;
}
