use crate::project::{ProjectContext, ProjectKind};

pub async fn run(ctx: ProjectContext) -> anyhow::Result<()> {
    let git_dir = match ctx.kind {
        ProjectKind::EngineDev => ctx.project_root.clone(),
        ProjectKind::UserProject => ctx.engine_path.clone(),
    };

    if !git_dir.exists() {
        anyhow::bail!(
            "Engine directory does not exist: {}\n  \
             Check that .openreality/config.toml has a correct engine_path.",
            git_dir.display()
        );
    }

    // Step 1: git pull
    println!("Pulling latest changes in {}...", git_dir.display());
    let status = tokio::process::Command::new("git")
        .args(["pull"])
        .current_dir(&git_dir)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    if !status.success() {
        anyhow::bail!(
            "git pull failed (exit code: {:?}).\n  \
             Common causes:\n  \
             - No network connection\n  \
             - Uncommitted local changes (run `git status` in {})\n  \
             - Merge conflicts that need manual resolution",
            status.code(),
            git_dir.display()
        );
    }

    // Step 2: Update Julia dependencies
    println!("Updating Julia dependencies...");
    let julia_status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", "using Pkg; Pkg.instantiate()"])
        .current_dir(&ctx.project_root)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await;

    match julia_status {
        Ok(s) if s.success() => println!("Dependencies updated successfully."),
        Ok(s) => eprintln!(
            "Warning: Julia dependency update failed (exit code: {:?}).\n  \
             Run manually: cd {} && julia --project=. -e 'using Pkg; Pkg.instantiate()'",
            s.code(),
            ctx.project_root.display()
        ),
        Err(e) => eprintln!(
            "Warning: Could not run Julia ({}).\n  \
             Install Julia and run:\n    \
             cd {} && julia --project=. -e 'using Pkg; Pkg.instantiate()'",
            e,
            ctx.project_root.display()
        ),
    }

    println!("Update complete.");
    Ok(())
}
