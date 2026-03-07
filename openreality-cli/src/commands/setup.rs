use crate::cli::CliSetupAction;
use crate::project::ProjectContext;

pub async fn run(action: CliSetupAction, ctx: ProjectContext) -> anyhow::Result<()> {
    let julia_code = match action {
        CliSetupAction::Install => {
            println!("Installing Julia dependencies...");
            r#"using Pkg; Pkg.activate("."); Pkg.instantiate()"#
        }
        CliSetupAction::Status => r#"using Pkg; Pkg.activate("."); Pkg.status()"#,
        CliSetupAction::Update => {
            println!("Updating Julia packages...");
            r#"using Pkg; Pkg.activate("."); Pkg.update()"#
        }
    };

    let status = tokio::process::Command::new("julia")
        .args(["--project=.", "-e", julia_code])
        .current_dir(&ctx.project_root)
        .stdin(std::process::Stdio::inherit())
        .stdout(std::process::Stdio::inherit())
        .stderr(std::process::Stdio::inherit())
        .status()
        .await?;

    std::process::exit(status.code().unwrap_or(1));
}
