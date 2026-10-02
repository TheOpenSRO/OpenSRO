//! The automatic Vulkan -> OpenGL fall back (round 693's review).
//!
//! The client's default renderer is Forward+ (Vulkan). Godot 4.2.2 has no fall back of its own:
//! a machine without a working Vulkan driver gets "Unable to initialize Vulkan video driver" and
//! the game exits (READ, platform/windows/display_server_windows.cpp,
//! DisplayServerWindows::create_func; `rendering_device/fallback_to_opengl3` arrived in 4.3).
//!
//! This runs at the library's Core initialisation (gd.rs, `min_level` Core), which Godot reaches
//! in Main::setup (register_core_extensions, main/main.cpp 1647) BEFORE it reads the renderer
//! (main.cpp 1966) and before any display exists. No Godot API is usable there on 4.2 (the
//! ProjectSettings and Engine singletons are registered later, in setup2), so it does not try to
//! change the setting. It asks the system's Vulkan loader for what Godot's Vulkan start needs --
//! an instance with the surface extensions, and at least one physical device -- and when that
//! fails it starts the game again with `--rendering-driver opengl3` (which selects the
//! Compatibility renderer, main.cpp 1911-1916) and ends this process before Godot gets further.
//!
//! - The loader is opened at run time (dlopen / LoadLibrary), so a machine without one is a
//!   clean "no", not a missing-import failure of this library.
//! - Nothing happens when the command line already names a renderer or a display driver, under
//!   `--headless` / the editor / an export, when SRREVAMP_VK_PROBE is already set (the re-started
//!   child: no loop), or when override.cfg beside the game already chooses gl_compatibility
//!   (Godot then starts on OpenGL by itself).
//! - What it found is left in SRREVAMP_VK_PROBE ("ok <ms>" / "fallback <reason>"), which the
//!   client's Boot logs and RendererChoice reads (a Compatibility start with nothing recorded is
//!   then recorded, so later starts skip the restart).
//! OURS throughout; the Vulkan calls are the API's own (vkCreateInstance,
//! vkEnumeratePhysicalDevices, vkDestroyInstance, through vkGetInstanceProcAddr).

use std::ffi::{c_char, c_void, CString, OsString};
use std::time::Instant;

pub const PROBE_ENV: &str = "SRREVAMP_VK_PROBE";

/// Whether this start should probe at all, from the raw process arguments (Godot's own
/// `OS.get_cmdline_args()` never holds the renderer flags, which Main consumes), the probe
/// variable and override.cfg's text beside the executable ("" when absent).
pub fn should_probe(args: &[String], probe_env: Option<&str>, override_cfg: &str) -> bool {
    if probe_env.is_some() {
        return false;
    }
    for a in args.iter().skip(1) {
        let a = a.as_str();
        if a == "--headless"
            || a == "--editor"
            || a == "-e"
            || a == "--doctool"
            || a.starts_with("--export")
            || a.starts_with("--rendering-driver")
            || a.starts_with("--rendering-method")
            || a.starts_with("--display-driver")
        {
            return false;
        }
    }
    !override_chooses_compatibility(override_cfg)
}

/// The editor and its import runs (gd.rs keeps the library at Scene there).
pub fn editor_or_import(args: &[String]) -> bool {
    args.iter().skip(1).any(|a| {
        let a = a.as_str();
        a == "--editor" || a == "-e" || a == "--import" || a == "--project-manager" || a == "-p" || a.starts_with("--export")
    })
}

/// override.cfg's `renderer/rendering_method="gl_compatibility"` (the file RendererChoice
/// writes; a `;` line is a comment there).
pub fn override_chooses_compatibility(text: &str) -> bool {
    text.lines().any(|l| {
        let l = l.trim();
        !l.starts_with(';')
            && l.starts_with("renderer/rendering_method")
            && !l.starts_with("renderer/rendering_method.")
            && l.contains("gl_compatibility")
    })
}

/// The restart's arguments: this start's, plus the Compatibility driver -- before any `--` or
/// `++`, after which Godot hands the arguments to the game instead of reading them.
pub fn fallback_args(args: &[OsString]) -> Vec<OsString> {
    let mut out: Vec<OsString> = args.iter().skip(1).cloned().collect();
    let at = out.iter().position(|a| a == "--" || a == "++").unwrap_or(out.len());
    out.insert(at, OsString::from("opengl3"));
    out.insert(at, OsString::from("--rendering-driver"));
    out
}

// --- The Vulkan probe -----------------------------------------------------------------------

type VkResult = i32;
type PfnVoid = unsafe extern "system" fn();
type PfnGetInstanceProcAddr = unsafe extern "system" fn(*mut c_void, *const c_char) -> Option<PfnVoid>;
type PfnCreateInstance = unsafe extern "system" fn(*const InstanceCreateInfo, *const c_void, *mut *mut c_void) -> VkResult;
type PfnEnumeratePhysicalDevices = unsafe extern "system" fn(*mut c_void, *mut u32, *mut *mut c_void) -> VkResult;
type PfnDestroyInstance = unsafe extern "system" fn(*mut c_void, *const c_void);

#[repr(C)]
struct ApplicationInfo {
    s_type: u32,
    p_next: *const c_void,
    p_application_name: *const c_char,
    application_version: u32,
    p_engine_name: *const c_char,
    engine_version: u32,
    api_version: u32,
}

#[repr(C)]
struct InstanceCreateInfo {
    s_type: u32,
    p_next: *const c_void,
    flags: u32,
    p_application_info: *const ApplicationInfo,
    enabled_layer_count: u32,
    pp_enabled_layer_names: *const *const c_char,
    enabled_extension_count: u32,
    pp_enabled_extension_names: *const *const c_char,
}

const STRUCTURE_TYPE_APPLICATION_INFO: u32 = 0;
const STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
const API_VERSION_1_0: u32 = 1 << 22;

#[cfg(target_os = "windows")]
const SURFACE_EXTENSION: &str = "VK_KHR_win32_surface";
#[cfg(not(target_os = "windows"))]
const SURFACE_EXTENSION: &str = "VK_KHR_xlib_surface"; // Godot 4.2's X11 display server

#[cfg(target_os = "windows")]
mod dl {
    use std::ffi::c_void;
    #[link(name = "kernel32")]
    extern "system" {
        fn LoadLibraryW(name: *const u16) -> *mut c_void;
        fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
        fn FreeLibrary(module: *mut c_void) -> i32;
    }
    pub const LOADER: &str = "vulkan-1.dll";
    pub unsafe fn open(name: &str) -> *mut c_void {
        let w: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
        LoadLibraryW(w.as_ptr())
    }
    pub unsafe fn sym(h: *mut c_void, name: &[u8]) -> *mut c_void {
        GetProcAddress(h, name.as_ptr())
    }
    pub unsafe fn close(h: *mut c_void) {
        FreeLibrary(h);
    }
}

#[cfg(not(target_os = "windows"))]
mod dl {
    use std::ffi::{c_char, c_int, c_void};
    #[link(name = "dl")]
    extern "C" {
        fn dlopen(name: *const c_char, flags: c_int) -> *mut c_void;
        fn dlsym(h: *mut c_void, name: *const c_char) -> *mut c_void;
        fn dlclose(h: *mut c_void) -> c_int;
    }
    const RTLD_NOW: c_int = 2;
    pub const LOADER: &str = "libvulkan.so.1";
    pub unsafe fn open(name: &str) -> *mut c_void {
        let c = std::ffi::CString::new(name).unwrap();
        dlopen(c.as_ptr(), RTLD_NOW)
    }
    pub unsafe fn sym(h: *mut c_void, name: &[u8]) -> *mut c_void {
        dlsym(h, name.as_ptr() as *const c_char)
    }
    pub unsafe fn close(h: *mut c_void) {
        dlclose(h);
    }
}

/// Ok(physical device count) when Vulkan can start as Godot needs it, Err(why) otherwise.
pub fn probe_vulkan() -> Result<u32, String> {
    unsafe {
        let lib = dl::open(dl::LOADER);
        if lib.is_null() {
            return Err(format!("no Vulkan loader ({})", dl::LOADER));
        }
        let out = probe_with(lib);
        dl::close(lib);
        out
    }
}

unsafe fn probe_with(lib: *mut c_void) -> Result<u32, String> {
    let gipa = dl::sym(lib, b"vkGetInstanceProcAddr\0");
    if gipa.is_null() {
        return Err("the loader has no vkGetInstanceProcAddr".into());
    }
    let gipa: PfnGetInstanceProcAddr = std::mem::transmute(gipa);
    let Some(create) = gipa(std::ptr::null_mut(), b"vkCreateInstance\0".as_ptr() as *const c_char) else {
        return Err("no vkCreateInstance".into());
    };
    let create: PfnCreateInstance = std::mem::transmute(create);
    let app_name = CString::new("srrevamp vulkan probe").unwrap();
    let app = ApplicationInfo {
        s_type: STRUCTURE_TYPE_APPLICATION_INFO,
        p_next: std::ptr::null(),
        p_application_name: app_name.as_ptr(),
        application_version: 1,
        p_engine_name: app_name.as_ptr(),
        engine_version: 1,
        api_version: API_VERSION_1_0,
    };
    let ext_names = [CString::new("VK_KHR_surface").unwrap(), CString::new(SURFACE_EXTENSION).unwrap()];
    let ext_ptrs: Vec<*const c_char> = ext_names.iter().map(|c| c.as_ptr()).collect();
    let info = InstanceCreateInfo {
        s_type: STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        p_next: std::ptr::null(),
        flags: 0,
        p_application_info: &app,
        enabled_layer_count: 0,
        pp_enabled_layer_names: std::ptr::null(),
        enabled_extension_count: ext_ptrs.len() as u32,
        pp_enabled_extension_names: ext_ptrs.as_ptr(),
    };
    let mut instance: *mut c_void = std::ptr::null_mut();
    let r = create(&info, std::ptr::null(), &mut instance);
    if r != 0 || instance.is_null() {
        return Err(format!("vkCreateInstance failed ({r})"));
    }
    let enumerate = gipa(instance, b"vkEnumeratePhysicalDevices\0".as_ptr() as *const c_char);
    let destroy = gipa(instance, b"vkDestroyInstance\0".as_ptr() as *const c_char);
    let mut count: u32 = 0;
    let result = match enumerate {
        Some(f) => {
            let f: PfnEnumeratePhysicalDevices = std::mem::transmute(f);
            let r = f(instance, &mut count, std::ptr::null_mut());
            if r != 0 {
                Err(format!("vkEnumeratePhysicalDevices failed ({r})"))
            } else if count == 0 {
                Err("no Vulkan device".into())
            } else {
                Ok(count)
            }
        }
        None => Err("no vkEnumeratePhysicalDevices".into()),
    };
    if let Some(d) = destroy {
        let d: PfnDestroyInstance = std::mem::transmute(d);
        d(instance, std::ptr::null());
    }
    result
}

// --- The hook -------------------------------------------------------------------------------

#[cfg(target_os = "windows")]
fn end_this_process() -> ! {
    // Nothing of Godot's is torn down: it is half initialised (OURS: no exit handlers run).
    #[link(name = "kernel32")]
    extern "system" {
        fn GetCurrentProcess() -> *mut c_void;
        fn TerminateProcess(p: *mut c_void, code: u32) -> i32;
    }
    unsafe {
        TerminateProcess(GetCurrentProcess(), 0);
    }
    std::process::abort()
}

/// The Core-init hook: probe, and on failure restart on OpenGL. Returns only when this start
/// carries on (Vulkan is there, or nothing was to be done, or the restart could not be made).
pub fn run_at_core_init() {
    let args: Vec<String> = std::env::args().collect();
    let probe_env = std::env::var(PROBE_ENV).ok();
    let exe = std::env::current_exe().ok();
    let override_text = exe
        .as_ref()
        .and_then(|e| e.parent().map(|d| d.join("override.cfg")))
        .and_then(|p| std::fs::read_to_string(p).ok())
        .unwrap_or_default();
    if !should_probe(&args, probe_env.as_deref(), &override_text) {
        return;
    }
    let t0 = Instant::now();
    let result = probe_vulkan();
    let ms = t0.elapsed().as_secs_f64() * 1000.0;
    match result {
        Ok(n) => {
            std::env::set_var(PROBE_ENV, format!("ok {n} device(s) in {ms:.1} ms"));
        }
        Err(why) => {
            let note = format!("fallback to OpenGL: {why} ({ms:.1} ms)");
            eprintln!("srrevamp: Vulkan probe: {note} -- restarting with --rendering-driver opengl3");
            let Some(exe) = exe else { return };
            let raw: Vec<OsString> = std::env::args_os().collect();
            let mut cmd = std::process::Command::new(exe);
            cmd.args(fallback_args(&raw)).env(PROBE_ENV, &note);
            #[cfg(not(target_os = "windows"))]
            {
                use std::os::unix::process::CommandExt;
                // Replaces this process (same PID); returns only on failure.
                let e = cmd.exec();
                eprintln!("srrevamp: Vulkan probe: could not restart ({e}); carrying on");
                std::env::set_var(PROBE_ENV, format!("{note}; restart failed: {e}"));
            }
            #[cfg(target_os = "windows")]
            {
                match cmd.spawn() {
                    Ok(_) => end_this_process(),
                    Err(e) => std::env::set_var(PROBE_ENV, format!("{note}; restart failed: {e}")),
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn probes_a_plain_start() {
        assert!(should_probe(&a(&["srrevamp.exe"]), None, ""));
        assert!(should_probe(&a(&["srrevamp.x86_64", "--verbose"]), None, ""));
    }

    #[test]
    fn leaves_a_named_renderer_or_a_headless_run_alone() {
        for flag in ["--headless", "--rendering-driver", "--rendering-driver=opengl3", "--rendering-method", "--display-driver", "--editor", "-e", "--export-release", "--doctool"] {
            assert!(!should_probe(&a(&["godot", flag, "x"]), None, ""), "{flag}");
        }
    }

    #[test]
    fn the_editor_and_imports_stay_at_scene() {
        assert!(editor_or_import(&a(&["godot", "--headless", "--path", ".", "--import", "--quit"])));
        assert!(editor_or_import(&a(&["godot", "-e"])));
        assert!(editor_or_import(&a(&["godot", "--export-release", "Linux", "x"])));
        assert!(!editor_or_import(&a(&["srrevamp.exe"])));
        assert!(!editor_or_import(&a(&["godot", "--headless", "--script", "res://x.gd"])));
    }

    #[test]
    fn never_loops() {
        assert!(!should_probe(&a(&["srrevamp.exe"]), Some("fallback to OpenGL: x"), ""));
    }

    #[test]
    fn respects_a_recorded_choice() {
        let written = "; Written by SRRevamp (round 693)\n[rendering]\n\nrenderer/rendering_method=\"gl_compatibility\"\n";
        assert!(!should_probe(&a(&["srrevamp.exe"]), None, written));
        assert!(should_probe(&a(&["srrevamp.exe"]), None, "[rendering]\nrenderer/rendering_method=\"forward_plus\"\n"));
        assert!(should_probe(&a(&["srrevamp.exe"]), None, ";renderer/rendering_method=\"gl_compatibility\"\n"));
        assert!(should_probe(&a(&["srrevamp.exe"]), None, "renderer/rendering_method.mobile=\"gl_compatibility\"\n"));
    }

    #[test]
    fn restarts_with_the_same_arguments_and_the_gl_driver() {
        let raw: Vec<OsString> = ["srrevamp.exe", "--verbose", "--", "--x=1"].iter().map(OsString::from).collect();
        let out: Vec<String> = fallback_args(&raw).into_iter().map(|o| o.into_string().unwrap()).collect();
        assert_eq!(out, vec!["--verbose", "--rendering-driver", "opengl3", "--", "--x=1"]);
        let plain: Vec<OsString> = ["srrevamp.exe"].iter().map(OsString::from).collect();
        assert_eq!(fallback_args(&plain), vec![OsString::from("--rendering-driver"), OsString::from("opengl3")]);
    }
}
