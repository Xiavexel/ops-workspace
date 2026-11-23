# Linux 生产环境实战：Nginx 核心配置与排障

Nginx 在生产环境中承担着反向代理、负载均衡、HTTPS 终结以及限流防刷的核心网关作用。配置文件应遵循规范，避免直接修改主配置，应在 `/etc/nginx/conf.d/` 目录下建立独立的 `.conf` 文件。

> **修改配置的黄金流程**：每次修改 `.conf` 后，先执行 `sudo nginx -t` 校验语法，再执行 `sudo systemctl reload nginx` 平滑重载——切勿直接 `restart` 造成连接中断。

> **返回总览**：[00-linux-ops-overview.md](00-linux-ops-overview.md)

---

## 1. 反向代理与真实 IP 传递

**核心目的**：将外部请求转发给后端的真实业务程序。

### 核心配置

```nginx
server {
    listen 80;
    server_name proxy.test.com;

    location / {
        proxy_pass http://127.0.0.1:8080;

        # 传递客户端真实 IP，否则后端只能看到 Nginx 的 IP
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
```

### 故障解决方案

- **现象**：后端返回 502 Bad Gateway。
- **原因**：Nginx 无法连接到 `proxy_pass` 指定的后端服务。
- **解决**：检查后端程序是否存活，后端端口是否被防火墙拦截，或者使用 `curl 127.0.0.1:端口` 测试后端是否正常响应。

---

## 2. 负载均衡配置

**核心目的**：将流量按照权重分发给多台后端服务器。

### 核心配置

```nginx
# 定义后端服务器池
upstream my_backend_pool {
    server 127.0.0.1:8080 weight=3; # 权重3，承担3/4流量
    server 127.0.0.1:8081 weight=1; # 权重1，承担1/4流量
}

server {
    listen 80;
    server_name balance.test.com;

    location / {
        proxy_pass http://my_backend_pool;
    }
}
```

---

## 3. HTTPS 安全加密配置

**核心目的**：全站加密，保障数据传输安全。

### 核心配置

```nginx
server {
    listen 443 ssl;
    server_name secure.test.com;

    # 生产环境需向 CA 申请证书，测试环境可用 openssl 生成自签证书
    ssl_certificate /etc/nginx/ssl/nginx.crt;
    ssl_certificate_key /etc/nginx/ssl/nginx.key;

    # 安全加固：禁用老旧协议
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

---

## 4. 限流防刷（Rate Limiting）

**核心目的**：限制客户端请求频率，防止恶意攻击或爬虫导致后端崩溃。

### 核心配置

**第一步**：在全局主配置 `nginx.conf` 的 `http {}` 块内定义限流区。

```nginx
# 按客户端 IP 区分，分配 10M 内存，每秒允许 5 次请求
limit_req_zone $binary_remote_addr zone=my_limit:10m rate=5r/s;
```

**第二步**：在业务 server 块中应用限流规则。

```nginx
server {
    listen 80;
    listen [::]:80;  # 必须加上 IPv6 监听，否则 localhost 请求可能被默认页面截胡
    server_name limit.test.com;

    location / {
        # 引用限流区，允许突发 3 个请求，超出直接返回 503
        limit_req zone=my_limit burst=3 nodelay;

        # 必须是实际的后端或静态文件访问
        proxy_pass http://my_backend_pool;
    }
}
```

---

## 5. 常见故障解决方案（Nginx 排障坑合集）

### 现象一：配置了 `server_name`，但 curl 依然返回默认欢迎页

- **原因 1（IPv6 截胡）**：系统默认配置监听了 `[::]:80`，而你的 server 块只写了 `listen 80;`。终端用 localhost 时会优先走 IPv6。
  - **解决方案**：加上 `listen [::]:80;`。
- **原因 2（默认配置抢占）**：主配置或自带文件中有 `default_server` 截获了所有未匹配流量。
  - **解决方案**：注释掉主配置里的默认 server 块。

### 现象二：配置了限流，但用 ab 压测全返回 200，没有 503

- **原因 1（短路执行）**：如果在 `location` 里使用了 `return 200 "xxx";`，Nginx 在 REWRITE 阶段就直接返回了，根本不会进入限流模块所在的 PREACCESS 阶段。
  - **解决方案**：移除 `return` 指令，改为访问真实的文件或反向代理。
- **原因 2（测试工具太弱）**：`for` 循环串行执行请求太慢，未触发限流算法。
  - **解决方案**：需使用 `ab -n 50 -c 10` 或 `wrk` 进行真实并发压测。

### 现象三：反向代理返回 404

- **原因**：`proxy_pass` 结尾有没有 `/` 决定了 URI 是否被剥离。`proxy_pass http://api:5000;`（无斜杠）会把完整 URI（如 `/api/user`）原样转发给后端；若后端路由本身没有 `/api` 前缀，就会 404。
- **解决方案**：若后端服务不带前缀，配置 `proxy_pass http://api:5000/;`（**带斜杠**），Nginx 会把 location 匹配到的前缀剥离后再转发。

---

## 6. 生产视角推演：网关性能与安全加固
- **隐藏版本号**：在 `nginx.conf` 的 `http` 块中添加 `server_tokens off;`，防止攻击者通过报错页面获取 Nginx 具体版本，降低被针对性攻击的风险。
- **SSL 会话复用**：在 HTTPS 配置中开启 `ssl_session_cache shared:SSL:10m;` 和 `ssl_session_timeout 10m;`，大幅降低频繁握手的 CPU 消耗。
