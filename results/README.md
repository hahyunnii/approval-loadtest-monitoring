# results

k6 테스트 결과 (2026-10-27 실습). 내 PC의 `approval-loadtest\reports` 폴더 내용을 이 폴더에 복사해 올립니다.

| 파일 | 내용 |
|---|---|
| 1-no-index.html | 1차: 인덱스 없음, 서버 1대, 최대 200명 |
| 2-index.html | 2차: 인덱스, 서버 1대, 최대 200명 |
| 2b-index-800vu.html | 2b: 인덱스, 서버 1대, 최대 800명 |
| 3-scale-out.html | 3차: 인덱스, 서버 3대, 최대 800명 |
| 4-failover.html | 장애 테스트: 서버 3대 중 1대 정지 |
| *-summary.json | k6 요약 (1차·2차·장애) |
| 4-failover-result.json | 탐지 시간·알람 시각·실패 건수 계산 결과 |
| 4-failover-events.json, 4-failover-alarms.log | 정지·탐지·재시작·복구·알람 시각(ms) |
| 4-failover-raw.csv.gz | 장애 테스트의 요청별 원본 기록 (실패 시각 계산용) |

HTML 파일은 내려받아 브라우저로 열면 그래프가 보입니다.
2b·3차는 k6가 종료 요약에서 멈춰 summary.json이 없습니다 (HTML 리포트의 Summary 표를 사용).
