#!/usr/bin/env python3
"""harbor 清理逻辑单测（TDD）。

对齐业界做法：brew services cleanup 以「后端 unit 文件是否还在磁盘」为权威信号，
仅清理 brew 管理的服务（opt/ 路径），对不归它管的保守跳过；检测与清理分离。

运行：python3 test_harbor_clean.py
"""
import importlib.util
import json
import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from unittest import mock

# harbor 脚本无 .py 后缀，用 SourceFileLoader 显式加载为模块
_spec = importlib.util.spec_from_loader(
    "harbor", SourceFileLoader("harbor", os.path.join(os.path.dirname(__file__), "harbor")))
harbor = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(harbor)


class TestStaleBrewApps(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.opt = os.path.join(self.tmp.name, "opt")
        # 所有用例都把判据根指向临时目录，避免依赖真实 ~/.harmonybrew/opt
        self.brew_patch = mock.patch.object(harbor, "BREW_OPT", self.opt)
        self.brew_patch.start()
        self.addCleanup(self.brew_patch.stop)

    def _unit(self, formula: str, exists: bool = True) -> str:
        path = os.path.join(self.opt, formula, f"sh.brew.{formula}.service")
        if exists:
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "w", encoding="utf-8") as f:
                f.write("[Service]\nExecStart=/bin/true\n")
        return path

    def _cfg(self, apps):
        return {"apps": apps, "autoHideOnLaunch": True}

    # --- 判据：brew 管理的 unit ---
    def test_stale_brew_unit_detected(self):
        """brew 管理的 unit 文件消失 -> 判定失效。"""
        missing = self._unit("herdr-app", exists=False)
        cfg = self._cfg([{"name": "herdr-app", "type": "unit", "unit": missing,
                          "pidfile": "/data/cache/harbor/herdr-app.pid"}])
        stale = harbor.find_stale_brew_apps(cfg)
        self.assertEqual([a["name"] for a in stale], ["herdr-app"])

    def test_existing_brew_unit_not_stale(self):
        """unit 文件还在 -> 不是失效项。"""
        present = self._unit("mihomo", exists=True)
        cfg = self._cfg([{"name": "mihomo", "type": "unit", "unit": present,
                          "pidfile": "/data/cache/harbor/mihomo.pid"}])
        self.assertEqual(harbor.find_stale_brew_apps(cfg), [])

    def test_manual_unit_not_touched(self):
        """手工 unit（非 opt/ 路径）即使文件不在，也不归 brew 清理 -> 跳过。"""
        cfg = self._cfg([{"name": "magpie", "type": "unit",
                          "unit": "/storage/Users/currentUser/.config/daemonbox/units/magpie.service",
                          "pidfile": "/data/cache/harbor/magpie.pid"}])
        self.assertEqual(harbor.find_stale_brew_apps(cfg), [])

    def test_exec_type_not_touched(self):
        """type:exec 不是 brew unit -> 跳过。"""
        cfg = self._cfg([{"name": "mihomo-up-script", "type": "exec",
                          "bin": "/some/bin", "pidfile": "/data/cache/harbor/x.pid"}])
        self.assertEqual(harbor.find_stale_brew_apps(cfg), [])

    def test_disabled_still_detected_as_stale(self):
        """已 enabled:false 的失效项仍算失效（供 cleanup 彻底移除）。"""
        missing = self._unit("herdr-app", exists=False)
        cfg = self._cfg([{"name": "herdr-app", "type": "unit", "unit": missing,
                          "enabled": False, "pidfile": "/data/cache/harbor/herdr-app.pid"}])
        self.assertEqual([a["name"] for a in harbor.find_stale_brew_apps(cfg)], ["herdr-app"])

    def test_brew_opt_path_uses_configured_opt_root(self):
        """判据基于传入的 opt 根路径（注入点），不硬编码绝对地址。"""
        with mock.patch.object(harbor, "BREW_OPT", self.opt):
            missing = self._unit("herdr-app", exists=False)
            cfg = self._cfg([{"name": "herdr-app", "type": "unit", "unit": missing,
                              "pidfile": "/data/cache/harbor/herdr-app.pid"}])
            self.assertEqual([a["name"] for a in harbor.find_stale_brew_apps(cfg)], ["herdr-app"])

    # --- 清理：显式 cleanup（硬删，对齐 brew rm），可逆性靠提示 + discover 重装 ---
    def test_cleanup_prune_removes_stale(self):
        """cleanup --prune 从 apps.json 移除失效项，保留其他配置。"""
        missing = self._unit("herdr-app", exists=False)
        present = self._unit("mihomo", exists=True)
        cfg = self._cfg([
            {"name": "herdr-app", "type": "unit", "unit": missing,
             "pidfile": "/data/cache/harbor/herdr-app.pid"},
            {"name": "mihomo", "type": "unit", "unit": present,
             "pidfile": "/data/cache/harbor/mihomo.pid"},
        ])
        with mock.patch.object(harbor, "BREW_OPT", self.opt):
            kept = harbor.prune_stale_brew_apps(cfg)
        self.assertEqual([a["name"] for a in kept], ["mihomo"])
        self.assertTrue(kept[0] is cfg["apps"][1])

    def test_cleanup_prune_is_idempotent(self):
        """无失效项时清理为空操作。"""
        present = self._unit("mihomo", exists=True)
        cfg = self._cfg([{"name": "mihomo", "type": "unit", "unit": present,
                          "pidfile": "/data/cache/harbor/mihomo.pid"}])
        with mock.patch.object(harbor, "BREW_OPT", self.opt):
            kept = harbor.prune_stale_brew_apps(cfg)
        self.assertEqual([a["name"] for a in kept], ["mihomo"])

    def test_cleanup_default_soft_disable(self):
        """harbor cleanup 默认软禁用（enabled:false），可逆；--prune 才硬删。"""
        missing = self._unit("herdr-app", exists=False)
        cfg = self._cfg([{"name": "herdr-app", "type": "unit", "unit": missing,
                          "pidfile": "/data/cache/harbor/herdr-app.pid"}])
        with mock.patch.object(harbor, "BREW_OPT", self.opt):
            disabled = harbor.disable_stale_brew_apps(cfg)
        self.assertEqual(disabled, ["herdr-app"])
        self.assertFalse(cfg["apps"][0]["enabled"])

    def test_soft_disable_then_prune_idempotent(self):
        """先软禁用再 --prune，幂等且最终清除条目。"""
        missing = self._unit("herdr-app", exists=False)
        cfg = self._cfg([{"name": "herdr-app", "type": "unit", "unit": missing,
                          "enabled": False, "pidfile": "/data/cache/harbor/herdr-app.pid"}])
        with mock.patch.object(harbor, "BREW_OPT", self.opt):
            disabled = harbor.disable_stale_brew_apps(cfg)
        self.assertEqual(disabled, [])  # 已禁用，无需再次禁用
        kept = harbor.prune_stale_brew_apps(cfg)
        self.assertEqual(kept, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
