// 업무시스템 결재함 부하 테스트 (약 9분 30초)
//
// - 직원 1만 명 중 무작위 1명이 "내 결재함"을 연다 (95%)
// - 5%는 새 결재 문서를 상신한다
// - 가상 사용자(VU)를 MAX_VUS의 10% → 50% → 100%로 늘려가며 최대 처리량을 찾는다
// - PDF 권장대로 5분 이상 돌려야 1분 단위 CloudWatch 지표가 안정적으로 쌓인다
// - 응답 헤더 X-Server-Name으로 "어느 서버가 처리했는지" 세어 부하 분산을 확인한다

import http from 'k6/http';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
const MAX_VUS = Number(__ENV.MAX_VUS || 200);
const THINK = Number(__ENV.THINK || 0.2); // 요청 사이 쉬는 시간(초)
const HEADERS = { headers: { 'Content-Type': 'application/json' }, tags: { name: 'submit' } };

// 서버별 처리 건수 (app-1, app-2, ... / 응답이 서버까지 못 간 경우 none)
export const serverHits = new Counter('server_hits');

// 서버별 건수가 요약(JSON)에 남도록 항상 통과하는 기준을 걸어 둔다 (SLO와 무관)
const perServer = {};
for (const s of ['app-1', 'app-2', 'app-3', 'app-4', 'none']) {
  perServer[`server_hits{server:${s}}`] = ['count>=0'];
}

export const options = {
  stages: [
    { duration: '2m', target: Math.round(MAX_VUS * 0.1) },
    { duration: '3m', target: Math.round(MAX_VUS * 0.5) },
    { duration: '3m', target: MAX_VUS },
    { duration: '1m', target: MAX_VUS },
    { duration: '30s', target: 0 },
  ],
  // SLO: 결재함 조회의 99%는 0.5초 안에, 실패는 1% 미만
  // 결과 화면에서 ✓(달성) / ✗(미달)로 표시된다
  thresholds: Object.assign({
    'http_req_duration{name:inbox}': ['p(99)<500'],
    http_req_failed: ['rate<0.01'],
  }, perServer),
};

function employee() {
  return 1 + Math.floor(Math.random() * 10000);
}

function countServer(res) {
  serverHits.add(1, { server: res.headers['X-Server-Name'] || 'none' });
}

export default function () {
  const me = employee();
  let res;
  if (Math.random() < 0.05) {
    const body = JSON.stringify({ drafterId: me, approverId: employee(), title: '출장 신청' });
    res = http.post(`${BASE_URL}/api/approvals`, body, HEADERS);
  } else {
    res = http.get(`${BASE_URL}/api/approvals/inbox?approverId=${me}`, { tags: { name: 'inbox' } });
  }
  countServer(res);
  sleep(THINK);
}
