"""Compatibility imports for repokeep users; implementation lives in gearflow."""

from importlib import import_module
import sys

from gearflow import __version__

for _name in (
    "common", "models", "versions", "upstream", "osv", "output", "watch",
    "workers", "task_status", "tasks", "updates", "cli",
):
    _module = import_module(f"gearflow.monitor.{_name}")
    globals()[_name] = _module
    sys.modules[f"{__name__}.{_name}"] = _module

del _name, _module
