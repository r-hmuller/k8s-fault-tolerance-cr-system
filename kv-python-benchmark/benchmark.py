import asyncio
from collections import defaultdict
import datetime
import os
import sys
from random import choice, randint
from string import ascii_lowercase
import time

import aiohttp
import requests as requests_sync


def execute(time_to_run, url, file_to_save, main_thread, main_client, debug, thinking_time, store_to_file,
            read_from_file, requests_file):
    asyncio.run(_execute_async(time_to_run, url, file_to_save, main_thread, main_client, debug, thinking_time,
                               store_to_file, read_from_file, requests_file))


async def _execute_async(time_to_run, url, file_to_save, main_thread, main_client, debug, thinking_time,
                         store_to_file, read_from_file, requests_file):
    endTime = datetime.datetime.now() + datetime.timedelta(seconds=time_to_run)
    timeout = aiohttp.ClientTimeout(total=240)
    # Default TCPConnector caps at 100 connections per session, which silently
    # throttles the loop once 100 requests are in-flight. The point of this
    # benchmark is to saturate the server, so the client must not be the
    # throttle — uncap both totals.
    connector = aiohttp.TCPConnector(limit=0, limit_per_host=0)
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        if read_from_file:
            if main_thread and main_client:
                await reproduce_requests_main_thread(requests_file, session, url, debug, {})
            else:
                await reproduce_requests_secondaries_threads(requests_file, session, url)
            return

        if main_thread and main_client:
            print("Starting test")
            r = requests_sync.post(url=f"{url}/testing", json={'action': 'start'})
            print(f"Status: {r.status_code}")

        latencies = {}
        status_counts = defaultdict(int)
        # Only track CURRENTLY in-flight tasks; remove via done-callback. The
        # old design appended every fired task to a list that grew to ~30k
        # zombie wrappers per process over a 300s run.
        in_flight = set()

        def _on_done(task):
            in_flight.discard(task)

        while datetime.datetime.now() < endTime:
            selected_key = randint(0, 1_000_000)
            new_value = "".join(choice(ascii_lowercase) for _ in range(1024))
            task = asyncio.create_task(
                _fire_one(session=session, url=url, key=selected_key, value=new_value,
                          debug=debug, latencies=latencies, status_counts=status_counts))
            in_flight.add(task)
            task.add_done_callback(_on_done)
            if store_to_file:
                save_to_file(file=requests_file, key=selected_key, value=new_value)
            await asyncio.sleep(thinking_time)

        if in_flight:
            await asyncio.gather(*in_flight, return_exceptions=True)

        print_status_counts(status_counts)

        if main_thread and main_client:
            arguments = sys.argv[1:]
            print("Finishing test")
            r = requests_sync.post(url=f"{url}/testing",
                                   json={'action': 'stop',
                                         'path': f"/data/{arguments[1]}_clients_{arguments[0]}_threads.log"
                                         })
            print(f"Status: {r.status_code}")
            if r.status_code != 204:
                print(r.content)

        # Per-PID output so every process contributes latencies without
        # clobbering siblings on the same host. The orchestrator concatenates
        # *.pid* across all hosts to compute real throughput.
        out_path = f"{file_to_save}.pid{os.getpid()}"
        with open(out_path, 'w') as f:
            f.write('--- Status Counts ---\n')
            for status, count in sorted(status_counts.items(), key=lambda x: str(x[0])):
                f.write('%s,%s\n' % (status, count))
            f.write('--- Latencies ---\n')
            for key, value in latencies.items():
                # (latência, status): permite filtrar 204 vs erros nos plots de
                # timeline. Consumidores antigos leem só os 2 primeiros campos.
                if isinstance(value, tuple):
                    f.write('%s,%s,%s\n' % (key, value[0], value[1]))
                else:
                    f.write('%s,%s\n' % (key, value))


async def _fire_one(session, url, key, value, debug, latencies, status_counts):
    """One POST; logs latency for every request (no random main/secondary split)."""
    start_time = time.time()
    try:
        async with session.post(url=url, data={'key': key, 'value': value}) as r:
            status_counts[r.status] += 1
            if debug:
                print("Debugging request")
                print(r.status)
                print(await r.read())
        end_time = time.time()
        latencies[start_time] = (end_time - start_time, r.status)
    except Exception as e:
        status_counts["error"] += 1
        if debug:
            print(f"Request error: {e}")


async def reproduce_requests_main_thread(file, session, url, debug, latencies):
    status_counts = defaultdict(int)
    lines = get_file_content(file)
    tasks = []
    for line in lines:
        splitted_line = line.split(';')
        if randint(0, 50) == 22:
            task = asyncio.create_task(
                _reproduce_single_main(session, url, splitted_line, debug, latencies, status_counts))
            tasks.append(task)
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    print_status_counts(status_counts)


async def _reproduce_single_main(session, url, splitted_line, debug, latencies, status_counts):
    start_time = time.time()
    try:
        async with session.post(url=url, data={'key': splitted_line[0], 'value': splitted_line[1]}) as r:
            status_counts[r.status] += 1
            if debug is True:
                print("Debugging request")
                print(r.status)
                print(await r.read())
        end_time = time.time()
        latency = end_time - start_time
        latencies[start_time] = latency
    except Exception as e:
        status_counts["error"] += 1
        print(f"Request error: {e}")


async def reproduce_requests_secondaries_threads(file, session, url):
    status_counts = defaultdict(int)
    lines = get_file_content(file)
    tasks = []
    for line in lines:
        splitted_line = line.split(';')
        task = asyncio.create_task(
            _fire_one(session=session, url=url, key=splitted_line[0], value=splitted_line[1],
                      debug=False, latencies={}, status_counts=status_counts))
        tasks.append(task)
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
    print_status_counts(status_counts)


def print_status_counts(status_counts):
    parts = [f"{status}: {count}" for status, count in sorted(status_counts.items(), key=lambda x: str(x[0]))]
    print("Status counts - " + " | ".join(parts))


def save_to_file(file, key, value):
    with open(file, 'a') as f:
        f.write('%s;%s\n' % (key, value))


def get_file_content(file):
    with open(file) as f:
        return f.readlines()
