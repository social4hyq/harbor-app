declare const daemonBridge: {
  // 通用拉起外部 ELF：spawn(binPath, argsJson, logPath, pidfile, envJson?)
  // argsJson 为 JSON 字符串数组，如 '["-d","/path"]'
  // envJson 可选，为 JSON 对象如 '{"HOME":"/storage/Users/currentUser","PATH":"..."}'，注入环境变量
  // 返回 1=已启动，0=已在运行（pidfile 去重）
  spawn(binPath: string, argsJson: string, logPath: string, pidfile: string, envJson?: string): number;
  // 读 pidfile 并返回存活的 pid，进程已死或文件无效返回 0
  pidFromPidfile(pidfile: string): number;
  // 向 pid 发信号（SIGTERM=15, SIGKILL=9），返回 0=成功 -1=失败
  killPid(pid: number, signal: number): number;
  // kill 后轮询等待进程真正退出（解决 SIGTERM 异步竞态），返回 0=已退出 -1=超时
  killAndWait(pid: number, signal: number, timeoutMs: number): number;
  // pidfile 文件是否存在（1=存在，0=不存在），用于区分 stopped/none 状态
  pidfileExists(pidfile: string): number;
  // 扫描 dir 下所有 *.pid，删除不在 keepJson（服务名数组）里的残留，返回删除个数
  cleanupPidfiles(dir: string, keepJson: string): number;
};

export default daemonBridge;
