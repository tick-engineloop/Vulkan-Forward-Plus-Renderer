#version 450
#extension GL_ARB_separate_shader_objects : enable

// TODO: it should be better done in view space
// TODO: 3d position based clustered shading

const int TILE_SIZE = 16;

struct PointLight {
	vec3 pos;
	float radius;
	vec3 intensity;
};

#define MAX_POINT_LIGHT_PER_TILE 1023
struct LightVisiblity
{
	uint count;
	uint lightindices[MAX_POINT_LIGHT_PER_TILE];
};

layout(push_constant) uniform PushConstantObject
{
	ivec2 viewport_size;
	ivec2 tile_nums;
} push_constants;

layout(std430, set = 0, binding = 0) buffer writeonly TileLightVisiblities
{
    LightVisiblity light_visiblities[];
};

layout(std140, set = 0, binding = 1) buffer readonly PointLights // FIXME: change back to uniform
{
	int light_num;
	PointLight pointlights[1000];
};

layout(std140, set = 1, binding = 0) buffer readonly CameraUbo // FIXME: change back to uniform
{
    mat4 view;
    mat4 proj;
    mat4 projview;
    vec3 cam_pos;
} camera;

layout(set = 2, binding = 0) uniform sampler2D depth_sampler;

// vulkan ndc, minDepth = 0.0, maxDepth = 1.0
const vec2 ndc_upper_left = vec2(-1.0, -1.0);
const float ndc_near_plane = 0.0;
const float ndc_far_plane = 1.0;

struct ViewFrustum
{
	vec4 planes[6];	// frustum plane array
	vec3 points[8]; // frustum vertex array, 0-3 near 4-7 far
};

layout(local_size_x = 32) in;

shared ViewFrustum frustum;
shared uint light_count_for_tile;
shared float min_depth;
shared float max_depth;

// Construct view frustum
ViewFrustum createFrustum(ivec2 tile_id)
{

	mat4 inv_projview = inverse(camera.projview);

	vec2 ndc_size_per_tile = 2.0 * vec2(TILE_SIZE, TILE_SIZE) / push_constants.viewport_size;

	vec2 ndc_pts[4];  // corners of tile in ndc
	ndc_pts[0] = ndc_upper_left + tile_id * ndc_size_per_tile;  // upper left
	ndc_pts[1] = vec2(ndc_pts[0].x + ndc_size_per_tile.x, ndc_pts[0].y); // upper right
	ndc_pts[2] = ndc_pts[0] + ndc_size_per_tile;
	ndc_pts[3] = vec2(ndc_pts[0].x, ndc_pts[0].y + ndc_size_per_tile.y); // lower left

	ViewFrustum frustum;

	vec4 temp;
	for (int i = 0; i < 4; i++)
	{
		temp = inv_projview * vec4(ndc_pts[i], min_depth, 1.0);
		frustum.points[i] = temp.xyz / temp.w;
		temp = inv_projview * vec4(ndc_pts[i], max_depth, 1.0);
		frustum.points[i + 4] = temp.xyz / temp.w;
	}

	vec3 temp_normal;
	for (int i = 0; i < 4; i++)
	{
		// Cax+Cby+Ccz+Cd = 0, planes[i] = (Ca, Cb, Cc, Cd)
		// 视锥体近平面四边形的两个相邻顶点可以和摄像机位置点形成视锥体的一个平面
		// 可以利用这两个顶点分别和摄像机位置点构成的向量求叉积获得该平面的法向量
		temp_normal = cross(frustum.points[i] - camera.cam_pos, frustum.points[i + 1] - camera.cam_pos);
		// 对求得的法向量归一化后得到平面方程中的 Ca, Cb, Cc
		temp_normal = normalize(temp_normal);
		// 由点法式平面方程的公式可知，Cd 可以通过法向量和平面中一点的点积求得
		frustum.planes[i] = vec4(temp_normal, - dot(temp_normal, frustum.points[i]));
	}
	// near plane
	{
		temp_normal = cross(frustum.points[1] - frustum.points[0], frustum.points[3] - frustum.points[0]);
		temp_normal = normalize(temp_normal);
		frustum.planes[4] = vec4(temp_normal, - dot(temp_normal, frustum.points[0]));
	}
	// far plane
	{
		temp_normal = cross(frustum.points[7] - frustum.points[4], frustum.points[5] - frustum.points[4]);
		temp_normal = normalize(temp_normal);
		frustum.planes[5] = vec4(temp_normal, - dot(temp_normal, frustum.points[4]));
	}

	return frustum;
}

bool isCollided(PointLight light, ViewFrustum frustum)
{
	bool result = true;

    // Step1: sphere-plane test
	for (int i = 0; i < 6; i++)
	{
		if (dot(light.pos, frustum.planes[i].xyz) + frustum.planes[i].w  < - light.radius )
		{
			result = false;
			break;
		}
	}

    if (!result)
    {
        return false;
    }

    // Step2: bbox corner test (to reduce false positive)
    vec3 light_bbox_max = light.pos + vec3(light.radius);
    vec3 light_bbox_min = light.pos - vec3(light.radius);
    int probe;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].x > light_bbox_max.x)?1:0); if( probe==8 ) return false;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].x < light_bbox_min.x)?1:0); if( probe==8 ) return false;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].y > light_bbox_max.y)?1:0); if( probe==8 ) return false;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].y < light_bbox_min.y)?1:0); if( probe==8 ) return false;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].z > light_bbox_max.z)?1:0); if( probe==8 ) return false;
    probe=0; for( int i=0; i<8; i++ ) probe += ((frustum.points[i].z < light_bbox_min.z)?1:0); if( probe==8 ) return false;

	return true;
}

void main()
{
	ivec2 tile_id = ivec2(gl_WorkGroupID.xy);
	uint tile_index = tile_id.y * push_constants.tile_nums.x + tile_id.x;

	// TODO: depth culling???

	if (gl_LocalInvocationIndex == 0)
	{
		min_depth = 1.0;
		max_depth = 0.0;

		for (int y = 0; y < TILE_SIZE; y++)
		{
			for (int x = 0; x < TILE_SIZE; x++)
			{
				vec2 sample_loc = (vec2(TILE_SIZE, TILE_SIZE) * tile_id + vec2(x, y) ) / push_constants.viewport_size;
				float pre_depth = texture(depth_sampler, sample_loc).x;
				min_depth = min(min_depth, pre_depth);
				max_depth = max(max_depth, pre_depth); //TODO: parallize this
			}
		}

		if (min_depth >= max_depth)
		{
			min_depth = max_depth;
		}

		frustum = createFrustum(tile_id);
		light_count_for_tile = 0;
	}

	barrier();

	// 每个瓦片对应的子视椎体都要遍历所有光源判断是否在其体内，所以每个工作组都要对所有光源进行剔除计算。
	// 因为工作组被定义为长度为32的一维工作组，所以一个工作组一次同时处理连续的32个光源：
	// 0号工作项调用从光源0开始处理，处理完光源0后，0号工作项调用处理光源32，接着处理光源64，…，直到处理到最大光源数或瓦片允许的最大光源数为止；
	// 1号工作项调用从光源1开始处理，处理完光源1后，1号工作项调用处理光源33，接着处理光源65，…，直到处理到最大光源数或瓦片允许的最大光源数为止；
	// ……
	// 31号工作项调用从光源31开始处理，处理完光源31后，31号工作项调用处理光源63，接着处理光源95，…，直到处理到最大光源数或瓦片允许的最大光源数为止。
	for (uint i = gl_LocalInvocationIndex; i < light_num && light_count_for_tile < MAX_POINT_LIGHT_PER_TILE; i += gl_WorkGroupSize.x)
	{
		if (isCollided(pointlights[i], frustum))
		{
			uint slot = atomicAdd(light_count_for_tile, 1);
			if (slot >= MAX_POINT_LIGHT_PER_TILE) {break;}
			light_visiblities[tile_index].lightindices[slot] = i;
		}
	}

	barrier();

	if (gl_LocalInvocationIndex == 0)
	{
		light_visiblities[tile_index].count = min(MAX_POINT_LIGHT_PER_TILE, light_count_for_tile);
	}
}
