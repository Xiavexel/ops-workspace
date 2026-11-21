#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
import os
import time
import logging
import requests
import json
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

# 1. 配置标准日志（比 Shell 的 echo 更强大）
logging.basicConfig(
    level=logging.INFO,
    format='[%(asctime)s] [%(levelname)s] [%(message)s]',
    datefmt='%Y-%m-%d %H:%M:%S'
)

def build_session():
    """统一出口：显式关闭环境代理。
    requests 默认会读取 http_proxy / https_proxy / ALL_PROXY / no_proxy，
    机器上挂了代理时，连对 127.0.0.1 的探测也会被送去代理 → 全部误报 FAIL。
    trust_env=False 之后，代理、netrc、.env 一律不读，行为才是确定的。"""
    session = requests.Session()
    session.trust_env = False
    session.headers.update({"User-Agent": "ops-api-monitor/1.0"})
    return session

# 需要凭据才能访问的状态码：服务在应答，只是没给钥匙
WARN_AUTH_CODES = (401, 403)

def judge(code):
    """按"可达性"判，而不是"等于 200"。
    巡检只该回答两件事：网络通不通、服务在不在应答；业务对不对不归它管。
    返回 (verdict, note)，verdict ∈ PASS / WARN / FAIL。"""
    if 200 <= code < 400:
        # 2xx 正常；3xx 说明服务在应答（默认 allow_redirects=True 时多为已跟随到终点）
        return "PASS", None
    if code in WARN_AUTH_CODES:
        # 401/403 不是"挂了"，是"要凭证"：必须 PASS，但日志里要显眼，别忘了配鉴权
        return "WARN", "需鉴权"
    return "FAIL", f"状态码 {code}"

def check_service(target, session):
    name = target["name"]
    url = target["url"]
    timeout = target.get("timeout", 3)  # 允许配置缺省，避免字段缺失时直接 KeyError
    max_retries = 3  # 最大重试次数（总共请求 3 次）
    
    for attempt in range(max_retries):
        start_time = time.time()
        try:
            resp = session.get(url, timeout=timeout)
            cost = int((time.time() - start_time) * 1000)
            
            verdict, note = judge(resp.status_code)
            if verdict == "PASS":
                # 可达即通过，不再要求恰好 200
                logging.info(f"PASS {name} | 状态码: {resp.status_code} | 耗时: {cost}ms")
                return True
            if verdict == "WARN":
                # 需鉴权：算成功、不进重试，但用 WARN 让它显眼
                logging.warning(f"WARN {name} | 状态码: {resp.status_code} | {note} | 耗时: {cost}ms")
                return True
            # 其余（5xx、其他 4xx）：记录后允许重试
            logging.warning(f"RETRY {name} | {note} (第 {attempt+1} 次尝试)")
                
        except requests.exceptions.Timeout:
            logging.warning(f"RETRY {name} | 请求超时 (第 {attempt+1} 次尝试)")
        except requests.exceptions.RequestException as e:
            logging.warning(f"RETRY {name} | 网络错误: {e.__class__.__name__} (第 {attempt+1} 次尝试)")

        # 如果没有在 try 里 return True，说明上面失败了
        # 如果还没到最后一次，就睡 1 秒，然后进入下一次循环
        if attempt < max_retries - 1:
            time.sleep(1)
            
    # 循环彻底跑完了还没 return True，说明 3 次全挂了
    logging.error(f"FAIL {name} | 重试 {max_retries} 次均失败")
    return False

def main():
    # 1. 使用 argparse 解析命令行参数
    parser = argparse.ArgumentParser(description="API 并发巡检工具")
    # 默认配置按脚本所在目录解析，而不是当前工作目录：
    # cron / systemd 调用时 CWD 不可控，用相对路径会直接 rc=2 找不到文件
    default_targets = os.path.join(os.path.dirname(os.path.abspath(__file__)), "targets.json")
    parser.add_argument("-f", "--file", default=default_targets, help="指定目标配置文件 (JSON)，不传则用同目录 targets.json")
    args = parser.parse_args()

    # 2. 读取 JSON 文件
    try:
        with open(args.file, 'r', encoding='utf-8') as f:
            targets = json.load(f)
    except FileNotFoundError:
        logging.error(f"配置文件未找到: {args.file}")
        sys.exit(2)
    except json.JSONDecodeError:
        logging.error(f"配置文件格式错误 (不是合法的 JSON): {args.file}")
        sys.exit(2)

    logging.info(f"==== 开始 Python API 并发巡检 (目标数: {len(targets)}) ====")
    fails = 0
    
    # 所有请求共用一个 Session：连接池复用，且 trust_env 只需要在这里设一次
    session = build_session()
    with ThreadPoolExecutor(max_workers=10) as executor:
        # 注意这里，把原来的 TARGETS 换成了从文件读取的 targets
        future_to_target = {executor.submit(check_service, t, session): t for t in targets}
        
        # 【修复】汇总判断必须在循环外
        # 原写法把 `if fails > 0: sys.exit(1)` 写在循环里：第一个目标失败就整体退出，
        # 剩余 future 被丢弃、汇总不完整，也拿不到"到底挂了几个"的结果。
        for future in as_completed(future_to_target):
            if not future.result():
                fails += 1

    if fails > 0:
        logging.error(f"==== 巡检结束: {fails}/{len(targets)} 个目标失败 ====")
        sys.exit(1)

    logging.info(f"==== 巡检结束: 全部 {len(targets)} 个目标正常 ====")

if __name__ == "__main__":
    main()
