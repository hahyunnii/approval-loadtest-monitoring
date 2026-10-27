#!/usr/bin/env python3
"""부하 테스트 결과 정리 (부하 발생기에서 run-test.sh, fail-test.sh가 호출한다)

  python3 report.py split    <summary.json>
      → 서버별 처리 건수와 비율 (부하가 고르게 나눠졌나)

  python3 report.py failover <k6.csv.gz> <events.json> <out.json>
      → 서버를 멈춘 뒤 ALB가 알아채기까지 걸린 시간, 그동안 실패한 요청 수
"""
import csv
import gzip
import json
import sys


def split(summary_path):
    metrics = json.load(open(summary_path))["metrics"]
    hits = {}
    for name, m in metrics.items():
        if name.startswith("server_hits{server:"):
            server = name[len("server_hits{server:"):-1]
            if m.get("count", 0) > 0:
                hits[server] = m["count"]
    total = sum(hits.values())
    if total == 0:
        print("  (서버별 집계 없음)")
        return
    print(" 서버별 처리 건수 (부하 분산 확인)")
    for server in sorted(hits):
        pct = hits[server] / total * 100
        label = "none(실패)" if server == "none" else server
        print(f"   {label:<16} {hits[server]:>8,}건  {pct:5.1f}%  {'█' * round(pct / 2)}")


def failover(csv_path, events_path, out_path):
    ev = json.load(open(events_path))
    stop, detect = ev["stopped_ms"], ev.get("detected_ms")
    start, recovered = ev.get("started_ms"), ev.get("recovered_ms")

    total = 0
    fails = []  # 실패한 요청의 시각(ms)
    with gzip.open(csv_path, "rt") as f:
        for row in csv.DictReader(f):
            if row["metric_name"] != "http_req_failed":
                continue
            total += 1
            if float(row["metric_value"]) >= 1:
                fails.append(int(row["timestamp"]))

    def sec(a, b):
        return None if a is None or b is None else round((b - a) / 1000, 1)

    result = {
        "target": ev["target"],
        "total_requests": total,
        "failed_requests": len(fails),
        "failed_rate_percent": round(len(fails) / total * 100, 3) if total else 0,
        "detect_seconds": sec(stop, detect),          # 서버 멈춤 → ALB가 비정상으로 판정
        "first_fail_after_stop_seconds": sec(stop, fails[0]) if fails else None,
        "last_fail_after_stop_seconds": sec(stop, fails[-1]) if fails else None,
        "recover_seconds": sec(start, recovered),     # 서버 다시 켬 → ALB가 정상으로 판정
        # 서버 멈춤 → 사람에게 알람 (CloudWatch는 1분 단위 지표로 판단해서 ALB보다 늦다)
        "alarm_seconds": {name: sec(stop, t) for name, t in sorted(ev.get("alarms", {}).items(), key=lambda x: x[1])},
    }
    json.dump(result, open(out_path, "w"), ensure_ascii=False, indent=2)

    print(" ── 장애 테스트 결과 ──────────────────────")
    print(f"   멈춘 서버:            {ev['target_name']} ({ev['target']})")
    print(f"   전체 요청:            {total:,}건")
    print(f"   실패한 요청:          {len(fails):,}건 ({result['failed_rate_percent']}%)")
    print(f"   ALB가 알아챈 시간:    서버를 멈추고 {result['detect_seconds']}초 뒤 (요청 보내기 중단)")
    if result["alarm_seconds"]:
        for name, s in result["alarm_seconds"].items():
            print(f"   사람에게 알람:        서버를 멈추고 {s}초 뒤 ({name.replace('approval-loadtest-', '')})")
    else:
        print("   사람에게 알람:        측정 시간 안에 울리지 않음")
    if fails:
        print(f"   실패가 난 구간:       멈춘 뒤 {result['first_fail_after_stop_seconds']}초 ~ "
              f"{result['last_fail_after_stop_seconds']}초")
    if result["recover_seconds"] is not None:
        print(f"   복구(다시 정상 판정): 서버를 켜고 {result['recover_seconds']}초 뒤")

    # 5초 단위 실패 건수 그래프 (멈춘 시각 기준)
    if fails:
        print("\n   5초 단위 실패 건수 (0초 = 서버를 멈춘 순간)")
        buckets = {}
        for t in fails:
            b = int((t - stop) // 5000) * 5
            buckets[b] = buckets.get(b, 0) + 1
        peak = max(buckets.values())
        for b in range(min(buckets), max(buckets) + 5, 5):
            n = buckets.get(b, 0)
            bar = "█" * max(1 if n else 0, round(n / peak * 40))
            mark = " ← ALB가 알아챔" if detect and b <= (detect - stop) / 1000 < b + 5 else ""
            print(f"   {b:>4}~{b + 5:<4}초 {n:>6}건 {bar}{mark}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "split" and len(sys.argv) == 3:
        split(sys.argv[2])
    elif cmd == "failover" and len(sys.argv) == 5:
        failover(*sys.argv[2:])
    else:
        print(__doc__)
        sys.exit(1)
