# ========== 阶段 1：构建 ==========
FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY main.go .

# CGO_ENABLED=0 静态编译，避免依赖 libc
RUN CGO_ENABLED=0 go build -o /hello main.go

# ========== 阶段 2：运行 ==========
FROM alpine:3.19

# 加 ca-certificates（如果应用要 HTTPS 请求外部）
RUN apk add --no-cache ca-certificates

WORKDIR /app
COPY --from=builder /hello /hello

EXPOSE 8080
CMD ["/hello"]
