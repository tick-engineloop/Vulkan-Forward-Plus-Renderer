#!/bin/bash

glslangValidator -V forwardplus.vert -o ../../content/forwardplus_vert.spv
glslangValidator -V forwardplus.frag -o ../../content/forwardplus_frag.spv
glslangValidator -V light_culling.comp.glsl -o ../../content/light_culling_comp.spv -S comp
glslangValidator -V depth.vert -o ../../content/depth_vert.spv
