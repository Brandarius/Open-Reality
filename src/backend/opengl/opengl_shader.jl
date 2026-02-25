# OpenGL shader implementation

"""
    ShaderProgram

Compiled and linked OpenGL shader program with cached uniform locations.
"""
mutable struct ShaderProgram <: AbstractShaderProgram
    id::GLuint
    uniform_cache::Dict{String, GLint}

    ShaderProgram(id::GLuint) = new(id, Dict{String, GLint}())
end

# =============================================================================
# GL Driver Info (for cache key generation)
# =============================================================================

const _GL_DRIVER_INFO = Ref{String}("")

"""
    _capture_gl_driver_info!()

Capture GL_VENDOR, GL_RENDERER, GL_VERSION into a global string for use as
a cache key component. Must be called after an OpenGL context is current.
"""
function _capture_gl_driver_info!()
    vendor = unsafe_string(glGetString(GL_VENDOR))
    renderer = unsafe_string(glGetString(GL_RENDERER))
    version = unsafe_string(glGetString(GL_VERSION))
    _GL_DRIVER_INFO[] = "$(vendor)|$(renderer)|$(version)"
    @debug "GL driver info captured" driver=_GL_DRIVER_INFO[]
end

# =============================================================================
# GL Program Binary helpers (for shader cache)
# =============================================================================

"""
    _gl_get_program_binary(program_id::GLuint) -> Union{Tuple{GLenum, Vector{UInt8}}, Nothing}

Retrieve the compiled binary of a linked program via glGetProgramBinary.
Returns (binary_format, binary_data) or `nothing` if not available.
"""
function _gl_get_program_binary(program_id::GLuint)::Union{Tuple{GLenum, Vector{UInt8}}, Nothing}
    len_ref = Ref{GLint}(0)
    glGetProgramiv(program_id, GL_PROGRAM_BINARY_LENGTH, len_ref)
    binary_length = len_ref[]
    binary_length <= 0 && return nothing

    buffer = Vector{UInt8}(undef, binary_length)
    actual_len = Ref{GLsizei}(0)
    format_ref = Ref{GLenum}(0)

    glGetProgramBinary(program_id, GLsizei(binary_length), actual_len, format_ref, buffer)

    if actual_len[] <= 0
        return nothing
    end

    return (format_ref[], buffer[1:actual_len[]])
end

"""
    _gl_program_binary(program_id::GLuint, format::GLenum, data::Vector{UInt8}) -> Bool

Load a pre-compiled program binary via glProgramBinary.
Returns true if the program linked successfully from the binary.
"""
function _gl_program_binary(program_id::GLuint, format::GLenum, data::Vector{UInt8})::Bool
    glProgramBinary(program_id, format, data, GLsizei(length(data)))

    status = Ref{GLint}(-1)
    glGetProgramiv(program_id, GL_LINK_STATUS, status)
    return status[] == GL_TRUE
end

# =============================================================================
# Shader compilation
# =============================================================================

"""
    compile_shader(source::String, shader_type::GLenum) -> GLuint

Compile a single GLSL shader. Throws on compilation failure.
"""
function compile_shader(source::String, shader_type::GLenum)
    shader = glCreateShader(shader_type)
    glShaderSource(shader, 1, Ptr{GLchar}[pointer(source)], C_NULL)
    glCompileShader(shader)

    status = Ref{GLint}(-1)
    glGetShaderiv(shader, GL_COMPILE_STATUS, status)
    if status[] != GL_TRUE
        max_len = Ref{GLint}(0)
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, max_len)
        log_buf = Vector{UInt8}(undef, max_len[])
        actual_len = Ref{GLsizei}(0)
        glGetShaderInfoLog(shader, max_len[], actual_len, log_buf)
        log_str = String(log_buf[1:actual_len[]])
        glDeleteShader(shader)
        error("Shader compilation failed:\n$log_str")
    end

    return shader
end

"""
    create_shader_program(vertex_src::String, fragment_src::String) -> ShaderProgram

Compile vertex and fragment shaders, link them into a program.
Uses the persistent shader cache when available — on cache hit, loads the
pre-compiled binary directly (skipping GLSL compilation entirely).
"""
function create_shader_program(vertex_src::String, fragment_src::String)
    cache = get_shader_cache()

    # --- Try loading from cache ---
    if cache.enabled && !isempty(_GL_DRIVER_INFO[])
        key = shader_cache_key(vertex_src, fragment_src; driver_info=_GL_DRIVER_INFO[])
        cached_data = cache_lookup(key)

        if cached_data !== nothing && length(cached_data) > 4
            # First 4 bytes = binary format (GLenum stored as UInt32)
            format = reinterpret(GLenum, cached_data[1:4])[1]
            binary = cached_data[5:end]

            program = glCreateProgram()
            if _gl_program_binary(program, format, binary)
                @debug "Shader loaded from cache" key=key
                return ShaderProgram(program)
            end

            # Binary invalid (driver update?) — fall through to normal compilation
            glDeleteProgram(program)
            @debug "Cached shader binary invalid, recompiling" key=key
        end
    end

    # --- Normal compilation path ---
    vert = compile_shader(vertex_src, GL_VERTEX_SHADER)
    frag = compile_shader(fragment_src, GL_FRAGMENT_SHADER)

    program = glCreateProgram()
    glAttachShader(program, vert)
    glAttachShader(program, frag)

    # Hint that we want to retrieve the binary after linking
    glProgramParameteri(program, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE)

    glLinkProgram(program)

    status = Ref{GLint}(-1)
    glGetProgramiv(program, GL_LINK_STATUS, status)
    if status[] != GL_TRUE
        max_len = Ref{GLint}(0)
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, max_len)
        log_buf = Vector{UInt8}(undef, max_len[])
        actual_len = Ref{GLsizei}(0)
        glGetProgramInfoLog(program, max_len[], actual_len, log_buf)
        log_str = String(log_buf[1:actual_len[]])
        glDeleteProgram(program)
        error("Shader program linking failed:\n$log_str")
    end

    glDetachShader(program, vert)
    glDetachShader(program, frag)
    glDeleteShader(vert)
    glDeleteShader(frag)

    # --- Store in cache ---
    if cache.enabled && !isempty(_GL_DRIVER_INFO[])
        result = _gl_get_program_binary(program)
        if result !== nothing
            format, binary = result
            # Prepend format as first 4 bytes for later retrieval
            data = vcat(reinterpret(UInt8, [format]), binary)
            key = shader_cache_key(vertex_src, fragment_src; driver_info=_GL_DRIVER_INFO[])
            cache_store!(key, data, "opengl";
                        source_hash=hash(vertex_src, hash(fragment_src)),
                        driver_hash=hash(_GL_DRIVER_INFO[]))
            @debug "Shader cached" key=key size=length(data)
        end
    end

    return ShaderProgram(program)
end

"""
    get_uniform_location!(sp::ShaderProgram, name::String) -> GLint

Get (and cache) a uniform location by name.
"""
function get_uniform_location!(sp::ShaderProgram, name::String)
    return get!(sp.uniform_cache, name) do
        glGetUniformLocation(sp.id, name)
    end
end

# Uniform setters

function set_uniform!(sp::ShaderProgram, name::String, val::Mat4f)
    loc = get_uniform_location!(sp, name)
    glUniformMatrix4fv(loc, 1, GL_FALSE, Ref(val))
end

function set_uniform!(sp::ShaderProgram, name::String, val::SMatrix{3, 3, Float32, 9})
    loc = get_uniform_location!(sp, name)
    glUniformMatrix3fv(loc, 1, GL_FALSE, Ref(val))
end

function set_uniform!(sp::ShaderProgram, name::String, val::Vec3f)
    loc = get_uniform_location!(sp, name)
    glUniform3f(loc, val[1], val[2], val[3])
end

function set_uniform!(sp::ShaderProgram, name::String, val::Float32)
    loc = get_uniform_location!(sp, name)
    glUniform1f(loc, val)
end

function set_uniform!(sp::ShaderProgram, name::String, val::Int32)
    loc = get_uniform_location!(sp, name)
    glUniform1i(loc, val)
end

function set_uniform!(sp::ShaderProgram, name::String, val::RGB{Float32})
    loc = get_uniform_location!(sp, name)
    glUniform3f(loc, val.r, val.g, val.b)
end

function set_uniform!(sp::ShaderProgram, name::String, val::Vec2f)
    loc = get_uniform_location!(sp, name)
    glUniform2f(loc, val[1], val[2])
end

"""
    create_compute_shader_program(compute_src::String) -> ShaderProgram

Compile a compute shader and link it into a program. Requires OpenGL 4.3+.
Uses the persistent shader cache when available.
"""
function create_compute_shader_program(compute_src::String)
    cache = get_shader_cache()

    # --- Try loading from cache ---
    if cache.enabled && !isempty(_GL_DRIVER_INFO[])
        key = shader_cache_key(compute_src; driver_info=_GL_DRIVER_INFO[])
        cached_data = cache_lookup(key)

        if cached_data !== nothing && length(cached_data) > 4
            format = reinterpret(GLenum, cached_data[1:4])[1]
            binary = cached_data[5:end]

            program = glCreateProgram()
            if _gl_program_binary(program, format, binary)
                @debug "Compute shader loaded from cache" key=key
                return ShaderProgram(program)
            end

            glDeleteProgram(program)
            @debug "Cached compute shader binary invalid, recompiling" key=key
        end
    end

    # --- Normal compilation path ---
    cs = compile_shader(compute_src, GL_COMPUTE_SHADER)

    program = glCreateProgram()
    glAttachShader(program, cs)

    glProgramParameteri(program, GL_PROGRAM_BINARY_RETRIEVABLE_HINT, GL_TRUE)

    glLinkProgram(program)

    status = Ref{GLint}(-1)
    glGetProgramiv(program, GL_LINK_STATUS, status)
    if status[] != GL_TRUE
        max_len = Ref{GLint}(0)
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, max_len)
        log_buf = Vector{UInt8}(undef, max_len[])
        actual_len = Ref{GLsizei}(0)
        glGetProgramInfoLog(program, max_len[], actual_len, log_buf)
        log_str = String(log_buf[1:actual_len[]])
        glDeleteProgram(program)
        error("Compute shader program linking failed:\n$log_str")
    end

    glDetachShader(program, cs)
    glDeleteShader(cs)

    # --- Store in cache ---
    if cache.enabled && !isempty(_GL_DRIVER_INFO[])
        result = _gl_get_program_binary(program)
        if result !== nothing
            format, binary = result
            data = vcat(reinterpret(UInt8, [format]), binary)
            key = shader_cache_key(compute_src; driver_info=_GL_DRIVER_INFO[])
            cache_store!(key, data, "opengl";
                        source_hash=hash(compute_src),
                        driver_hash=hash(_GL_DRIVER_INFO[]))
            @debug "Compute shader cached" key=key size=length(data)
        end
    end

    return ShaderProgram(program)
end

function set_uniform!(sp::ShaderProgram, name::String, val::UInt32)
    loc = get_uniform_location!(sp, name)
    glUniform1ui(loc, val)
end

"""
    destroy_shader_program!(sp::ShaderProgram)

Delete the OpenGL shader program.
"""
function destroy_shader_program!(sp::ShaderProgram)
    glDeleteProgram(sp.id)
    sp.id = GLuint(0)
end
