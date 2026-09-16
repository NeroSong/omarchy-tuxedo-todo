#!/usr/bin/env python3
"""Security boundary for todo.txt and plugin-state file access."""

from __future__ import annotations

import ctypes
import errno
import json
import os
import secrets
import select
import stat
import struct
import sys

TODO_MAX_BYTES = 8 * 1024 * 1024
TODO_MAX_LINE_BYTES = 64 * 1024
STATE_MAX_BYTES = 1 * 1024 * 1024
READ_CHUNK = 64 * 1024

_OPEN_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
_DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class SecureFileError(Exception):
    def __init__(self, code: str):
        super().__init__(code)
        self.code = code


def _map_open_error(error: OSError) -> SecureFileError:
    if error.errno == errno.ELOOP:
        return SecureFileError("SYMLINK")
    if error.errno == errno.ENOENT:
        return SecureFileError("NOT_FOUND")
    if error.errno in (errno.EACCES, errno.EPERM):
        return SecureFileError("ACCESS")
    return SecureFileError("OPEN")


def _validate_regular(st: os.stat_result, max_bytes: int) -> None:
    if not stat.S_ISREG(st.st_mode):
        raise SecureFileError("NOT_REGULAR")
    if st.st_uid != os.getuid():
        raise SecureFileError("WRONG_OWNER")
    if st.st_size > max_bytes:
        raise SecureFileError("TOO_LARGE")


def _bounded_fd_read(fd: int, initial: os.stat_result, max_bytes: int) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        try:
            chunk = os.read(fd, min(READ_CHUNK, max_bytes + 1 - total))
        except BlockingIOError as error:
            raise SecureFileError("CHANGED") from error
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            raise SecureFileError("TOO_LARGE")
    final = os.fstat(fd)
    if final.st_dev != initial.st_dev or final.st_ino != initial.st_ino:
        raise SecureFileError("CHANGED")
    if final.st_size != initial.st_size or total != initial.st_size:
        raise SecureFileError("CHANGED")
    return b"".join(chunks)


def secure_read(path: str, max_bytes: int, *, missing_ok: bool = False) -> bytes:
    try:
        fd = os.open(path, _OPEN_FLAGS)
    except OSError as error:
        if missing_ok and error.errno == errno.ENOENT:
            return b""
        raise _map_open_error(error) from error
    try:
        initial = os.fstat(fd)
        _validate_regular(initial, max_bytes)
        return _bounded_fd_read(fd, initial, max_bytes)
    finally:
        os.close(fd)


def read_todo(path: str) -> bytes:
    return read_task_file(path)


def read_done(path: str) -> bytes:
    return read_task_file(path, missing_ok=True)


def read_task_file(path: str, *, missing_ok: bool = False) -> bytes:
    data = secure_read(path, TODO_MAX_BYTES, missing_ok=missing_ok)
    line_bytes = 0
    for byte in data:
        if byte == 10:
            if line_bytes > TODO_MAX_LINE_BYTES:
                raise SecureFileError("LINE_TOO_LONG")
            line_bytes = 0
        else:
            line_bytes += 1
            if line_bytes > TODO_MAX_LINE_BYTES:
                raise SecureFileError("LINE_TOO_LONG")
    return data


def _open_private_state_dir(state_path: str, *, create: bool) -> tuple[int, str]:
    directory, filename = os.path.split(os.path.abspath(state_path))
    if not filename or filename in (".", ".."):
        raise SecureFileError("BAD_PATH")
    parent, dirname = os.path.split(directory)
    if not dirname:
        raise SecureFileError("BAD_PATH")
    try:
        parent_fd = os.open(parent, _DIR_FLAGS)
    except OSError as error:
        raise _map_open_error(error) from error
    try:
        if create:
            try:
                os.mkdir(dirname, 0o700, dir_fd=parent_fd)
            except FileExistsError:
                pass
        try:
            unresolved = os.stat(dirname, dir_fd=parent_fd, follow_symlinks=False)
        except OSError as error:
            raise _map_open_error(error) from error
        if not stat.S_ISDIR(unresolved.st_mode):
            raise SecureFileError("STATE_DIR_NOT_DIRECTORY")
        try:
            directory_fd = os.open(dirname, _DIR_FLAGS, dir_fd=parent_fd)
        except OSError as error:
            raise _map_open_error(error) from error
    finally:
        os.close(parent_fd)

    try:
        directory_stat = os.fstat(directory_fd)
        if not stat.S_ISDIR(directory_stat.st_mode):
            raise SecureFileError("STATE_DIR_NOT_DIRECTORY")
        if directory_stat.st_uid != os.getuid():
            raise SecureFileError("STATE_DIR_WRONG_OWNER")
        if stat.S_IMODE(directory_stat.st_mode) != 0o700:
            os.fchmod(directory_fd, 0o700)
            if stat.S_IMODE(os.fstat(directory_fd).st_mode) != 0o700:
                raise SecureFileError("STATE_DIR_MODE")
        return directory_fd, filename
    except Exception:
        os.close(directory_fd)
        raise


def _validate_state_file(st: os.stat_result) -> None:
    _validate_regular(st, STATE_MAX_BYTES)
    if stat.S_IMODE(st.st_mode) & ~0o600:
        raise SecureFileError("STATE_FILE_MODE")


def read_state(path: str) -> bytes:
    directory_fd, filename = _open_private_state_dir(path, create=True)
    try:
        try:
            fd = os.open(filename, _OPEN_FLAGS, dir_fd=directory_fd)
        except OSError as error:
            if error.errno == errno.ENOENT:
                return b""
            raise _map_open_error(error) from error
        try:
            initial = os.fstat(fd)
            _validate_state_file(initial)
            return _bounded_fd_read(fd, initial, STATE_MAX_BYTES)
        finally:
            os.close(fd)
    finally:
        os.close(directory_fd)


def write_state(path: str, data: bytes) -> None:
    if len(data) > STATE_MAX_BYTES:
        raise SecureFileError("TOO_LARGE")
    directory_fd, filename = _open_private_state_dir(path, create=True)
    temporary = ".state-" + secrets.token_hex(16) + ".tmp"
    temp_fd = -1
    try:
        try:
            existing_fd = os.open(filename, _OPEN_FLAGS, dir_fd=directory_fd)
        except OSError as error:
            if error.errno != errno.ENOENT:
                raise _map_open_error(error) from error
        else:
            try:
                _validate_state_file(os.fstat(existing_fd))
            finally:
                os.close(existing_fd)

        temp_fd = os.open(
            temporary,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
            0o600,
            dir_fd=directory_fd,
        )
        _validate_state_file(os.fstat(temp_fd))
        offset = 0
        while offset < len(data):
            written = os.write(temp_fd, data[offset:])
            if written <= 0:
                raise SecureFileError("WRITE")
            offset += written
        os.fsync(temp_fd)
        os.close(temp_fd)
        temp_fd = -1
        os.replace(temporary, filename, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    except SecureFileError:
        raise
    except OSError as error:
        raise SecureFileError("WRITE") from error
    finally:
        if temp_fd >= 0:
            os.close(temp_fd)
        try:
            os.unlink(temporary, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        os.close(directory_fd)


def _emit(payload: dict[str, object]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def _decode_utf8(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise SecureFileError("INVALID_UTF8") from error


def watch(path: str) -> None:
    directory, filename = os.path.split(os.path.abspath(path))
    if not filename:
        raise SecureFileError("BAD_PATH")
    libc = ctypes.CDLL(None, use_errno=True)
    init = libc.inotify_init1
    add = libc.inotify_add_watch
    init.argtypes = [ctypes.c_int]
    init.restype = ctypes.c_int
    add.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32]
    add.restype = ctypes.c_int
    inotify_fd = init(os.O_CLOEXEC | os.O_NONBLOCK)
    if inotify_fd < 0:
        raise SecureFileError("WATCH_INIT")
    mask = 0x00000004 | 0x00000008 | 0x00000080 | 0x00000100 | 0x00000200
    try:
        if add(inotify_fd, os.fsencode(directory), mask) < 0:
            raise SecureFileError("WATCH_PARENT")
        event_header = struct.Struct("iIII")
        sys.stdout.write("READY\n")
        sys.stdout.flush()
        while True:
            select.select([inotify_fd], [], [])
            try:
                block = os.read(inotify_fd, 64 * 1024)
            except BlockingIOError:
                continue
            offset = 0
            relevant = False
            while offset + event_header.size <= len(block):
                _, event_mask, _, name_length = event_header.unpack_from(block, offset)
                offset += event_header.size
                name = block[offset:offset + name_length].split(b"\0", 1)[0]
                offset += name_length
                if event_mask & 0x00004000 or os.fsdecode(name) == filename:
                    relevant = True
            if relevant:
                sys.stdout.write("EVENT\n")
                sys.stdout.flush()
    finally:
        os.close(inotify_fd)


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("read-todo", "read-done", "read-state", "write-state", "watch"):
        _emit({"ok": False, "error": "USAGE"})
        return 2
    command, path = argv[1], argv[2]
    try:
        if command == "read-todo":
            _emit({"ok": True, "data": _decode_utf8(read_todo(path))})
        elif command == "read-done":
            _emit({"ok": True, "data": _decode_utf8(read_done(path))})
        elif command == "read-state":
            _emit({"ok": True, "data": _decode_utf8(read_state(path))})
        elif command == "write-state":
            data = sys.stdin.buffer.readline(STATE_MAX_BYTES + 2)
            if len(data) > STATE_MAX_BYTES + 1 or not data.endswith(b"\n"):
                raise SecureFileError("TOO_LARGE")
            write_state(path, data[:-1])
            _emit({"ok": True})
        else:
            watch(path)
        return 0
    except SecureFileError as error:
        _emit({"ok": False, "error": error.code})
        return 1
    except (OSError, ValueError):
        _emit({"ok": False, "error": "INTERNAL"})
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
