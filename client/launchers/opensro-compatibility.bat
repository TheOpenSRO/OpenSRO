@echo off
rem Starts OpenSRO on the Compatibility (OpenGL) renderer. The game already falls back to
rem OpenGL by itself when Vulkan is missing (with its native library next to it); this is
rem for choosing OpenGL by hand, or for a copy without that library.
rem The game remembers the choice (override.cfg beside it), so after this one
rem start OpenSRO.exe opens on Compatibility too. Delete override.cfg, or set
rem display.renderer: forward_plus in setting\config.yaml, to go back to Forward+.
rem Round 760: the default render thread under OpenGL (the separate one crashed Compatibility).
start "" "%~dp0OpenSRO.exe" --rendering-driver opengl3 --render-thread safe %*
