use crate::detect;
use crate::project::ProjectContext;
use crate::state::*;

pub async fn run(ctx: ProjectContext) -> anyhow::Result<()> {
    let platform = Platform::detect();

    println!("OpenReality Project Info");
    println!("=======================");
    println!("  Platform:     {}", platform.label());
    println!("  Project root: {}", ctx.project_root.display());
    println!("  Project kind: {:?}", ctx.kind);
    println!("  Engine path:  {}", ctx.engine_path.display());
    println!();

    // Tool detection
    println!("Tools");
    println!("-----");
    let tools = detect::detect_all_tools(platform).await;
    print_tool("Julia", &tools.julia);
    print_tool("Cargo", &tools.cargo);
    print_tool("Swift", &tools.swift);
    print_tool("wasm-pack", &tools.wasm_pack);
    print_tool("vulkaninfo", &tools.vulkaninfo);
    print_lib("GLFW", &tools.glfw);
    print_lib("OpenGL Dev", &tools.opengl_dev);
    println!();

    // Backend status
    println!("Backends");
    println!("--------");
    let backends = detect::detect_all_backends(&ctx.engine_path, &tools, platform);
    for bs in &backends {
        let status_str = match &bs.build_status {
            BuildStatus::NotNeeded => "ready (no build needed)".to_string(),
            BuildStatus::NotBuilt => "not built".to_string(),
            BuildStatus::Built { modified, .. } => {
                if let Some(m) = modified {
                    format!("built ({})", m)
                } else {
                    "built".to_string()
                }
            }
            BuildStatus::Building => "building...".to_string(),
            BuildStatus::BuildFailed { exit_code } => {
                format!("build failed (exit code: {:?})", exit_code)
            }
        };
        let deps = if bs.deps_satisfied {
            "deps ok"
        } else {
            "deps missing"
        };
        println!("  {:<12} {} [{}]", bs.backend.label(), status_str, deps);
    }
    println!();

    // Julia packages
    let pkg_status = detect::check_julia_packages(&ctx.project_root);
    println!("Julia Packages");
    println!("--------------");
    match pkg_status {
        Some(true) => println!("  Manifest.toml found (packages installed)"),
        Some(false) => println!("  Manifest.toml missing (run: orcli setup install)"),
        None => println!("  No Project.toml found"),
    }
    println!();

    // Examples
    let examples = detect::discover_examples(&ctx.project_root);
    println!("Scenes/Examples: {} found", examples.len());

    Ok(())
}

fn print_tool(name: &str, status: &ToolStatus) {
    match status {
        ToolStatus::Found { version, path } => {
            println!("  {:<12} {} ({})", name, version, path.display());
        }
        ToolStatus::NotFound => {
            println!("  {:<12} not found", name);
        }
    }
}

fn print_lib(name: &str, status: &LibraryStatus) {
    let label = match status {
        LibraryStatus::Found => "found",
        LibraryStatus::NotFound => "not found",
        LibraryStatus::Unknown => "unknown",
    };
    println!("  {:<12} {}", name, label);
}
