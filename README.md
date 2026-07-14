# bufancv probe

bufancv.com 的站外 7×24 生产探针。每 5 分钟从 GitHub Actions(站外视角)探测生产链路,确认故障后发飞书告警。它的核心使命有两个:

1. **服务器整机挂掉时仍有人报警** —— 站内的巡检/冒烟脚本此时已经跟着哑巴了。
2. **击穿缓存检查 CDN 回源** —— 请求必然不存在的随机路径,CDN 无法命中缓存必须回源;404 = 整条链路(DNS → CDN 边缘 → 回源 TLS → 源站 nginx → 上游)全通,502/超时 = 回源断。2026-07-13 的事故(nginx catchall 拒掉 CDN 空 SNI 回源握手)被 CDN 缓存掩盖了 18 小时,常规拨测全绿,只有这种探针能当场发现。

## 探针清单

| 探针 | 期望 | 证明什么 |
|---|---|---|
| `https://bufancv.com/` | 200 + 含品牌串 | web SSR 存活 |
| `https://bufancv.com/api/me`(匿名) | 401/200 | nginx → API server 链路存活(healthz 不对公网暴露;匿名 401 即活着) |
| `https://assets.bufancv.com/_nuxt/<随机>.js` | **404** | assets CDN 回源穿透(502/超时=回源断) |
| `https://cdn.bufancv.com/<随机>` | 404/403 | cdn(OSS 源)回源穿透 |
| 三张证书(主域/assets/cdn) | 剩余 ≥14 天 | 证书不会静默过期 |

## 运行频率与通知

- **probe.yml**:cron 每 5 分钟(GitHub 对公开仓调度有抖动,实际 5-15 分钟一次)。全绿静默。
- **daily-report.yml**:每天 09:00 北京时间发一条 📊 完整体检日报到飞书(每项耗时 + 证书剩余天数/到期日),全绿也发。

## 告警策略(防误报 + 防轰炸)

- 每个探针自带 3 次重试(间隔 15s),吸收单次网络抖动。
- 第一轮失败 → 60s 后整轮复核,**两轮都失败才告警**(GitHub 跑在海外,跨境偶发抖动不该半夜叫人)。
- 故障持续期间只在开头发一条(上一次运行已是 failure 则不重复);恢复时发一条 🟢。

## 密钥

飞书机器人 webhook 存在 Actions secret `FEISHU_WEBHOOK`,仓库内无明文。fork PR 拿不到 secrets。

```bash
gh secret set FEISHU_WEBHOOK --repo <this-repo>   # 值从 stdin 输入
```

## 本地运行

```bash
./probe.sh   # 退出码 0=全绿 1=有失败,输出即告警正文
```

## 维护须知

- **keepalive.yml**:GitHub 会停用公开仓 60 天无 commit 的 scheduled workflow,每月自动打一个空 commit 保活,勿删。
- 加探针:在 `probe.sh` 末尾加一行 `http_probe '名称' '期望码正则' 'url' ['响应体必含']`,推 main 即生效(push 会触发一次运行自测)。
- 这是监控体系的第一层;变更后深度冒烟(Playwright 全流程旅程)在主仓库,见主仓库 `docs/`。
