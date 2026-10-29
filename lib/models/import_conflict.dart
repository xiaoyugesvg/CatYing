/// 本地源（Python）导入时，遇到**同名**条目的处理方式。
///
/// 历史行为是"静默自动改名"（`名字 (2)`），用户 2026-10-28 要求改成
/// **让他自己选**：替换还是重命名。
///
/// 放在 models 层（而不是页面里）是因为 service 要用它分支：
/// `LocalPythonSources.importCode` 按它处理同名导入。
enum ImportConflict {
  /// 自动改名：`名字 (2)`、`名字 (3)`…（原来的默认行为）
  rename,

  /// 覆盖同名源：**沿用旧 key**，只替换脚本内容。
  ///
  /// 沿用 key 是刻意的 —— 文件路径 `<Documents>/local_py|local_js/<key>.py|js`
  /// 不变，已选中的源（`ApiConfig` 里存的是 key）、分组顺序、使用次数
  /// 全部保持，用户看到的就是"这个源更新了"。
  replace,
}
