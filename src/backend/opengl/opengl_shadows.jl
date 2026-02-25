# OpenGL shadow mapping implementation

# ---- Type definitions ----

"""
    ShadowMap

Stores OpenGL resources for directional shadow mapping:
depth-only FBO, depth texture, and the depth-pass shader.
"""
mutable struct ShadowMap <: AbstractShadowMap
    fbo::GLuint
    depth_texture::GLuint
    width::Int
    height::Int
    shader::Union{ShaderProgram, Nothing}

    ShadowMap(; width::Int=2048, height::Int=2048) =
        new(GLuint(0), GLuint(0), width, height, nothing)
end

get_width(sm::ShadowMap) = sm.width
get_height(sm::ShadowMap) = sm.height

"""
    CascadedShadowMap

Cascaded shadow mapping with multiple frustum splits for improved shadow quality.
Uses Practical Split Scheme (PSSM) for optimal split distribution.
"""
mutable struct CascadedShadowMap <: AbstractCascadedShadowMap
    num_cascades::Int
    cascade_fbos::Vector{GLuint}
    cascade_textures::Vector{GLuint}
    cascade_matrices::Vector{Mat4f}
    split_distances::Vector{Float32}  # View-space split distances
    resolution::Int
    depth_shader::Union{ShaderProgram, Nothing}

    CascadedShadowMap(; num_cascades::Int = 4, resolution::Int = 2048) =
        new(num_cascades, GLuint[], GLuint[], Mat4f[], Float32[], resolution, nothing)
end

# ---- Depth shader sources ----

const SHADOW_VERTEX_SHADER = """
#version 330 core

layout(location = 0) in vec3 a_Position;
layout(location = 3) in vec4 a_BoneWeights;
layout(location = 4) in uvec4 a_BoneIndices;

#define MAX_BONES 128
uniform mat4 u_BoneMatrices[MAX_BONES];
uniform int u_HasSkinning;

uniform mat4 u_LightSpaceMatrix;
uniform mat4 u_Model;

void main()
{
    vec3 localPos = a_Position;

    if (u_HasSkinning == 1) {
        mat4 skin = u_BoneMatrices[a_BoneIndices.x] * a_BoneWeights.x
                  + u_BoneMatrices[a_BoneIndices.y] * a_BoneWeights.y
                  + u_BoneMatrices[a_BoneIndices.z] * a_BoneWeights.z
                  + u_BoneMatrices[a_BoneIndices.w] * a_BoneWeights.w;
        localPos = (skin * vec4(a_Position, 1.0)).xyz;
    }

    gl_Position = u_LightSpaceMatrix * u_Model * vec4(localPos, 1.0);
}
"""

const SHADOW_FRAGMENT_SHADER = """
#version 330 core

void main()
{
    // Depth is written automatically
}
"""

# ---- ShadowMap: Create / Destroy ----

"""
    create_shadow_map!(sm::ShadowMap)

Allocate the depth FBO, depth texture, and compile the depth shader.
"""
function create_shadow_map!(sm::ShadowMap)
    # Create depth texture
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    sm.depth_texture = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, sm.depth_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24,
                 sm.width, sm.height, 0, GL_DEPTH_COMPONENT, GL_FLOAT, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)
    border_color = Float32[1.0, 1.0, 1.0, 1.0]
    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color)

    # Create FBO
    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    sm.fbo = fbo_ref[]
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, sm.depth_texture, 0)
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    # Compile depth shader
    sm.shader = create_shader_program(SHADOW_VERTEX_SHADER, SHADOW_FRAGMENT_SHADER)

    return nothing
end

"""
    destroy_shadow_map!(sm::ShadowMap)

Clean up shadow map GPU resources.
"""
function destroy_shadow_map!(sm::ShadowMap)
    if sm.fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(sm.fbo))
        sm.fbo = GLuint(0)
    end
    if sm.depth_texture != GLuint(0)
        glDeleteTextures(1, Ref(sm.depth_texture))
        sm.depth_texture = GLuint(0)
    end
    if sm.shader !== nothing
        destroy_shader_program!(sm.shader)
        sm.shader = nothing
    end
    return nothing
end

# ---- ShadowMap: Shadow render pass ----

"""
    render_shadow_pass!(sm::ShadowMap, light_space::Mat4f, gpu_cache::GPUResourceCache)

Render all mesh entities into the shadow depth buffer.
"""
function render_shadow_pass!(sm::ShadowMap, light_space::Mat4f, gpu_cache::GPUResourceCache)
    sm.shader === nothing && return nothing

    # Save current viewport
    viewport = Int32[0, 0, 0, 0]
    glGetIntegerv(GL_VIEWPORT, viewport)

    glViewport(0, 0, sm.width, sm.height)
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glClear(GL_DEPTH_BUFFER_BIT)

    # Disable face culling for shadow pass to avoid peter-panning
    glDisable(GL_CULL_FACE)

    sp = sm.shader
    glUseProgram(sp.id)
    set_uniform!(sp, "u_LightSpaceMatrix", light_space)

    iterate_components(MeshComponent) do entity_id, mesh
        isempty(mesh.indices) && return

        world_transform = get_world_transform(entity_id)
        model = Mat4f(world_transform)
        set_uniform!(sp, "u_Model", model)

        gpu_mesh = get_or_upload_mesh!(gpu_cache, entity_id, mesh)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
        glBindVertexArray(GLuint(0))
    end

    # Restore
    glEnable(GL_CULL_FACE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))
    glViewport(viewport[1], viewport[2], viewport[3], viewport[4])

    return nothing
end

# ---- CascadedShadowMap: Create / Destroy ----

"""
    create_csm!(csm::CascadedShadowMap, near::Float32, far::Float32)

Create GPU resources for cascaded shadow maps.
"""
function create_csm!(csm::CascadedShadowMap, near::Float32, far::Float32)
    # Compute split distances
    csm.split_distances = compute_cascade_splits(near, far, csm.num_cascades)

    @info "Creating CSM" cascades=csm.num_cascades resolution=csm.resolution splits=csm.split_distances

    # Create framebuffers and textures for each cascade
    resize!(csm.cascade_fbos, csm.num_cascades)
    resize!(csm.cascade_textures, csm.num_cascades)
    resize!(csm.cascade_matrices, csm.num_cascades)

    for i in 1:csm.num_cascades
        # Create framebuffer
        fbo_ref = Ref(GLuint(0))
        glGenFramebuffers(1, fbo_ref)
        csm.cascade_fbos[i] = fbo_ref[]

        # Create depth texture
        tex_ref = Ref(GLuint(0))
        glGenTextures(1, tex_ref)
        csm.cascade_textures[i] = tex_ref[]

        glBindTexture(GL_TEXTURE_2D, csm.cascade_textures[i])
        glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24, csm.resolution, csm.resolution,
                     0, GL_DEPTH_COMPONENT, GL_FLOAT, C_NULL)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)

        # Border color white (1.0) so samples outside shadow map are fully lit
        border_color = Float32[1.0, 1.0, 1.0, 1.0]
        glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color)

        # Attach to framebuffer
        glBindFramebuffer(GL_FRAMEBUFFER, csm.cascade_fbos[i])
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D,
                               csm.cascade_textures[i], 0)
        glDrawBuffer(GL_NONE)
        glReadBuffer(GL_NONE)

        # Verify completeness
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER)
        if status != GL_FRAMEBUFFER_COMPLETE
            error("CSM framebuffer $i incomplete! Status: $status")
        end

        # Initialize matrix
        csm.cascade_matrices[i] = Mat4f(I)
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    # Create depth-only shader (reuse from shadow_map.jl if available)
    # For now, we'll assume it's created elsewhere

    return nothing
end

"""
    destroy_csm!(csm::CascadedShadowMap)

Release GPU resources for cascaded shadow maps.
"""
function destroy_csm!(csm::CascadedShadowMap)
    for i in 1:csm.num_cascades
        if i <= length(csm.cascade_fbos) && csm.cascade_fbos[i] != GLuint(0)
            glDeleteFramebuffers(1, Ref(csm.cascade_fbos[i]))
        end
        if i <= length(csm.cascade_textures) && csm.cascade_textures[i] != GLuint(0)
            glDeleteTextures(1, Ref(csm.cascade_textures[i]))
        end
    end

    empty!(csm.cascade_fbos)
    empty!(csm.cascade_textures)
    empty!(csm.cascade_matrices)
    empty!(csm.split_distances)

    if csm.depth_shader !== nothing
        destroy_shader_program!(csm.depth_shader)
        csm.depth_shader = nothing
    end

    return nothing
end

# ---- CascadedShadowMap: Render cascade ----

"""
    render_csm_cascade!(csm::CascadedShadowMap, cascade_idx::Int, entities,
                        view::Mat4f, proj::Mat4f, light_dir::Vec3f, gpu_cache, depth_shader)

Render a single cascade of the CSM.
"""
function render_csm_cascade!(csm::CascadedShadowMap, cascade_idx::Int, entities,
                            view::Mat4f, proj::Mat4f, light_dir::Vec3f,
                            gpu_cache, depth_shader)
    # Compute light space matrix for this cascade
    near = csm.split_distances[cascade_idx]
    far = csm.split_distances[cascade_idx + 1]

    light_matrix = compute_cascade_light_matrix(view, proj, near, far, light_dir)
    csm.cascade_matrices[cascade_idx] = light_matrix

    # Bind framebuffer
    glBindFramebuffer(GL_FRAMEBUFFER, csm.cascade_fbos[cascade_idx])
    glViewport(0, 0, csm.resolution, csm.resolution)
    glClear(GL_DEPTH_BUFFER_BIT)

    # Render depth only
    glUseProgram(depth_shader.id)
    set_uniform!(depth_shader, "u_LightSpaceMatrix", light_matrix)

    # TODO: Frustum culling per cascade
    # For now, render all entities
    for (entity_id, mesh, model, _) in entities
        set_uniform!(depth_shader, "u_Model", model)

        gpu_mesh = get_or_upload_mesh!(gpu_cache, entity_id, mesh)
        glBindVertexArray(gpu_mesh.vao)
        glDrawElements(GL_TRIANGLES, gpu_mesh.index_count, GL_UNSIGNED_INT, C_NULL)
        glBindVertexArray(GLuint(0))
    end

    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    return nothing
end

# =============================================================================
# Spot Light Shadow Map
# =============================================================================

"""
    SpotLightShadowMap

Single-face depth map for spot light shadows, using a perspective projection
with the spot light's outer cone angle as the FOV.
"""
mutable struct SpotLightShadowMap
    fbo::GLuint
    depth_texture::GLuint
    resolution::Int
    light_matrix::Mat4f  # View-projection from the spot light's perspective

    SpotLightShadowMap(; resolution::Int = 1024) =
        new(GLuint(0), GLuint(0), resolution, Mat4f(I))
end

function create_spot_shadow_map!(sm::SpotLightShadowMap)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    sm.depth_texture = tex_ref[]
    glBindTexture(GL_TEXTURE_2D, sm.depth_texture)
    glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT24,
                 sm.resolution, sm.resolution, 0, GL_DEPTH_COMPONENT, GL_FLOAT, C_NULL)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_BORDER)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_BORDER)
    border_color = Float32[1.0, 1.0, 1.0, 1.0]
    glTexParameterfv(GL_TEXTURE_2D, GL_TEXTURE_BORDER_COLOR, border_color)

    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    sm.fbo = fbo_ref[]
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_TEXTURE_2D, sm.depth_texture, 0)
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    return nothing
end

function destroy_spot_shadow_map!(sm::SpotLightShadowMap)
    if sm.fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(sm.fbo))
        sm.fbo = GLuint(0)
    end
    if sm.depth_texture != GLuint(0)
        glDeleteTextures(1, Ref(sm.depth_texture))
        sm.depth_texture = GLuint(0)
    end
    return nothing
end

"""
    compute_spot_light_matrix(position, direction, outer_cone, range) -> Mat4f

Compute the view-projection matrix for a spot light shadow map.
"""
function compute_spot_light_matrix(position::Vec3f, direction::Vec3f, outer_cone::Float32, range::Float32)
    # View matrix: look from light position along its direction
    target = Vec3f(position[1] + direction[1], position[2] + direction[2], position[3] + direction[3])

    # Choose an up vector that isn't parallel to direction
    up = abs(direction[2]) < 0.99f0 ? Vec3f(0, 1, 0) : Vec3f(1, 0, 0)

    forward = normalize(direction)
    right = normalize(cross(forward, up))
    actual_up = cross(right, forward)

    # Manual lookat matrix
    view_mat = Mat4f(
        right[1], actual_up[1], -forward[1], 0,
        right[2], actual_up[2], -forward[2], 0,
        right[3], actual_up[3], -forward[3], 0,
        -dot(right, position), -dot(actual_up, position), dot(forward, position), 1
    )

    # Perspective projection with cone angle as FOV
    fov = 2.0f0 * outer_cone  # Full cone angle
    fov = min(fov, Float32(π * 0.95))  # Clamp to avoid degenerate projection
    aspect = 1.0f0
    near = 0.1f0
    far = range

    f = 1.0f0 / tan(fov * 0.5f0)
    proj_mat = Mat4f(
        f/aspect, 0,  0,                            0,
        0,        f,  0,                            0,
        0,        0,  (far+near)/(near-far),       -1,
        0,        0,  (2*far*near)/(near-far),      0
    )

    return proj_mat * view_mat
end

# =============================================================================
# Point Light Shadow Map (Cubemap)
# =============================================================================

"""
    PointLightShadowMap

Cubemap depth map for omnidirectional point light shadows.
Renders 6 faces per shadow-casting point light.
"""
mutable struct PointLightShadowMap
    fbo::GLuint
    depth_cubemap::GLuint
    resolution::Int
    light_matrices::Vector{Mat4f}  # 6 face view-projection matrices

    PointLightShadowMap(; resolution::Int = 512) =
        new(GLuint(0), GLuint(0), resolution, Mat4f[])
end

function create_point_shadow_map!(sm::PointLightShadowMap)
    tex_ref = Ref(GLuint(0))
    glGenTextures(1, tex_ref)
    sm.depth_cubemap = tex_ref[]
    glBindTexture(GL_TEXTURE_CUBE_MAP, sm.depth_cubemap)

    for face in 0:5
        glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + UInt32(face), 0, GL_DEPTH_COMPONENT24,
                     sm.resolution, sm.resolution, 0, GL_DEPTH_COMPONENT, GL_FLOAT, C_NULL)
    end

    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_CUBE_MAP, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE)

    fbo_ref = Ref(GLuint(0))
    glGenFramebuffers(1, fbo_ref)
    sm.fbo = fbo_ref[]

    # FBO will bind individual faces during rendering
    glBindFramebuffer(GL_FRAMEBUFFER, sm.fbo)
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT,
                           GL_TEXTURE_CUBE_MAP_POSITIVE_X, sm.depth_cubemap, 0)
    glDrawBuffer(GL_NONE)
    glReadBuffer(GL_NONE)
    glBindFramebuffer(GL_FRAMEBUFFER, GLuint(0))

    return nothing
end

function destroy_point_shadow_map!(sm::PointLightShadowMap)
    if sm.fbo != GLuint(0)
        glDeleteFramebuffers(1, Ref(sm.fbo))
        sm.fbo = GLuint(0)
    end
    if sm.depth_cubemap != GLuint(0)
        glDeleteTextures(1, Ref(sm.depth_cubemap))
        sm.depth_cubemap = GLuint(0)
    end
    return nothing
end

"""
    compute_point_light_matrices(position, range) -> Vector{Mat4f}

Compute 6 view-projection matrices for cubemap shadow rendering.
Order: +X, -X, +Y, -Y, +Z, -Z
"""
function compute_point_light_matrices(position::Vec3f, range::Float32)
    near = 0.1f0
    far = range

    # 90° FOV perspective projection (cubemap face)
    f = 1.0f0  # tan(π/4) = 1
    proj = Mat4f(
        f, 0,  0,                            0,
        0, f,  0,                            0,
        0, 0,  (far+near)/(near-far),       -1,
        0, 0,  (2*far*near)/(near-far),      0
    )

    # 6 cubemap face directions (target, up)
    directions = [
        (Vec3f( 1,  0,  0), Vec3f(0, -1,  0)),  # +X
        (Vec3f(-1,  0,  0), Vec3f(0, -1,  0)),  # -X
        (Vec3f( 0,  1,  0), Vec3f(0,  0,  1)),  # +Y
        (Vec3f( 0, -1,  0), Vec3f(0,  0, -1)),  # -Y
        (Vec3f( 0,  0,  1), Vec3f(0, -1,  0)),  # +Z
        (Vec3f( 0,  0, -1), Vec3f(0, -1,  0)),  # -Z
    ]

    matrices = Mat4f[]
    for (dir, up) in directions
        target = Vec3f(position[1] + dir[1], position[2] + dir[2], position[3] + dir[3])
        forward = normalize(dir)
        right = normalize(cross(forward, up))
        actual_up = cross(right, forward)

        view_mat = Mat4f(
            right[1], actual_up[1], -forward[1], 0,
            right[2], actual_up[2], -forward[2], 0,
            right[3], actual_up[3], -forward[3], 0,
            -dot(right, position), -dot(actual_up, position), dot(forward, position), 1
        )

        push!(matrices, proj * view_mat)
    end

    return matrices
end
