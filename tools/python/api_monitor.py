#!/usr/bin/env python3
# -*- coding: utf-8 -*-
import sys
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

def check_service(target):
    name = target["name"]
    url = target["url"]
    timeout = target["timeout"]
    max_retries = 3  # 最大重试次数（总共请求 3 次）
    
    for attempt in range(max_retries):
        start_time = time.time()
        try:
            resp = requests.get(url, timeout=timeout)
            cost = int((time.time() - start_time) * 1000)
            
            if resp.status_code == 200:
                # 成功！直接 return True，退出整个函数，不再重试
                logging.info(f"PASS {name} | 状态码: {resp.status_code} | 耗时: {cost}ms")
                return True
            else:
                # 状态码不对（比如 502），记录错误但也允许重试
                logging.warning(f"RETRY {name} | 状态码异常: {resp.status_code} (第 {attempt+1} 次尝试)")
                
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
    # 添加 -f 参数，如果不传，默认读取同目录下的 targets.json
    parser.add_argument("-f", "--file", default="targets.json", help="指定目标配置文件 (JSON)")
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
    
    with ThreadPoolExecutor(max_workers=10) as executor:
        # 注意这里，把原来的 TARGETS 换成了从文件读取的 targets
        future_to_target = {executor.submit(check_service, t): t for t in targets}
        
        for future in as_completed(future_to_target):
            if not future.result():  
                fails += 1
            if fails > 0: sys.exit(1)

if __name__ == "__main__":
    main()
