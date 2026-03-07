use std::path::PathBuf;

use chrono::{DateTime, Local};

use crate::project::ProjectKind;

// ─── Platform ────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Platform {
    Linux,
    MacOS,
    Windows,
}

impl Platform {
    pub fn detect() -> Self {
        if cfg!(target_os = "macos") {
            Self::MacOS
        } else if cfg!(target_os = "windows") {
            Self::Windows
        } else {
            Self::Linux
        }
    }

    pub fn supports_metal(&self) -> bool {
        matches!(self, Self::MacOS)
    }

    pub fn supports_vulkan(&self) -> bool {
        !matches!(self, Self::MacOS)
    }

    pub fn label(&self) -> &'static str {
        match self {
            Self::Linux => "Linux",
            Self::MacOS => "macOS",
            Self::Windows => "Windows",
        }
    }
}

// ─── Tool/Dependency Status ──────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolStatus {
    Found { version: String, path: PathBuf },
    NotFound,
}

impl ToolStatus {
    pub fn is_available(&self) -> bool {
        matches!(self, Self::Found { .. })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LibraryStatus {
    Found,
    NotFound,
    Unknown,
}

#[derive(Debug, Clone)]
pub struct ToolSet {
    pub julia: ToolStatus,
    pub cargo: ToolStatus,
    pub swift: ToolStatus,
    pub wasm_pack: ToolStatus,
    pub vulkaninfo: ToolStatus,
    pub glfw: LibraryStatus,
    pub opengl_dev: LibraryStatus,
}

impl Default for ToolSet {
    fn default() -> Self {
        Self {
            julia: ToolStatus::NotFound,
            cargo: ToolStatus::NotFound,
            swift: ToolStatus::NotFound,
            wasm_pack: ToolStatus::NotFound,
            vulkaninfo: ToolStatus::NotFound,
            glfw: LibraryStatus::Unknown,
            opengl_dev: LibraryStatus::Unknown,
        }
    }
}

// ─── Backend ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Backend {
    OpenGL,
    Metal,
    Vulkan,
    WebGPU,
    WasmExport,
}

impl Backend {
    pub fn label(&self) -> &'static str {
        match self {
            Self::OpenGL => "OpenGL",
            Self::Metal => "Metal",
            Self::Vulkan => "Vulkan",
            Self::WebGPU => "WebGPU",
            Self::WasmExport => "WASM Export",
        }
    }

    pub fn available_on(platform: Platform) -> Vec<Backend> {
        let mut v = vec![Backend::OpenGL];
        if platform.supports_metal() {
            v.push(Backend::Metal);
        }
        if platform.supports_vulkan() {
            v.push(Backend::Vulkan);
        }
        v.push(Backend::WebGPU);
        v.push(Backend::WasmExport);
        v
    }

    pub fn needs_build(&self) -> bool {
        matches!(self, Self::Metal | Self::WebGPU | Self::WasmExport)
    }
}

// ─── Build Status ────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildStatus {
    NotNeeded,
    NotBuilt,
    Built {
        artifact_path: PathBuf,
        modified: Option<String>,
    },
    Building,
    BuildFailed {
        exit_code: Option<i32>,
    },
}

#[derive(Debug, Clone)]
pub struct BackendState {
    pub backend: Backend,
    pub build_status: BuildStatus,
    pub deps_satisfied: bool,
}

// ─── Example Metadata ────────────────────────────────────────────────

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct ExampleEntry {
    pub filename: String,
    pub path: PathBuf,
    pub description: String,
    pub required_backend: Option<Backend>,
}

// ─── Process Status ──────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum ProcessStatus {
    Idle,
    Running,
    Finished { exit_code: Option<i32> },
    Failed { error: String },
}

// ─── Log Buffer ──────────────────────────────────────────────────────

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub struct LogLine {
    pub timestamp: DateTime<Local>,
    pub text: String,
    pub is_stderr: bool,
}

pub struct LogBuffer {
    pub lines: Vec<LogLine>,
    pub scroll_offset: usize,
    pub auto_scroll: bool,
    max_lines: usize,
}

impl LogBuffer {
    pub fn new(max_lines: usize) -> Self {
        Self {
            lines: Vec::new(),
            scroll_offset: 0,
            auto_scroll: true,
            max_lines,
        }
    }

    pub fn push(&mut self, text: String, is_stderr: bool) {
        if self.lines.len() >= self.max_lines {
            self.lines.remove(0);
            self.scroll_offset = self.scroll_offset.saturating_sub(1);
        }
        self.lines.push(LogLine {
            timestamp: chrono::Local::now(),
            text,
            is_stderr,
        });
        if self.auto_scroll {
            self.scroll_to_bottom();
        }
    }

    pub fn scroll_to_bottom(&mut self) {
        self.scroll_offset = self.lines.len().saturating_sub(1);
    }

    pub fn clear(&mut self) {
        self.lines.clear();
        self.scroll_offset = 0;
    }

    pub fn scroll_up(&mut self, amount: usize) {
        self.scroll_offset = self.scroll_offset.saturating_sub(amount);
        self.auto_scroll = false;
    }

    pub fn scroll_down(&mut self, amount: usize) {
        self.scroll_offset = (self.scroll_offset + amount).min(self.lines.len().saturating_sub(1));
        if self.scroll_offset >= self.lines.len().saturating_sub(1) {
            self.auto_scroll = true;
        }
    }

    pub fn scroll_to_top(&mut self) {
        self.scroll_offset = 0;
        self.auto_scroll = false;
    }
}

// ─── Tabs ────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tab {
    Dashboard,
    Build,
    Run,
    Setup,
    Tests,
}

impl Tab {
    pub const ALL: &'static [Tab] = &[Tab::Dashboard, Tab::Build, Tab::Run, Tab::Setup, Tab::Tests];

    pub fn label(&self) -> &'static str {
        match self {
            Self::Dashboard => "Dashboard",
            Self::Build => "Build",
            Self::Run => "Run",
            Self::Setup => "Setup",
            Self::Tests => "Tests",
        }
    }

    pub fn index(&self) -> usize {
        match self {
            Self::Dashboard => 0,
            Self::Build => 1,
            Self::Run => 2,
            Self::Setup => 3,
            Self::Tests => 4,
        }
    }

    pub fn next(&self) -> Tab {
        match self {
            Self::Dashboard => Self::Build,
            Self::Build => Self::Run,
            Self::Run => Self::Setup,
            Self::Setup => Self::Tests,
            Self::Tests => Self::Dashboard,
        }
    }

    pub fn prev(&self) -> Tab {
        match self {
            Self::Dashboard => Self::Tests,
            Self::Build => Self::Dashboard,
            Self::Run => Self::Build,
            Self::Setup => Self::Run,
            Self::Tests => Self::Setup,
        }
    }
}

// ─── Setup Actions ───────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SetupAction {
    PkgInstantiate,
    PkgStatus,
    PkgUpdate,
    RefreshDetection,
    CacheShaders,
    CacheClear,
    CacheStatus,
}

impl SetupAction {
    pub const ALL: &'static [SetupAction] = &[
        Self::PkgInstantiate,
        Self::PkgStatus,
        Self::PkgUpdate,
        Self::RefreshDetection,
        Self::CacheShaders,
        Self::CacheClear,
        Self::CacheStatus,
    ];

    pub fn label(&self) -> &'static str {
        match self {
            Self::PkgInstantiate => "Pkg.instantiate()",
            Self::PkgStatus => "Pkg.status()",
            Self::PkgUpdate => "Pkg.update()",
            Self::RefreshDetection => "Refresh tool detection",
            Self::CacheShaders => "Warm shader cache",
            Self::CacheClear => "Clear shader cache",
            Self::CacheStatus => "Shader cache status",
        }
    }
}

// ─── Build Mode ─────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BuildMode {
    Backend,
    Desktop,
    Web,
    Mobile,
    Export,
    Package,
}

impl BuildMode {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Backend => "Backend",
            Self::Desktop => "Desktop",
            Self::Web => "Web",
            Self::Mobile => "Mobile",
            Self::Export => "Export",
            Self::Package => "Package",
        }
    }

    pub const ALL: &'static [BuildMode] = &[
        Self::Backend,
        Self::Desktop,
        Self::Web,
        Self::Mobile,
        Self::Export,
        Self::Package,
    ];
}

// ─── Application State ──────────────────────────────────────────────

#[allow(dead_code)]
pub struct AppState {
    pub platform: Platform,
    pub project_root: PathBuf,
    pub project_kind: ProjectKind,
    pub engine_path: PathBuf,
    pub active_tab: Tab,

    // Detection
    pub tools: ToolSet,
    pub julia_packages_installed: Option<bool>,

    // Backends
    pub backends: Vec<BackendState>,

    // Build tab
    pub build_mode: BuildMode,
    pub build_selected: usize,
    pub build_log: LogBuffer,
    pub build_process: ProcessStatus,

    // Run tab
    pub examples: Vec<ExampleEntry>,
    pub run_selected: usize,
    pub run_backend_idx: usize,
    pub run_log: LogBuffer,
    pub run_process: ProcessStatus,
    pub warm_cache: bool,

    // Setup tab
    pub setup_selected: usize,
    pub setup_log: LogBuffer,
    pub setup_process: ProcessStatus,

    // Tests tab
    pub test_log: LogBuffer,
    pub test_process: ProcessStatus,

    // Dashboard
    pub creating_scene: bool,
    pub scene_name_input: String,

    // Global
    pub show_help: bool,
    pub should_quit: bool,
}

impl AppState {
    pub fn new(project_root: PathBuf, project_kind: ProjectKind, engine_path: PathBuf) -> Self {
        let platform = Platform::detect();
        let backends = Backend::available_on(platform)
            .into_iter()
            .map(|b| BackendState {
                backend: b,
                build_status: if b.needs_build() {
                    BuildStatus::NotBuilt
                } else {
                    BuildStatus::NotNeeded
                },
                deps_satisfied: false,
            })
            .collect();

        Self {
            platform,
            project_root,
            project_kind,
            engine_path,
            active_tab: Tab::Dashboard,
            tools: ToolSet::default(),
            julia_packages_installed: None,
            backends,
            build_mode: BuildMode::Backend,
            build_selected: 0,
            build_log: LogBuffer::new(5000),
            build_process: ProcessStatus::Idle,
            examples: Vec::new(),
            run_selected: 0,
            run_backend_idx: 0,
            run_log: LogBuffer::new(5000),
            run_process: ProcessStatus::Idle,
            warm_cache: false,
            setup_selected: 0,
            setup_log: LogBuffer::new(5000),
            setup_process: ProcessStatus::Idle,
            test_log: LogBuffer::new(10000),
            test_process: ProcessStatus::Idle,
            creating_scene: false,
            scene_name_input: String::new(),
            show_help: false,
            should_quit: false,
        }
    }

    /// Get backends that can actually run examples (not WASM).
    pub fn runnable_backends(&self) -> Vec<&BackendState> {
        self.backends
            .iter()
            .filter(|b| !matches!(b.backend, Backend::WasmExport))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashSet;

    // ── Platform ──

    #[test]
    fn test_platform_supports_metal() {
        assert!(Platform::MacOS.supports_metal());
        assert!(!Platform::Linux.supports_metal());
        assert!(!Platform::Windows.supports_metal());
    }

    #[test]
    fn test_platform_supports_vulkan() {
        assert!(Platform::Linux.supports_vulkan());
        assert!(Platform::Windows.supports_vulkan());
        assert!(!Platform::MacOS.supports_vulkan());
    }

    #[test]
    fn test_platform_labels() {
        assert_eq!(Platform::Linux.label(), "Linux");
        assert_eq!(Platform::MacOS.label(), "macOS");
        assert_eq!(Platform::Windows.label(), "Windows");
    }

    // ── Backend ──

    #[test]
    fn test_backend_available_on_linux() {
        let backends = Backend::available_on(Platform::Linux);
        assert!(backends.contains(&Backend::OpenGL));
        assert!(backends.contains(&Backend::Vulkan));
        assert!(backends.contains(&Backend::WebGPU));
        assert!(backends.contains(&Backend::WasmExport));
        assert!(!backends.contains(&Backend::Metal));
    }

    #[test]
    fn test_backend_available_on_macos() {
        let backends = Backend::available_on(Platform::MacOS);
        assert!(backends.contains(&Backend::Metal));
        assert!(!backends.contains(&Backend::Vulkan));
    }

    #[test]
    fn test_backend_needs_build() {
        assert!(!Backend::OpenGL.needs_build());
        assert!(!Backend::Vulkan.needs_build());
        assert!(Backend::Metal.needs_build());
        assert!(Backend::WebGPU.needs_build());
        assert!(Backend::WasmExport.needs_build());
    }

    #[test]
    fn test_backend_labels() {
        assert_eq!(Backend::OpenGL.label(), "OpenGL");
        assert_eq!(Backend::Metal.label(), "Metal");
    }

    // ── Tab ──

    #[test]
    fn test_tab_all_count() {
        assert_eq!(Tab::ALL.len(), 5);
    }

    #[test]
    fn test_tab_next_wraps() {
        assert_eq!(Tab::Tests.next(), Tab::Dashboard);
    }

    #[test]
    fn test_tab_prev_wraps() {
        assert_eq!(Tab::Dashboard.prev(), Tab::Tests);
    }

    #[test]
    fn test_tab_next_prev_roundtrip() {
        for tab in Tab::ALL {
            assert_eq!(tab.next().prev(), *tab);
        }
    }

    #[test]
    fn test_tab_indices_unique() {
        let indices: HashSet<usize> = Tab::ALL.iter().map(|t| t.index()).collect();
        assert_eq!(indices.len(), Tab::ALL.len());
    }

    // ── ToolStatus ──

    #[test]
    fn test_tool_status_is_available() {
        let found = ToolStatus::Found {
            version: "1.0".into(),
            path: PathBuf::from("/usr/bin/test"),
        };
        assert!(found.is_available());
        assert!(!ToolStatus::NotFound.is_available());
    }

    // ── LogBuffer ──

    #[test]
    fn test_log_buffer_push() {
        let mut buf = LogBuffer::new(100);
        buf.push("hello".into(), false);
        assert_eq!(buf.lines.len(), 1);
        assert_eq!(buf.lines[0].text, "hello");
    }

    #[test]
    fn test_log_buffer_max_lines_eviction() {
        let mut buf = LogBuffer::new(3);
        buf.push("a".into(), false);
        buf.push("b".into(), false);
        buf.push("c".into(), false);
        buf.push("d".into(), false);
        assert_eq!(buf.lines.len(), 3);
        assert_eq!(buf.lines[0].text, "b");
        assert_eq!(buf.lines[2].text, "d");
    }

    #[test]
    fn test_log_buffer_clear() {
        let mut buf = LogBuffer::new(100);
        buf.push("test".into(), false);
        buf.push("test2".into(), false);
        buf.clear();
        assert_eq!(buf.lines.len(), 0);
        assert_eq!(buf.scroll_offset, 0);
    }

    #[test]
    fn test_log_buffer_scroll_up_disables_auto_scroll() {
        let mut buf = LogBuffer::new(100);
        for i in 0..10 {
            buf.push(format!("line {i}"), false);
        }
        assert!(buf.auto_scroll);
        buf.scroll_up(3);
        assert!(!buf.auto_scroll);
    }

    #[test]
    fn test_log_buffer_scroll_to_top() {
        let mut buf = LogBuffer::new(100);
        for i in 0..10 {
            buf.push(format!("line {i}"), false);
        }
        buf.scroll_to_top();
        assert_eq!(buf.scroll_offset, 0);
        assert!(!buf.auto_scroll);
    }

    #[test]
    fn test_log_buffer_scroll_down_clamps() {
        let mut buf = LogBuffer::new(100);
        buf.push("only line".into(), false);
        buf.scroll_to_top();
        buf.scroll_down(1000);
        assert_eq!(buf.scroll_offset, 0); // Only 1 line, so max offset is 0
        assert!(buf.auto_scroll);
    }

    // ── SetupAction ──

    #[test]
    fn test_setup_action_all_count() {
        assert_eq!(SetupAction::ALL.len(), 7);
    }

    #[test]
    fn test_setup_action_labels_non_empty() {
        for action in SetupAction::ALL {
            assert!(!action.label().is_empty());
        }
    }
}
