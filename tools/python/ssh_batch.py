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

def run_ssh(host_info):
    """执行 SSH 远程命令的核心函数"""
    host = host_info["host"]
    port = host_info.get("port", 22)
    user = host_info["user"]
    password = host_info["password"]
    command = host_info["command"]
    
    # 初始化 SSH 客户端
    ssh = paramiko.SSHClient()
    # 生产环境千万别用这个，这里为了实验方便，自动接受未知的主机指纹
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        # 连接超时设 3 秒
        ssh.connect(hostname=host, port=port, username=user, password=password, timeout=3)
        # 执行命令
        stdin, stdout, stderr = ssh.exec_command(command)
        # 读取结果并转码
        output = stdout.read().decode('utf-8').strip()
        error = stderr.read().decode('utf-8').strip()
        
        if error:
            return {"status": "FAIL", "host": host, "msg": error}
        return {"status": "PASS", "host": host, "msg": output}
        
    except paramiko.AuthenticationException:
        return {"status": "FAIL", "host": host, "msg": "认证失败(密码错误)"}
    except Exception as e:
        return {"status": "FAIL", "host": host, "msg": str(e)}
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
