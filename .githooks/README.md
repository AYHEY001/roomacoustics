# Git Hooks

## pre-commit

提交前跑两项快速检查：

- `moon check --deny-warn` —— 编译错误和警告
- `moon fmt --check` —— 格式是否符合 `moon fmt` 的结果

不跑 `moon test`。全量测试要几秒，每次提交前都等不合适，而且 CI 在 push 后会跑
完整的 `check` / `fmt` / `test` + CLI 冒烟。这个 hook 的定位是让明显的问题在本地
就被挡下，不是替代 CI。

## 启用

```bash
chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
```

`core.hooksPath` 是**本地仓库配置**，不随仓库分发，所以每个 clone 都要各自设置
一次。设置之前 hook 不会生效（CI 不受影响，它一直在跑自己的那套检查）。

## 前提

需要 `moon` 在 PATH 里。若用隔离安装，先设好环境变量：

```bash
export PATH="/c/Users/admin/.workbuddy/binaries/moonbit-latest/bin:$PATH"
export MOON_HOME="C:/Users/admin/.workbuddy/binaries/moonbit-latest"
```

hook 里做了检查：找不到 `moon` 时会提示并**跳过**（放行提交），而不是让提交
莫名其妙地失败。CI 仍会检查。

## 跳过

```bash
git commit --no-verify
```

不建议。CI 会跑同一套检查，跳过的结果只是把失败推后。
