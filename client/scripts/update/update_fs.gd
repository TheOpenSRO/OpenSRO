extends RefCounted
class_name UpdateFs

## The file operations the update installer uses (round 668), behind one
## object so a test can swap in a filesystem that behaves like Windows
## (update_installer_test.gd's FakeFs) -- a running exe and a loaded DLL that
## can be renamed but not overwritten or deleted, a file held open, a file
## antivirus removed. This is the real one: plain DirAccess/FileAccess.
##
## Godot 4.2.2's DirAccess.rename on Windows (dir_access_windows.cpp:300-307,
## READ) deletes an existing target first and then calls _wrename; renaming
## onto a name that does not exist is a plain _wrename. The installer only
## ever renames onto names it has just made sure do not exist.

func exists(path: String) -> bool:
	return FileAccess.file_exists(path)

func rename(from: String, to: String) -> bool:
	return DirAccess.rename_absolute(from, to) == OK

func remove(path: String) -> bool:
	return DirAccess.remove_absolute(path) == OK

func copy(from: String, to: String) -> bool:
	return DirAccess.copy_absolute(from, to) == OK

func make_dir(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path)

## Unix permission bits, or -1 where there are none (Windows).
func permissions(path: String) -> int:
	if OS.get_name() == "Windows":
		return -1
	return int(FileAccess.get_unix_permissions(path))

func set_permissions(path: String, bits: int) -> void:
	if bits >= 0 and OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(path, bits)

func read_text(path: String) -> String:
	return FileAccess.get_file_as_string(path) if FileAccess.file_exists(path) else ""

func write_text(path: String, text: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(text)
	return true

func sleep_ms(ms: int) -> void:
	OS.delay_msec(ms)
