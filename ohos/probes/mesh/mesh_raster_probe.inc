// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Independent pixel oracle: three overlapping triangles, last instance is 2.
// Attribute x=(first9+instance2)+.25, y=instance2. Fragment maps /16 and /4.
static int mesh_raster_probe(VkDevice device, VkPhysicalDevice physical, VkQueue queue,
    VkCommandBuffer cmd, VkFence fence, VkPipelineLayout layout, VkDescriptorSet set,
    VkBuffer control, const char *directory) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(physical, &mp);
    VkImage image; VkDeviceMemory image_memory, read_memory; VkImageView view; VkBuffer read_buffer; uint8_t *pixels;
    VkImageCreateInfo ii={.sType=VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,.imageType=VK_IMAGE_TYPE_2D,.format=VK_FORMAT_R8G8B8A8_UNORM,
        .extent={8,8,1},.mipLevels=1,.arrayLayers=1,.samples=VK_SAMPLE_COUNT_1_BIT,.tiling=VK_IMAGE_TILING_OPTIMAL,
        .usage=VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT,.sharingMode=VK_SHARING_MODE_EXCLUSIVE};
    OK(vkCreateImage(device,&ii,NULL,&image)); VkMemoryRequirements mr; vkGetImageMemoryRequirements(device,image,&mr);
    uint32_t type=0; while(type<mp.memoryTypeCount&&!(mr.memoryTypeBits&(1u<<type))) type++; CHECK(type<mp.memoryTypeCount);
    VkMemoryAllocateInfo ma={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=mr.size,.memoryTypeIndex=type};
    OK(vkAllocateMemory(device,&ma,NULL,&image_memory)); OK(vkBindImageMemory(device,image,image_memory,0));
    VkImageViewCreateInfo vi={.sType=VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,.image=image,.viewType=VK_IMAGE_VIEW_TYPE_2D,
        .format=VK_FORMAT_R8G8B8A8_UNORM,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
    OK(vkCreateImageView(device,&vi,NULL,&view));
    VkBufferCreateInfo bi={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=256,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    OK(vkCreateBuffer(device,&bi,NULL,&read_buffer)); vkGetBufferMemoryRequirements(device,read_buffer,&mr);
    type=0; VkMemoryPropertyFlags flags=VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
    while(type<mp.memoryTypeCount&&(!(mr.memoryTypeBits&(1u<<type))||(mp.memoryTypes[type].propertyFlags&flags)!=flags)) type++; CHECK(type<mp.memoryTypeCount);
    ma.allocationSize=mr.size;ma.memoryTypeIndex=type;
    OK(vkAllocateMemory(device,&ma,NULL,&read_memory));OK(vkBindBufferMemory(device,read_buffer,read_memory,0));
    OK(vkMapMemory(device,read_memory,0,256,0,(void **)&pixels));memset(pixels,0xee,256);
    VkAttachmentDescription attachment={.format=VK_FORMAT_R8G8B8A8_UNORM,.samples=VK_SAMPLE_COUNT_1_BIT,.loadOp=VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp=VK_ATTACHMENT_STORE_OP_STORE,.stencilLoadOp=VK_ATTACHMENT_LOAD_OP_DONT_CARE,.stencilStoreOp=VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout=VK_IMAGE_LAYOUT_UNDEFINED,.finalLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
    VkAttachmentReference reference={0,VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
    VkSubpassDescription sub={.pipelineBindPoint=VK_PIPELINE_BIND_POINT_GRAPHICS,.colorAttachmentCount=1,.pColorAttachments=&reference};
    VkSubpassDependency dep={.srcSubpass=0,.dstSubpass=VK_SUBPASS_EXTERNAL,.srcStageMask=VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask=VK_PIPELINE_STAGE_TRANSFER_BIT,.srcAccessMask=VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT};
    VkRenderPassCreateInfo ri={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,.attachmentCount=1,.pAttachments=&attachment,
        .subpassCount=1,.pSubpasses=&sub,.dependencyCount=1,.pDependencies=&dep};
    VkRenderPass pass;OK(vkCreateRenderPass(device,&ri,NULL,&pass));
    VkFramebufferCreateInfo fbi={.sType=VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,.renderPass=pass,.attachmentCount=1,.pAttachments=&view,.width=8,.height=8,.layers=1};
    VkFramebuffer framebuffer;OK(vkCreateFramebuffer(device,&fbi,NULL,&framebuffer));
    const char *names[2]={"vertex","raster-frag"};VkShaderModule modules[2];VkPipelineShaderStageCreateInfo stages[2];
    for(int i=0;i<2;i++) {
        char path[1024];snprintf(path,sizeof path,"%s/%s.spv",directory,names[i]);FILE *f=fopen(path,"rb");CHECK(f);
        CHECK(!fseek(f,0,SEEK_END));long bytes=ftell(f);CHECK(bytes>20&&bytes%4==0);rewind(f);
        uint32_t *words=malloc((size_t)bytes);CHECK(words&&fread(words,1,(size_t)bytes,f)==(size_t)bytes);fclose(f);
        VkShaderModuleCreateInfo mi={.sType=VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,.codeSize=(size_t)bytes,.pCode=words};
        OK(vkCreateShaderModule(device,&mi,NULL,&modules[i]));free(words);
        stages[i]=(VkPipelineShaderStageCreateInfo){.sType=VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage=i?VK_SHADER_STAGE_FRAGMENT_BIT:VK_SHADER_STAGE_VERTEX_BIT,.module=modules[i],.pName="main"};
    }
    VkPipelineVertexInputStateCreateInfo vin={.sType=VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO};
    VkPipelineInputAssemblyStateCreateInfo ia={.sType=VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,.topology=VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    VkViewport vp={0,0,8,8,0,1};VkRect2D sc={{0,0},{8,8}};
    VkPipelineViewportStateCreateInfo viewport={.sType=VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,.viewportCount=1,.pViewports=&vp,.scissorCount=1,.pScissors=&sc};
    VkPipelineRasterizationStateCreateInfo raster={.sType=VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,.polygonMode=VK_POLYGON_MODE_FILL,.cullMode=VK_CULL_MODE_NONE,.lineWidth=1};
    VkPipelineMultisampleStateCreateInfo samples={.sType=VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,.rasterizationSamples=VK_SAMPLE_COUNT_1_BIT};
    VkPipelineColorBlendAttachmentState blend={.colorWriteMask=15};VkPipelineColorBlendStateCreateInfo cb={.sType=VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,.attachmentCount=1,.pAttachments=&blend};
    VkGraphicsPipelineCreateInfo pi={.sType=VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,.stageCount=2,.pStages=stages,
        .pVertexInputState=&vin,.pInputAssemblyState=&ia,.pViewportState=&viewport,.pRasterizationState=&raster,.pMultisampleState=&samples,
        .pColorBlendState=&cb,.layout=layout,.renderPass=pass};
    VkPipeline pipeline;OK(vkCreateGraphicsPipelines(device,VK_NULL_HANDLE,1,&pi,NULL,&pipeline));
    OK(vkResetCommandBuffer(cmd,0));VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};OK(vkBeginCommandBuffer(cmd,&begin));
    barrier(cmd,VK_PIPELINE_STAGE_VERTEX_SHADER_BIT|VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_INDIRECT_COMMAND_READ_BIT);
    VkClearValue clear={.color={{0,0,0,1}}};VkRenderPassBeginInfo rb={.sType=VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,.renderPass=pass,.framebuffer=framebuffer,
        .renderArea={{0,0},{8,8}},.clearValueCount=1,.pClearValues=&clear};
    vkCmdBeginRenderPass(cmd,&rb,VK_SUBPASS_CONTENTS_INLINE);vkCmdBindPipeline(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,pipeline);
    vkCmdBindDescriptorSets(cmd,VK_PIPELINE_BIND_POINT_GRAPHICS,layout,1,1,&set,0,NULL);vkCmdDrawIndirect(cmd,control,32,1,16);vkCmdEndRenderPass(cmd);
    VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={8,8,1}};
    vkCmdCopyImageToBuffer(cmd,image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,read_buffer,1,&copy);
    VkMemoryBarrier host={.sType=VK_STRUCTURE_TYPE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT,.dstAccessMask=VK_ACCESS_HOST_READ_BIT};
    vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_HOST_BIT,0,1,&host,0,NULL,0,NULL);OK(vkEndCommandBuffer(cmd));
    OK(vkResetFences(device,1,&fence));VkSubmitInfo si={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};
    OK(vkQueueSubmit(queue,1,&si,fence));OK(vkWaitForFences(device,1,&fence,VK_TRUE,5000000000ull));
    uint8_t *p=pixels+4*(5+5*8);fprintf(mesh_probe_log?mesh_probe_log:stdout,"raster center=%u,%u,%u,%u expected=179,128,64,255\n",p[0],p[1],p[2],p[3]);
    CHECK(abs((int)p[0]-179)<=1&&abs((int)p[1]-128)<=1&&abs((int)p[2]-64)<=1&&p[3]==255);
    CHECK(pixels[4*(1+1*8)]==0&&pixels[4*(7+7*8)]==0);
    vkDestroyPipeline(device,pipeline,NULL);for(int i=0;i<2;i++)vkDestroyShaderModule(device,modules[i],NULL);
    vkDestroyFramebuffer(device,framebuffer,NULL);vkDestroyRenderPass(device,pass,NULL);vkDestroyImageView(device,view,NULL);
    vkDestroyImage(device,image,NULL);vkFreeMemory(device,image_memory,NULL);vkUnmapMemory(device,read_memory);
    vkDestroyBuffer(device,read_buffer,NULL);vkFreeMemory(device,read_memory,NULL);
    fprintf(mesh_probe_log?mesh_probe_log:stdout,"PASS vertex pulling raster (3 indirect instances, attributes and clipped unused triangles)\n");return 0;
}
