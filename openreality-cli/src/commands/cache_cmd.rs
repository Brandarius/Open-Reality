use std::path::PathBuf;

use crate::cli::CacheAction;
use crate::project::ProjectContext;

pub async fn run(action: CacheAction, ctx: ProjectContext) -> anyhow::Result<()> {
    match action {
        CacheAction::Shaders { backend } => warm_shader_cache(backend, ctx).await,
        CacheAction::Clear => clear_shader_cache(ctx).await,
        CacheAction::Status => show_cache_status(ctx).await,
    }
}

async fn warm_shader_cache(backend: String, ctx: ProjectContext) -> anyhow::Result<()> {
    println!("Warming shader cache for {} backend...", backend);

    let julia_code = format!(
        r#"using OpenReality; OpenReality._warm_shader_cache!("{backend}")"#,
        backend = backend,
    );

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", &julia_code])
        .current_dir(&ctx.engine_path)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if status.success() {
        println!("Shader cache warmed successfully.");
    }

    std::process::exit(status.code().unwrap_or(1));
}

async fn clear_shader_cache(ctx: ProjectContext) -> anyhow::Result<()> {
    let cache_dir = ctx.project_root.join(".openreality").join("shader_cache");
    if cache_dir.exists() {
        let entry_count = count_cache_files(&cache_dir);
        std::fs::remove_dir_all(&cache_dir)?;
        println!(
            "Shader cache cleared ({} entries removed): {}",
            entry_count,
            cache_dir.display()
        );
    } else {
        println!("No shader cache found.");
    }
    Ok(())
}

async fn show_cache_status(ctx: ProjectContext) -> anyhow::Result<()> {
    let cache_dir = ctx.project_root.join(".openreality").join("shader_cache");
    if !cache_dir.exists() {
        println!("No shader cache found.");
        return Ok(());
    }

    println!("Shader cache: {}", cache_dir.display());

    let (gl_count, gl_size) = count_and_size(&cache_dir.join("opengl"));
    let (vk_count, vk_size) = count_and_size(&cache_dir.join("vulkan"));

    println!(
        "  OpenGL:  {} cached programs ({:.2} KB)",
        gl_count,
        gl_size as f64 / 1024.0
    );
    println!(
        "  Vulkan:  {} cached SPIR-V   ({:.2} KB)",
        vk_count,
        vk_size as f64 / 1024.0
    );
    println!(
        "  Total:   {} entries ({:.2} KB)",
        gl_count + vk_count,
        (gl_size + vk_size) as f64 / 1024.0
    );

    Ok(())
}

fn count_cache_files(dir: &PathBuf) -> usize {
    let mut count = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                count += count_cache_files(&path);
            } else if matches!(
                path.extension().and_then(|e| e.to_str()),
                Some("bin") | Some("spv")
            ) {
                count += 1;
            }
        }
    }
    count
}

fn count_and_size(dir: &PathBuf) -> (usize, u64) {
    let mut count = 0;
    let mut total_size: u64 = 0;
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_file() {
                if let Ok(meta) = path.metadata() {
                    count += 1;
                    total_size += meta.len();
                }
            }
        }
    }
    (count, total_size)
}
