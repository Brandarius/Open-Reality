# Navigation Demo — Hot-Reload Script
# Edit this file while the demo is running to see changes live!
#
# This function is called every frame for each agent's bobbing animation.
# Try changing the speed or amplitude and save the file.

function agent_bob_offset(time::Float64)::Float64
    return 0.15 * sin(time * 3.0)
end
