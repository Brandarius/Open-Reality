use crate::project::ProjectContext;

pub async fn run(file: String, warm_cache: bool, ctx: ProjectContext) -> anyhow::Result<()> {
    if warm_cache {
        println!("Warming shader cache...");
        let julia_code = r#"using OpenReality; OpenReality._warm_shader_cache!("opengl")"#;
        let warm_status = tokio::process::Command::new("julia")
            .args(["--project=.", "-e", julia_code])
            .current_dir(&ctx.project_root)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .await?;

        if !warm_status.success() {
            eprintln!(
                "Warning: shader cache warming failed (exit code: {:?}), continuing anyway.\n  \
                 Try running manually: julia --project=. -e 'using OpenReality; OpenReality._warm_shader_cache!(\"opengl\")'",
                warm_status.code()
            );
        }
    }

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", &file])
        .current_dir(&ctx.project_root)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    std::process::exit(status.code().unwrap_or(1));
}
