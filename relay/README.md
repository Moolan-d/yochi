# Yochi Relay

手机不在 tailnet 上时，Yochi App 经这个中继连到 Mac 上的 Gateway。Gateway 主动外连中继，不需要开放入站端口。App 与 Gateway 之间用 Noise 端到端加密（ADR 0006），中继只转发密文。

fork 自 [Alma Relay](https://github.com/yetone/alma-relay)（MIT，见 `LICENSE`），只留下 WebSocket 隧道。协议见 [PROTOCOL.md](PROTOCOL.md)。

## 部署

一般用 `yochi relay setup` 部署：它用你自己的 Cloudflare 账号部署 Worker 版（需要 Node.js，第一次会让你在浏览器里登录），生成注册密钥，再让 Gateway 连上去。`*.workers.dev` 在部分网络下打不开，可以用 `--domain relay.example.com` 挂到你在 Cloudflare 上的域名，DNS 记录和证书由 Cloudflare 自动建。之后 `yochi relay rotate` 可以换一个路由 token，旧的配对链接随之失效。

也可以手动部署，有两种方式：

- **Cloudflare Workers**（免费套餐可用）：

  ```bash
  npm install
  npx wrangler secret put RELAY_REGISTRATION_KEY
  npx wrangler deploy
  ```

- **Docker + Caddy**（自动 HTTPS）：

  ```bash
  cp .env.example .env    # 填 RELAY_DOMAIN 和 RELAY_REGISTRATION_KEY
  docker compose up -d
  ```

部署后，把中继地址和注册密钥写进 Gateway 的配置。

## 测试

```bash
npm test                  # Node 版
npm run test:cloudflare   # Cloudflare 版（wrangler dev --local）
```
