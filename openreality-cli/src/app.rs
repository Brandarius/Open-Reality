use std::io;

use crossterm::event::{KeyCode, KeyModifiers};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use tokio::sync::mpsc;

use crate::build;
use crate::detect;
use crate::event::AppEvent;
use crate::project::ProjectContext;
use crate::runner;
use crate::state::*;
use crate::ui;

pub struct App {
    pub state: AppState,
    event_tx: mpsc::UnboundedSender<AppEvent>,
    build_handle: Option<tokio::task::JoinHandle<()>>,
    run_handle: Option<tokio::task::JoinHandle<()>>,
    setup_handle: Option<tokio::task::JoinHandle<()>>,
    test_handle: Option<tokio::task::JoinHandle<()>>,
}

impl App {
    pub async fn new(
        ctx: ProjectContext,
        event_tx: mpsc::UnboundedSender<AppEvent>,
    ) -> anyhow::Result<Self> {
        let project_root = ctx.project_root.clone();
        let engine_path = ctx.engine_path.clone();
        let mut state = AppState::new(ctx.project_root, ctx.kind, ctx.engine_path);

        // Run detection
        state.tools = detect::detect_all_tools(state.platform).await;
        state.julia_packages_installed = detect::check_julia_packages(&project_root);
        state.backends = detect::detect_all_backends(&engine_path, &state.tools, state.platform);
        state.examples = detect::discover_examples(&project_root);

        Ok(Self {
            state,
            event_tx,
            build_handle: None,
            run_handle: None,
            setup_handle: None,
            test_handle: None,
        })
    }

    pub async fn handle_event(&mut self, event: AppEvent) {
        match event {
            AppEvent::Key(key) => self.handle_key(key).await,
            AppEvent::Tick => {}
            AppEvent::Build(be) => self.handle_build_event(be),
            AppEvent::Run(re) => self.handle_run_event(re),
            AppEvent::Setup(se) => self.handle_setup_event(se),
            AppEvent::Test(te) => self.handle_test_event(te),
        }
    }

    async fn handle_key(&mut self, key: crossterm::event::KeyEvent) {
        // Global keys
        match (key.modifiers, key.code) {
            (KeyModifiers::CONTROL, KeyCode::Char('c')) | (_, KeyCode::Char('q')) => {
                if self.state.show_help {
                    self.state.show_help = false;
                } else {
                    self.state.should_quit = true;
                }
                return;
            }
            (_, KeyCode::Char('?')) => {
                self.state.show_help = !self.state.show_help;
                return;
            }
            (_, KeyCode::Esc) => {
                if self.state.show_help {
                    self.state.show_help = false;
                    return;
                }
            }
            (_, KeyCode::Char('1')) => {
                self.state.active_tab = Tab::Dashboard;
                return;
            }
            (_, KeyCode::Char('2')) => {
                self.state.active_tab = Tab::Build;
                return;
            }
            (_, KeyCode::Char('3')) => {
                self.state.active_tab = Tab::Run;
                return;
            }
            (_, KeyCode::Char('4')) => {
                self.state.active_tab = Tab::Setup;
                return;
            }
            (_, KeyCode::Char('5')) => {
                self.state.active_tab = Tab::Tests;
                return;
            }
            (_, KeyCode::Tab) => {
                self.state.active_tab = self.state.active_tab.next();
                return;
            }
            (KeyModifiers::SHIFT, KeyCode::BackTab) => {
                self.state.active_tab = self.state.active_tab.prev();
                return;
            }
            _ => {}
        }

        if self.state.show_help {
            return;
        }

        match self.state.active_tab {
            Tab::Dashboard => self.handle_dashboard_key(key).await,
            Tab::Build => self.handle_build_key(key).await,
            Tab::Run => self.handle_run_key(key).await,
            Tab::Setup => self.handle_setup_key(key).await,
            Tab::Tests => self.handle_test_key(key).await,
        }
    }

    async fn handle_dashboard_key(&mut self, key: crossterm::event::KeyEvent) {
        if self.state.creating_scene {
            match key.code {
                KeyCode::Enter => {
                    let name = self.state.scene_name_input.trim().to_string();
                    self.state.creating_scene = false;
                    self.state.scene_name_input.clear();
                    if !name.is_empty() {
                        let ctx = crate::project::ProjectContext {
                            project_root: self.state.project_root.clone(),
                            kind: self.state.project_kind.clone(),
                            engine_path: self.state.engine_path.clone(),
                            config: None,
                        };
                        match crate::commands::new::scene(name, ctx).await {
                            Ok(()) => {
                                self.state.examples =
                                    detect::discover_examples(&self.state.project_root);
                            }
                            Err(_e) => {}
                        }
                    }
                }
                KeyCode::Esc => {
                    self.state.creating_scene = false;
                    self.state.scene_name_input.clear();
                }
                KeyCode::Backspace => {
                    self.state.scene_name_input.pop();
                }
                KeyCode::Char(c) => {
                    self.state.scene_name_input.push(c);
                }
                _ => {}
            }
            return;
        }
        if let KeyCode::Char('n') = key.code {
            self.state.creating_scene = true;
        }
    }

    async fn handle_build_key(&mut self, key: crossterm::event::KeyEvent) {
        match key.code {
            // Build mode switching
            KeyCode::Char('a') => {
                self.state.build_mode = BuildMode::Backend;
            }
            KeyCode::Char('d') => {
                self.state.build_mode = BuildMode::Desktop;
            }
            KeyCode::Char('w') => {
                self.state.build_mode = BuildMode::Web;
            }
            KeyCode::Char('m') => {
                self.state.build_mode = BuildMode::Mobile;
            }
            KeyCode::Char('x') => {
                self.state.build_mode = BuildMode::Export;
            }
            KeyCode::Char('p') => {
                self.state.build_mode = BuildMode::Package;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                if self.state.build_mode == BuildMode::Backend {
                    self.state.build_selected = self.state.build_selected.saturating_sub(1);
                }
            }
            KeyCode::Down | KeyCode::Char('j') => {
                if self.state.build_mode == BuildMode::Backend {
                    let max = self.state.backends.len().saturating_sub(1);
                    self.state.build_selected = (self.state.build_selected + 1).min(max);
                }
            }
            KeyCode::Enter | KeyCode::Char('b') => match self.state.build_mode {
                BuildMode::Backend => self.start_build().await,
                other => {
                    self.state.build_log.clear();
                    self.state.build_log.push(
                        format!(
                            "{} builds run via CLI: orcli build {}",
                            other.label(),
                            other.label().to_lowercase()
                        ),
                        false,
                    );
                    self.state.build_log.push(
                            "TUI backend builds are fully supported. For other build targets, use the CLI directly.".into(),
                            false,
                        );
                }
            },
            KeyCode::Char('g') => self.state.build_log.scroll_to_top(),
            KeyCode::Char('G') => self.state.build_log.scroll_to_bottom(),
            KeyCode::PageUp => self.state.build_log.scroll_up(20),
            KeyCode::PageDown => self.state.build_log.scroll_down(20),
            _ => {}
        }
    }

    async fn handle_run_key(&mut self, key: crossterm::event::KeyEvent) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.state.run_selected = self.state.run_selected.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let max = self.state.examples.len().saturating_sub(1);
                self.state.run_selected = (self.state.run_selected + 1).min(max);
            }
            KeyCode::Left | KeyCode::Char('h') => {
                self.state.run_backend_idx = self.state.run_backend_idx.saturating_sub(1);
            }
            KeyCode::Right | KeyCode::Char('l') => {
                let max = self.state.runnable_backends().len().saturating_sub(1);
                self.state.run_backend_idx = (self.state.run_backend_idx + 1).min(max);
            }
            KeyCode::Char('c') => {
                self.state.warm_cache = !self.state.warm_cache;
            }
            KeyCode::Enter | KeyCode::Char('r') => {
                self.start_example().await;
            }
            KeyCode::Char('g') => self.state.run_log.scroll_to_top(),
            KeyCode::Char('G') => self.state.run_log.scroll_to_bottom(),
            KeyCode::PageUp => self.state.run_log.scroll_up(20),
            KeyCode::PageDown => self.state.run_log.scroll_down(20),
            _ => {}
        }
    }

    async fn handle_setup_key(&mut self, key: crossterm::event::KeyEvent) {
        match key.code {
            KeyCode::Up | KeyCode::Char('k') => {
                self.state.setup_selected = self.state.setup_selected.saturating_sub(1);
            }
            KeyCode::Down | KeyCode::Char('j') => {
                let max = SetupAction::ALL.len().saturating_sub(1);
                self.state.setup_selected = (self.state.setup_selected + 1).min(max);
            }
            KeyCode::Enter => {
                self.start_setup_action().await;
            }
            KeyCode::Char('g') => self.state.setup_log.scroll_to_top(),
            KeyCode::Char('G') => self.state.setup_log.scroll_to_bottom(),
            KeyCode::PageUp => self.state.setup_log.scroll_up(20),
            KeyCode::PageDown => self.state.setup_log.scroll_down(20),
            _ => {}
        }
    }

    async fn start_build(&mut self) {
        if matches!(self.state.build_process, ProcessStatus::Running) {
            self.state
                .build_log
                .push("A build is already in progress.".into(), true);
            return;
        }

        let backend_state = &self.state.backends[self.state.build_selected];
        let backend = backend_state.backend;

        if !backend.needs_build() {
            self.state.build_log.push(
                format!("{} requires no build step.", backend.label()),
                false,
            );
            return;
        }

        if !backend_state.deps_satisfied {
            self.state.build_log.push(
                format!(
                    "Missing dependencies for {}. Check the Setup tab.",
                    backend.label()
                ),
                true,
            );
            return;
        }

        self.state.build_log.clear();
        self.state
            .build_log
            .push(format!("Building {}...", backend.label()), false);
        self.state.build_process = ProcessStatus::Running;
        self.state.backends[self.state.build_selected].build_status = BuildStatus::Building;

        let (build_tx, mut build_rx) = mpsc::unbounded_channel();
        let main_tx = self.event_tx.clone();
        tokio::spawn(async move {
            while let Some(ev) = build_rx.recv().await {
                if main_tx.send(AppEvent::Build(ev)).is_err() {
                    break;
                }
            }
        });

        let engine_path = self.state.engine_path.clone();
        let platform = self.state.platform;
        match build::spawn_build(&engine_path, backend, platform, build_tx).await {
            Ok(handle) => self.build_handle = Some(handle),
            Err(e) => {
                self.state
                    .build_log
                    .push(format!("Failed to start build: {e}"), true);
                self.state.build_process = ProcessStatus::Failed {
                    error: e.to_string(),
                };
            }
        }
    }

    fn handle_build_event(&mut self, event: build::BuildEvent) {
        match event {
            build::BuildEvent::StdoutLine(line) => {
                self.state.build_log.push(line, false);
            }
            build::BuildEvent::StderrLine(line) => {
                self.state.build_log.push(line, true);
            }
            build::BuildEvent::Finished { exit_code } => {
                let success = exit_code == Some(0);
                self.state.build_process = ProcessStatus::Finished { exit_code };

                if success {
                    self.state.build_log.push("Build succeeded!".into(), false);
                    let idx = self.state.build_selected;
                    let backend = self.state.backends[idx].backend;
                    self.state.backends[idx].build_status = detect::check_backend_artifact(
                        &self.state.engine_path,
                        backend,
                        self.state.platform,
                    );
                } else {
                    self.state
                        .build_log
                        .push(format!("Build failed (exit code: {exit_code:?})"), true);
                    let idx = self.state.build_selected;
                    self.state.backends[idx].build_status = BuildStatus::BuildFailed { exit_code };
                }
            }
            build::BuildEvent::Error(e) => {
                self.state.build_log.push(format!("Error: {e}"), true);
                self.state.build_process = ProcessStatus::Failed { error: e };
            }
        }
    }

    async fn start_example(&mut self) {
        if self.state.examples.is_empty() {
            return;
        }
        if matches!(self.state.run_process, ProcessStatus::Running) {
            self.state
                .run_log
                .push("An example is already running.".into(), true);
            return;
        }

        let example = &self.state.examples[self.state.run_selected];
        let filename = example.filename.clone();

        self.state.run_log.clear();
        self.state
            .run_log
            .push(format!("Running {}...", filename), false);
        self.state.run_process = ProcessStatus::Running;

        let (run_tx, mut run_rx) = mpsc::unbounded_channel();
        let main_tx = self.event_tx.clone();
        tokio::spawn(async move {
            while let Some(ev) = run_rx.recv().await {
                if main_tx.send(AppEvent::Run(ev)).is_err() {
                    break;
                }
            }
        });

        let project_root = self.state.project_root.clone();
        let args = vec!["--project=.".to_string(), format!("examples/{filename}")];
        match runner::spawn_julia_command(&project_root, args, run_tx).await {
            Ok(handle) => self.run_handle = Some(handle),
            Err(e) => {
                self.state
                    .run_log
                    .push(format!("Failed to start: {e}"), true);
                self.state.run_process = ProcessStatus::Failed {
                    error: e.to_string(),
                };
            }
        }
    }

    fn handle_run_event(&mut self, event: runner::RunEvent) {
        match event {
            runner::RunEvent::StdoutLine(line) => {
                self.state.run_log.push(line, false);
            }
            runner::RunEvent::StderrLine(line) => {
                self.state.run_log.push(line, true);
            }
            runner::RunEvent::Finished { exit_code } => {
                self.state.run_process = ProcessStatus::Finished { exit_code };
                let success = exit_code == Some(0);
                if success {
                    self.state
                        .run_log
                        .push("Process finished successfully.".into(), false);
                } else {
                    self.state
                        .run_log
                        .push(format!("Process exited (code: {exit_code:?})"), true);
                }
            }
            runner::RunEvent::Error(e) => {
                self.state.run_log.push(format!("Error: {e}"), true);
                self.state.run_process = ProcessStatus::Failed { error: e };
            }
        }
    }

    async fn start_setup_action(&mut self) {
        if matches!(self.state.setup_process, ProcessStatus::Running) {
            self.state
                .setup_log
                .push("An action is already running.".into(), true);
            return;
        }

        let action = SetupAction::ALL[self.state.setup_selected];

        // Handle synchronous actions
        match action {
            SetupAction::RefreshDetection => {
                self.state.setup_log.clear();
                self.state
                    .setup_log
                    .push("Refreshing tool detection...".into(), false);
                self.state.tools = detect::detect_all_tools(self.state.platform).await;
                self.state.backends = detect::detect_all_backends(
                    &self.state.project_root,
                    &self.state.tools,
                    self.state.platform,
                );
                self.state.julia_packages_installed =
                    detect::check_julia_packages(&self.state.project_root);
                self.state.examples = detect::discover_examples(&self.state.project_root);
                self.state
                    .setup_log
                    .push("Detection complete.".into(), false);
                return;
            }
            SetupAction::CacheClear => {
                self.state.setup_log.clear();
                let cache_dir = self
                    .state
                    .project_root
                    .join(".openreality")
                    .join("shader_cache");
                if cache_dir.exists() {
                    match std::fs::remove_dir_all(&cache_dir) {
                        Ok(()) => self
                            .state
                            .setup_log
                            .push("Shader cache cleared.".into(), false),
                        Err(e) => self
                            .state
                            .setup_log
                            .push(format!("Failed to clear cache: {e}"), true),
                    }
                } else {
                    self.state
                        .setup_log
                        .push("No shader cache found.".into(), false);
                }
                return;
            }
            SetupAction::CacheStatus => {
                self.state.setup_log.clear();
                let cache_dir = self
                    .state
                    .project_root
                    .join(".openreality")
                    .join("shader_cache");
                if cache_dir.exists() {
                    let mut count = 0usize;
                    let mut total_size = 0u64;
                    if let Ok(entries) = std::fs::read_dir(&cache_dir) {
                        for entry in entries.flatten() {
                            if entry.path().is_file() {
                                count += 1;
                                total_size += entry.metadata().map(|m| m.len()).unwrap_or(0);
                            }
                        }
                    }
                    self.state.setup_log.push(
                        format!(
                            "Shader cache: {} files, {:.1} KB",
                            count,
                            total_size as f64 / 1024.0
                        ),
                        false,
                    );
                } else {
                    self.state
                        .setup_log
                        .push("No shader cache found.".into(), false);
                }
                return;
            }
            _ => {}
        }

        // Handle Julia-based actions
        let pkg_expr = match action {
            SetupAction::PkgInstantiate => "Pkg.instantiate()",
            SetupAction::PkgStatus => "Pkg.status()",
            SetupAction::PkgUpdate => "Pkg.update()",
            SetupAction::CacheShaders => {
                r#"using OpenReality; OpenReality._warm_shader_cache!("opengl")"#
            }
            _ => unreachable!(),
        };

        self.state.setup_log.clear();
        self.state
            .setup_log
            .push(format!("Running {}...", action.label()), false);
        self.state.setup_process = ProcessStatus::Running;

        let (setup_tx, mut setup_rx) = mpsc::unbounded_channel();
        let main_tx = self.event_tx.clone();
        tokio::spawn(async move {
            while let Some(ev) = setup_rx.recv().await {
                if main_tx.send(AppEvent::Setup(ev)).is_err() {
                    break;
                }
            }
        });

        let project_root = self.state.project_root.clone();
        match runner::spawn_pkg_command(&project_root, pkg_expr, setup_tx).await {
            Ok(handle) => self.setup_handle = Some(handle),
            Err(e) => {
                self.state
                    .setup_log
                    .push(format!("Failed to start: {e}"), true);
                self.state.setup_process = ProcessStatus::Failed {
                    error: e.to_string(),
                };
            }
        }
    }

    fn handle_setup_event(&mut self, event: runner::RunEvent) {
        match event {
            runner::RunEvent::StdoutLine(line) => {
                self.state.setup_log.push(line, false);
            }
            runner::RunEvent::StderrLine(line) => {
                self.state.setup_log.push(line, true);
            }
            runner::RunEvent::Finished { exit_code } => {
                self.state.setup_process = ProcessStatus::Finished { exit_code };
                let success = exit_code == Some(0);
                if success {
                    self.state
                        .setup_log
                        .push("Action completed successfully.".into(), false);
                } else {
                    self.state
                        .setup_log
                        .push(format!("Action failed (exit code: {exit_code:?})"), true);
                }
            }
            runner::RunEvent::Error(e) => {
                self.state.setup_log.push(format!("Error: {e}"), true);
                self.state.setup_process = ProcessStatus::Failed { error: e };
            }
        }
    }

    async fn handle_test_key(&mut self, key: crossterm::event::KeyEvent) {
        match key.code {
            KeyCode::Enter | KeyCode::Char('t') => {
                self.start_tests().await;
            }
            KeyCode::Char('g') => self.state.test_log.scroll_to_top(),
            KeyCode::Char('G') => self.state.test_log.scroll_to_bottom(),
            KeyCode::PageUp => self.state.test_log.scroll_up(20),
            KeyCode::PageDown => self.state.test_log.scroll_down(20),
            _ => {}
        }
    }

    async fn start_tests(&mut self) {
        if matches!(self.state.test_process, ProcessStatus::Running) {
            self.state
                .test_log
                .push("Tests are already running.".into(), true);
            return;
        }

        self.state.test_log.clear();
        self.state
            .test_log
            .push("Running test suite...".into(), false);
        self.state.test_process = ProcessStatus::Running;

        let (test_tx, mut test_rx) = mpsc::unbounded_channel();
        let main_tx = self.event_tx.clone();
        tokio::spawn(async move {
            while let Some(ev) = test_rx.recv().await {
                if main_tx.send(AppEvent::Test(ev)).is_err() {
                    break;
                }
            }
        });

        let engine_path = self.state.engine_path.clone();
        match runner::spawn_pkg_command(&engine_path, "Pkg.test()", test_tx).await {
            Ok(handle) => self.test_handle = Some(handle),
            Err(e) => {
                self.state
                    .test_log
                    .push(format!("Failed to start tests: {e}"), true);
                self.state.test_process = ProcessStatus::Failed {
                    error: e.to_string(),
                };
            }
        }
    }

    fn handle_test_event(&mut self, event: runner::RunEvent) {
        match event {
            runner::RunEvent::StdoutLine(line) => {
                self.state.test_log.push(line, false);
            }
            runner::RunEvent::StderrLine(line) => {
                self.state.test_log.push(line, true);
            }
            runner::RunEvent::Finished { exit_code } => {
                self.state.test_process = ProcessStatus::Finished { exit_code };
                if exit_code == Some(0) {
                    self.state.test_log.push("All tests passed!".into(), false);
                } else {
                    self.state
                        .test_log
                        .push(format!("Tests failed (exit code: {exit_code:?})"), true);
                }
            }
            runner::RunEvent::Error(e) => {
                self.state.test_log.push(format!("Error: {e}"), true);
                self.state.test_process = ProcessStatus::Failed { error: e };
            }
        }
    }

    pub fn draw(
        &self,
        terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    ) -> anyhow::Result<()> {
        terminal.draw(|frame| {
            ui::render(frame, &self.state);
        })?;
        Ok(())
    }

    /// Suspend the TUI, run a Julia example with direct terminal access (for GLFW),
    /// then restore the TUI.
    pub async fn run_example_suspended(
        &mut self,
        terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    ) -> anyhow::Result<()> {
        if self.state.examples.is_empty() {
            return Ok(());
        }

        let example = &self.state.examples[self.state.run_selected];
        let filename = example.filename.clone();

        // Suspend TUI
        disable_raw_mode()?;
        execute!(io::stdout(), LeaveAlternateScreen)?;

        println!(
            "\n--- Running {} (press Ctrl+C in the window to quit) ---\n",
            filename
        );

        // Optionally warm shader cache before running
        if self.state.warm_cache {
            println!("Warming shader cache...");
            let _ = tokio::process::Command::new("julia")
                .args([
                    "--project=.",
                    "-e",
                    r#"using OpenReality; OpenReality._warm_shader_cache!("opengl")"#,
                ])
                .current_dir(&self.state.project_root)
                .stdin(std::process::Stdio::inherit())
                .stdout(std::process::Stdio::inherit())
                .stderr(std::process::Stdio::inherit())
                .status()
                .await;
        }

        let status = tokio::process::Command::new("julia")
            .args(["--project=.", &format!("examples/{filename}")])
            .current_dir(&self.state.project_root)
            .stdin(std::process::Stdio::inherit())
            .stdout(std::process::Stdio::inherit())
            .stderr(std::process::Stdio::inherit())
            .status()
            .await;

        match &status {
            Ok(s) => println!(
                "\n--- Example exited with code: {} ---",
                s.code().unwrap_or(-1)
            ),
            Err(e) => println!("\n--- Failed to run example: {e} ---"),
        }

        println!("Press Enter to return to TUI...");
        let _ = std::io::stdin().read_line(&mut String::new());

        // Restore TUI
        enable_raw_mode()?;
        execute!(io::stdout(), EnterAlternateScreen)?;
        terminal.clear()?;

        Ok(())
    }
}
