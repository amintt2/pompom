"""Priorite basse pour les gros calculs de developpement (la machine sert aussi a jouer).

Attention : kernel32.GetCurrentProcess() renvoie la pseudo-poignee (HANDLE)-1 ; sans restype/argtypes, ctypes la
tronque en int 32 bits et SetPriorityClass echoue SANS erreur (processus reste en priorite normale).
"""

from __future__ import annotations

import ctypes
import os

IDLE = 0x40
BELOW_NORMAL = 0x4000


def set_low_priority(idle: bool = False) -> bool:
    """IDLE (entrainement, generation) ou BELOW_NORMAL (mesures). Renvoie True si Windows l'a accepte."""
    if os.name != "nt":
        try:
            os.nice(10)
            return True
        except OSError:
            return False
    k = ctypes.WinDLL("kernel32", use_last_error=True)
    k.GetCurrentProcess.restype = ctypes.c_void_p
    k.SetPriorityClass.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
    k.SetPriorityClass.restype = ctypes.c_int
    return bool(k.SetPriorityClass(k.GetCurrentProcess(), IDLE if idle else BELOW_NORMAL))
