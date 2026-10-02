@echo off
rem Starts SRRevamp on the Compatibility (OpenGL) renderer, for a PC without Vulkan.
rem The game remembers the choice (override.cfg beside it), so after this one
rem start srrevamp.exe opens on Compatibility too. Delete override.cfg, or set
rem display.renderer: forward_plus in setting\config.yaml, to go back to Forward+.
start "" "%~dp0srrevamp.exe" --rendering-driver opengl3 %*
