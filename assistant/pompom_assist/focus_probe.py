"""Detection du champ de saisie qui a le focus (Windows UI Automation, via comtypes).

Ne lit JAMAIS le contenu d'un champ : seulement sa description (type, nom, id, aide, classe,
libelle associe, processus, titre de fenetre). Les champs mot de passe sont ignores entierement
(on renvoie {"skip": "password"} sans aucun autre detail).

Cout mesure : ~1-4 ms par lecture (une seule requete UIA groupee grace a un CacheRequest).
"""

from __future__ import annotations

import ctypes
import os
import threading
import time
from ctypes import wintypes

# --- UIA ids (UIAutomationClient.h)
P_CONTROL_TYPE = 30003
P_LOCALIZED_TYPE = 30004
P_NAME = 30005
P_KB_FOCUSABLE = 30009
P_AUTOMATION_ID = 30011
P_CLASS_NAME = 30012
P_HELP_TEXT = 30013
P_LABELED_BY = 30018
P_IS_PASSWORD = 30019
P_PROCESS_ID = 30002
P_FRAMEWORK_ID = 30024
P_VALUE_AVAILABLE = 30043
P_VALUE_READONLY = 30046
P_ARIA_ROLE = 30101
P_ARIA_PROPS = 30102

CONTROL_TYPES = {
    50000: "button", 50003: "combobox", 50004: "edit", 50020: "text", 50025: "custom",
    50026: "group", 50030: "document", 50032: "window", 50033: "pane",
}
EDITABLE = {"edit", "document", "combobox"}
MAX_STR = 160

_user32 = ctypes.WinDLL("user32", use_last_error=True)
_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_user32.GetForegroundWindow.restype = wintypes.HWND
_user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
_user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
_kernel32.OpenProcess.restype = wintypes.HANDLE
_kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
_kernel32.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR,
                                                 ctypes.POINTER(wintypes.DWORD)]
_kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def _clip(s) -> str:
    s = " ".join(str(s or "").split())
    return s[:MAX_STR]


def foreground_window() -> tuple[str, int]:
    """(titre, pid) de la fenetre au premier plan."""
    h = _user32.GetForegroundWindow()
    if not h:
        return "", 0
    buf = ctypes.create_unicode_buffer(512)
    _user32.GetWindowTextW(h, buf, 512)
    pid = wintypes.DWORD()
    _user32.GetWindowThreadProcessId(h, ctypes.byref(pid))
    return buf.value, pid.value


_proc_cache: dict[int, str] = {}


def process_name(pid: int) -> str:
    if pid <= 0:
        return ""
    if pid in _proc_cache:
        return _proc_cache[pid]
    name = ""
    h = _kernel32.OpenProcess(0x1000, False, pid)  # PROCESS_QUERY_LIMITED_INFORMATION
    if h:
        try:
            buf = ctypes.create_unicode_buffer(1024)
            n = wintypes.DWORD(1024)
            if _kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                name = os.path.basename(buf.value).lower()
        finally:
            _kernel32.CloseHandle(h)
    if len(_proc_cache) > 256:
        _proc_cache.clear()
    _proc_cache[pid] = name
    return name


class FocusProbe:
    """Lit l'element qui a le focus clavier. A utiliser depuis UN seul thread (COM)."""

    def __init__(self) -> None:
        import comtypes
        import comtypes.client

        try:
            comtypes.CoInitializeEx(comtypes.COINIT_MULTITHREADED)
        except OSError:
            pass  # deja initialise sur ce thread (ex. thread principal : STA) : ca marche aussi
        comtypes.client.GetModule("UIAutomationCore.dll")
        from comtypes.gen import UIAutomationClient as uia  # type: ignore

        self._uia_mod = uia
        self._uia = comtypes.client.CreateObject(uia.CUIAutomation, interface=uia.IUIAutomation)
        req = self._uia.CreateCacheRequest()
        for pid in (P_CONTROL_TYPE, P_LOCALIZED_TYPE, P_NAME, P_AUTOMATION_ID, P_CLASS_NAME, P_HELP_TEXT,
                    P_IS_PASSWORD, P_PROCESS_ID, P_FRAMEWORK_ID, P_VALUE_AVAILABLE, P_VALUE_READONLY,
                    P_ARIA_ROLE, P_ARIA_PROPS, P_LABELED_BY, P_KB_FOCUSABLE):
            req.AddProperty(pid)
        self._req = req
        self.own_pid = os.getpid()
        self.ignore_pids: set[int] = set()

    def snapshot(self) -> dict | None:
        """Description du champ focus, {"skip": raison} si on doit l'ignorer, ou None si erreur."""
        try:
            el = self._uia.GetFocusedElementBuildCache(self._req)
        except Exception:
            return None
        if el is None:
            return None
        g = el.GetCachedPropertyValue
        try:
            if bool(g(P_IS_PASSWORD)):
                return {"skip": "password"}  # rien d'autre : ni nom, ni fenetre
            pid = int(g(P_PROCESS_ID) or 0)
            if pid == self.own_pid or pid in self.ignore_pids:
                return {"skip": "self"}
            ctype = CONTROL_TYPES.get(int(g(P_CONTROL_TYPE) or 0), str(g(P_CONTROL_TYPE)))
            value_ok = bool(g(P_VALUE_AVAILABLE))
            readonly = bool(g(P_VALUE_READONLY)) if value_ok else False
            editable = (ctype in EDITABLE or value_ok) and not readonly
            if not editable:
                return {"skip": "not_editable", "control_type": ctype}
            label = ""
            try:
                lb = g(P_LABELED_BY)
                if lb is not None:
                    lb = lb.QueryInterface(self._uia_mod.IUIAutomationElement)
                    label = lb.CurrentName
            except Exception:
                label = ""
            title, _fg_pid = foreground_window()
            return {
                "control_type": ctype,
                "localized_type": _clip(g(P_LOCALIZED_TYPE)),
                "name": _clip(g(P_NAME)),
                "automation_id": _clip(g(P_AUTOMATION_ID)),
                "class_name": _clip(g(P_CLASS_NAME)),
                "help_text": _clip(g(P_HELP_TEXT)),
                "label": _clip(label),
                "framework": _clip(g(P_FRAMEWORK_ID)),
                "aria_role": _clip(g(P_ARIA_ROLE)),
                "aria_properties": _clip(g(P_ARIA_PROPS)),
                "is_password": False,
                "process": process_name(pid),
                "window_title": _clip(title),
            }
        except Exception:
            return None


class FocusWatcher(threading.Thread):
    """Interroge le focus a intervalle regulier ; garde le dernier champ et un numero de version."""

    def __init__(self, interval: float = 0.25) -> None:
        super().__init__(name="focus-watcher", daemon=True)
        self.interval = interval
        self.lock = threading.Lock()
        self.seq = 0
        self.current: dict | None = None
        self.read_ms = 0.0
        self.error = ""
        self._stop = threading.Event()
        self.ignore_pids: set[int] = set()

    def run(self) -> None:
        try:
            probe = FocusProbe()
        except Exception as exc:  # pas d'UIA (ex. session sans bureau)
            self.error = f"uia: {exc}"
            return
        last_key = None
        while not self._stop.is_set():
            probe.ignore_pids = self.ignore_pids
            t0 = time.perf_counter()
            snap = probe.snapshot()
            self.read_ms = (time.perf_counter() - t0) * 1000.0
            if snap is not None:
                key = tuple(sorted((k, str(v)) for k, v in snap.items()))
                if key != last_key:
                    last_key = key
                    with self.lock:
                        self.seq += 1
                        self.current = dict(snap, seq=self.seq, at=time.time())
            self._stop.wait(self.interval)

    def stop(self) -> None:
        self._stop.set()

    def get(self) -> dict:
        with self.lock:
            return dict(self.current or {"seq": 0, "skip": "none"})


if __name__ == "__main__":  # diagnostic : python -m pompom_assist.focus_probe
    import json

    p = FocusProbe()
    for _ in range(20):
        t0 = time.perf_counter()
        s = p.snapshot()
        print(f"{(time.perf_counter() - t0) * 1000:.1f} ms", json.dumps(s, ensure_ascii=False))
        time.sleep(1.0)
