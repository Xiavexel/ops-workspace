#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import time
import logging
import json
import argparse
import paramiko
from concurrent.futures import ThreadPoolExecutor, as_completed

logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] [%(message)s]',
    datefmt='%Y-%m-%d %H:%M:%S'
)

EXEC_TIMEOUT = 10  # 远端命令执行超时（秒）：不加超时，一条卡死的命令会永久占住一个 worker

def run_ssh(host_info):
    """执行 SSH 远程命令的核心函数"""
    host = host_info["host"]
    port = host_info.get("port", 22)
    user = host_info["user"]
    password = host_info.get("password")
    key_file = host_info.get("key_file")   # 优先用密钥：配置了 key_file 就不再走密码
    command = host_info["command"]

    # 初始化 SSH 客户端
    ssh = paramiko.SSHClient()
    # 注意：AutoAddPolicy 只适合内网实验环境。
    # 生产应改为 RejectPolicy，并先用 ssh-keyscan <host> >> ~/.ssh/known_hosts 预置指纹。
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        connect_kwargs = dict(
            hostname=host, port=port, username=user,
            timeout=3, banner_timeout=10, auth_timeout=10,
        )
        if key_file:
            connect_kwargs["key_filename"] = key_file
        else:
            connect_kwargs["password"] = password
        ssh.connect(**connect_kwargs)

        # 【修复】exec_command 必须带 timeout，否则远端 hang 住会永久阻塞线程
        stdin, stdout, stderr = ssh.exec_command(command, timeout=EXEC_TIMEOUT)
        # 【修复】成败以退出码为准，而不是"stderr 有没有输出"
        # 很多正常命令（如 find 的权限告警、systemctl 的提示）也会写 stderr
        exit_status = stdout.channel.recv_exit_status()
        output = stdout.read().decode('utf-8', 'replace').strip()
        error = stderr.read().decode('utf-8', 'replace').strip()

        if exit_status != 0:
            detail = error or output or "(无输出)"
            return {"status": "FAIL", "host": host,
                    "msg": f"exit={exit_status} | {detail}"}
        return {"status": "PASS", "host": host, "msg": output}

    except paramiko.AuthenticationException:
        return {"status": "FAIL", "host": host, "msg": "认证失败(密码/密钥错误)"}
    except Exception as e:
        return {"status": "FAIL", "host": host, "msg": f"{e.__class__.__name__}: {e}"}
    finally:
        ssh.close()

def main():
    parser = argparse.ArgumentParser(description="并发 SSH 巡检工具")
    parser.add_argument("-f", "--file", default="hosts.json", help="主机配置文件")
    args = parser.parse_args()

    try:
        with open(args.file, 'r', encoding='utf-8') as f:
            hosts = json.load(f)
    except Exception as e:
        logging.error(f"读取配置失败: {e}")
        sys.exit(2)

    logging.info(f"==== 开始并发 SSH 执行，共 {len(hosts)} 台机器 ====")
    results = []
    fails = 0

    # 利用线程池并发执行
    with ThreadPoolExecutor(max_workers=10) as executor:
        future_to_host = {executor.submit(run_ssh, h): h for h in hosts}
        
        for future in as_completed(future_to_host):
            res = future.result()
            results.append(res)
            if res["status"] == "FAIL":
                fails += 1

    # 格式化表格输出
    print("\n" + "="*60)
    print(f"{'状态':<6} | {'主机':<15} | {'执行结果/错误原因'}")
    print("-" * 60)
    for r in results:
        # 如果输出太长(比如 df -h 有多行)，我们可以取第一行，或者直接替换换行符显示
        display_msg = r['msg'].replace('\n', ' | ')
        print(f"{r['status']:<6} | {r['host']:<15} | {display_msg}")
    print("="*60 + "\n")

    if fails > 0:
        logging.error(f"==== 执行结束: {fails} 台机器操作失败 ====")
        sys.exit(1)
    else:
        logging.info("==== 执行结束: 全部成功 ====")
        sys.exit(0)

if __name__ == "__main__":
    main()
