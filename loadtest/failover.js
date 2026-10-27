// 장애 테스트용 부하 (fail-test.sh가 실행한다)
//
// - 일정한 부하(가상 사용자 VUS명)를 DURATION 동안 계속 준다
// - 그 사이에 fail-test.sh가 앱 서버 1대를 멈췄다가 다시 켠다
// - "ALB가 몇 초 만에 알아채고, 그동안 사용자 요청이 몇 건 실패했나"를 본다

import http from 'k6/http';
import { sleep } from 'k6';
import { Counter } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL;
const VUS = Number(__ENV.VUS || 60);
const DURATION = __ENV.DURATION || '5m';
const THINK = Number(__ENV.THINK || 0.2);

export const serverHits = new Counter('server_hits');

const perServer = {};
for (const s of ['app-1', 'app-2', 'app-3', 'app-4', 'none']) {
  perServer[`server_hits{server:${s}}`] = ['count>=0'];
}

export const options = {
  scenarios: {
    steady: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  },
  // 장애를 일부러 일으키므로 SLO 판정은 하지 않는다 (실패 건수는 따로 집계)
  thresholds: perServer,
};

export default function () {
  const me = 1 + Math.floor(Math.random() * 10000);
  const res = http.get(`${BASE_URL}/api/approvals/inbox?approverId=${me}`, { tags: { name: 'inbox' } });
  serverHits.add(1, { server: res.headers['X-Server-Name'] || 'none' });
  sleep(THINK);
}
