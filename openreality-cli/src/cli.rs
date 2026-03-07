use std::path::PathBuf;

use clap::{Parser, Subcommand, ValueEnum};

#[derive(Parser)]
#[command(
    name = "orcli",
    about = "Open Reality game engine CLI",
    version,
    arg_required_else_help = false
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand)]
pub enum Command {
    /// Initialize a new OpenReality project
    Init {
        /// Project name (directory to create)
        name: String,
        /// Clone for engine development instead of creating a user project
        #[arg(long)]
        engine_dev: bool,
        /// Git URL for the engine repo
        #[arg(
            long,
            default_value = "https://github.com/sinisterMage/Open-Reality.git"
        )]
        repo_url: String,
    },
    /// Generate new project files
    New {
        #[command(subcommand)]
        kind: NewKind,
    },
    /// Run a Julia scene/script
    Run {
        /// Path to the .jl file to run
        file: String,
        /// Warm the shader cache before running (pre-compiles all shaders)
        #[arg(long)]
        warm_cache: bool,
    },
    /// Build targets (backends, desktop, web, mobile)
    Build {
        #[command(subcommand)]
        target: BuildTarget,
    },
    /// Export a scene to a portable format
    Export {
        /// Scene file (.jl) that creates and returns a Scene
        scene: String,
        /// Output file path
        #[arg(short, long)]
        output: PathBuf,
        /// Export format
        #[arg(short, long, default_value = "orsb", value_enum)]
        format: ExportFormat,
        /// Include physics configuration
        #[arg(long)]
        physics: bool,
        /// Compress textures in the output
        #[arg(long, default_value_t = true)]
        compress_textures: bool,
    },
    /// Package a built application for distribution
    Package {
        #[command(subcommand)]
        target: PackageTarget,
    },
    /// Run the Julia test suite
    Test,
    /// Manage the shader cache
    Cache {
        #[command(subcommand)]
        action: CacheAction,
    },
    /// Pull latest engine changes and update dependencies
    Update,
    /// Manage Julia package environment
    Setup {
        #[command(subcommand)]
        action: CliSetupAction,
    },
    /// Show project info, tool detection, and backend status
    Info,
}

#[derive(Subcommand)]
pub enum CliSetupAction {
    /// Install/resolve Julia dependencies (Pkg.instantiate)
    Install,
    /// Show Julia package status (Pkg.status)
    Status,
    /// Update Julia packages (Pkg.update)
    Update,
}

#[derive(Subcommand)]
pub enum CacheAction {
    /// Pre-compile and cache all shader variants
    Shaders {
        /// Backend to warm cache for (opengl, vulkan)
        #[arg(short, long, default_value = "opengl")]
        backend: String,
    },
    /// Clear the shader cache
    Clear,
    /// Show shader cache statistics
    Status,
}

#[derive(Subcommand)]
pub enum NewKind {
    /// Generate a new scene file
    Scene {
        /// Name of the scene (used for filename)
        name: String,
    },
}

#[derive(Subcommand)]
pub enum BuildTarget {
    /// Build a GPU backend library (metal, webgpu, wasm)
    Backend {
        /// Backend name: metal, webgpu, wasm
        name: String,
    },
    /// Build standalone desktop executable via PackageCompiler.jl
    Desktop {
        /// Entry point Julia file
        entry: String,
        /// Target platform (linux, macos, windows). Defaults to current.
        #[arg(short, long)]
        platform: Option<DesktopPlatform>,
        /// Output directory
        #[arg(short, long, default_value = "build/desktop")]
        output: PathBuf,
        /// Enable release optimizations (slower build, faster runtime)
        #[arg(long)]
        release: bool,
    },
    /// Build for web deployment (WASM + ORSB)
    Web {
        /// Scene file to bundle (.jl)
        scene: String,
        /// Output directory
        #[arg(short, long, default_value = "build/web")]
        output: PathBuf,
        /// Enable release optimizations
        #[arg(long)]
        release: bool,
    },
    /// Build for mobile via WebView shell (experimental)
    Mobile {
        /// Scene file to bundle (.jl)
        scene: String,
        /// Target mobile platform
        #[arg(short, long, value_enum)]
        platform: MobilePlatform,
        /// Output directory
        #[arg(short, long, default_value = "build/mobile")]
        output: PathBuf,
    },
}

#[derive(Subcommand)]
pub enum PackageTarget {
    /// Package desktop build into distributable archive
    Desktop {
        /// Build directory (from `orcli build desktop`)
        #[arg(short, long, default_value = "build/desktop")]
        build_dir: PathBuf,
        /// Output directory for the package
        #[arg(short, long, default_value = "dist")]
        output: PathBuf,
        /// Target platform (linux, macos, windows). Defaults to current.
        #[arg(short, long)]
        platform: Option<DesktopPlatform>,
    },
    /// Package web build for deployment
    Web {
        /// Build directory (from `orcli build web`)
        #[arg(short, long, default_value = "build/web")]
        build_dir: PathBuf,
        /// Output directory for the package
        #[arg(short, long, default_value = "dist/web")]
        output: PathBuf,
    },
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum ExportFormat {
    /// OpenReality Scene Bundle (binary, for WASM runtime)
    Orsb,
    /// glTF 2.0 (JSON + binary buffers)
    Gltf,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum DesktopPlatform {
    Linux,
    Macos,
    Windows,
}

impl DesktopPlatform {
    pub fn detect() -> Self {
        if cfg!(target_os = "macos") {
            Self::Macos
        } else if cfg!(target_os = "windows") {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Linux => "linux",
            Self::Macos => "macos",
            Self::Windows => "windows",
        }
    }
}

#[derive(Clone, Copy, Debug, ValueEnum)]
pub enum MobilePlatform {
    Android,
    Ios,
}

impl MobilePlatform {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Android => "android",
            Self::Ios => "ios",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn test_cli_no_args() {
        let cli = Cli::try_parse_from(["orcli"]).unwrap();
        assert!(cli.command.is_none());
    }

    #[test]
    fn test_cli_init() {
        let cli = Cli::try_parse_from(["orcli", "init", "myproject"]).unwrap();
        match cli.command.unwrap() {
            Command::Init {
                name, engine_dev, ..
            } => {
                assert_eq!(name, "myproject");
                assert!(!engine_dev);
            }
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_cli_init_engine_dev() {
        let cli = Cli::try_parse_from(["orcli", "init", "myproject", "--engine-dev"]).unwrap();
        match cli.command.unwrap() {
            Command::Init { engine_dev, .. } => assert!(engine_dev),
            _ => panic!("Expected Init command"),
        }
    }

    #[test]
    fn test_cli_run() {
        let cli = Cli::try_parse_from(["orcli", "run", "scene.jl"]).unwrap();
        match cli.command.unwrap() {
            Command::Run { file, warm_cache } => {
                assert_eq!(file, "scene.jl");
                assert!(!warm_cache);
            }
            _ => panic!("Expected Run command"),
        }
    }

    #[test]
    fn test_cli_build_backend() {
        let cli = Cli::try_parse_from(["orcli", "build", "backend", "metal"]).unwrap();
        match cli.command.unwrap() {
            Command::Build {
                target: BuildTarget::Backend { name },
            } => {
                assert_eq!(name, "metal");
            }
            _ => panic!("Expected Build Backend command"),
        }
    }

    #[test]
    fn test_cli_export() {
        let cli = Cli::try_parse_from(["orcli", "export", "scene.jl", "-o", "out.orsb"]).unwrap();
        match cli.command.unwrap() {
            Command::Export { scene, output, .. } => {
                assert_eq!(scene, "scene.jl");
                assert_eq!(output, PathBuf::from("out.orsb"));
            }
            _ => panic!("Expected Export command"),
        }
    }

    #[test]
    fn test_cli_test() {
        let cli = Cli::try_parse_from(["orcli", "test"]).unwrap();
        assert!(matches!(cli.command.unwrap(), Command::Test));
    }

    #[test]
    fn test_cli_invalid_subcommand() {
        assert!(Cli::try_parse_from(["orcli", "invalid"]).is_err());
    }

    #[test]
    fn test_cli_update() {
        let cli = Cli::try_parse_from(["orcli", "update"]).unwrap();
        assert!(matches!(cli.command.unwrap(), Command::Update));
    }

    #[test]
    fn test_cli_setup_install() {
        let cli = Cli::try_parse_from(["orcli", "setup", "install"]).unwrap();
        match cli.command.unwrap() {
            Command::Setup {
                action: CliSetupAction::Install,
            } => {}
            _ => panic!("Expected Setup Install command"),
        }
    }

    #[test]
    fn test_cli_setup_status() {
        let cli = Cli::try_parse_from(["orcli", "setup", "status"]).unwrap();
        match cli.command.unwrap() {
            Command::Setup {
                action: CliSetupAction::Status,
            } => {}
            _ => panic!("Expected Setup Status command"),
        }
    }

    #[test]
    fn test_cli_setup_update() {
        let cli = Cli::try_parse_from(["orcli", "setup", "update"]).unwrap();
        match cli.command.unwrap() {
            Command::Setup {
                action: CliSetupAction::Update,
            } => {}
            _ => panic!("Expected Setup Update command"),
        }
    }

    #[test]
    fn test_cli_info() {
        let cli = Cli::try_parse_from(["orcli", "info"]).unwrap();
        assert!(matches!(cli.command.unwrap(), Command::Info));
    }
}
