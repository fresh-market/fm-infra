// 선착순 쿠폰 발급 부하 시험.
//
// 요구사항이 정한 것은 셋이다 (backend/docs/coupon/requirement.md).
//
//   재고 10,000장에 20,000명이 동시에 요청해도 초과 발급 0건, 1인 최대 1매
//   ramp-up 60s
//   도구와 처리량은 평가하지 않는다
//
// 마지막 줄이 이 스크립트의 성격을 정한다. 재는 것은 성능이 아니라 정확성이다.
// p99 와 처리량은 기록하되 합격 판정에 쓰지 않는다.

import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Counter, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';
const RAMP = __ENV.RAMP_SECONDS || '60';
const HOLD = __ENV.HOLD_SECONDS || '30';

/*
 * vus   동시 사용자 수를 RAMP 초에 걸쳐 USERS 까지 올린다. 요구사항의 ramp-up 해석이다.
 * rate  도착률만 맞춘다. 서버가 받는 부하는 같고 생성기 메모리를 훨씬 덜 쓴다.
 *
 * 서버 입장에서 둘이 구분되지 않는다. 요청을 다 보낸 VU 는 살아 있어도 아무것도 안 보낸다.
 * 차이는 시연 화면에 20000/20000 VUs 가 찍히느냐이고, 그 대가로 메모리를 약 7 GB 더 쓴다.
 */
const MODE = __ENV.MODE || 'vus';
const USERS = Number(__ENV.USERS || 20000);
const MEASURE = __ENV.MEASURE === '1';

// 평상시 경로에 흘리는 배경 부하. 기본은 끔.
//
// 첫 시험의 질문은 초과 발급 0건 하나다. 변수를 하나만 둔다.
// 격벽 검증은 그것이 통과한 뒤에 BROWSE_RPS 를 주어 따로 본다.
const BROWSE_RPS = Number(__ENV.BROWSE_RPS || 0);

/*
 * SharedArray 가 아니면 VU 마다 배열 전체가 복제된다.
 * 토큰 2만 개면 VU 당 16 MB 라 어떤 인스턴스로도 감당하지 못한다.
 */
const tokens = new SharedArray('tokens', () => JSON.parse(open('./tokens.json')));

function buildScenario() {
  if (MEASURE) {
    // VU 당 메모리를 재는 모드. 도착률 실행기로는 VU 수를 고정할 수 없다.
    return {
      executor: 'constant-vus',
      vus: Number(__ENV.MEASURE_VUS || 100),
      duration: __ENV.MEASURE_DURATION || '30s',
      exec: 'issue',
    };
  }

  if (MODE === 'rate') {
    /*
     * 60초 동안 정확히 USERS 건을 균등하게 보낸다.
     * rate 와 timeUnit 을 이렇게 주면 적분이 딱 떨어져 토큰이 남거나 모자라지 않는다.
     */
    return {
      executor: 'constant-arrival-rate',
      rate: USERS,
      timeUnit: `${RAMP}s`,
      duration: `${RAMP}s`,
      preAllocatedVUs: Number(__ENV.PRE_VUS || 500),
      maxVUs: Number(__ENV.MAX_VUS || 2000),
      exec: 'issue',
    };
  }

  /*
   * 동시 사용자 수를 USERS 까지 올린다. 요구사항의 ramp-up 을 이렇게 읽은 것이다.
   *
   * VU 는 태어나자마자 한 번 쏘고 그 뒤로는 논다. 1인 1매라 또 보내면 alreadyIssued 다.
   * 도착 시각이 VU 시작 시각과 같고 VU 가 균등하게 태어나므로 도착률도 균등하다.
   * 서버가 받는 부하는 rate 모드와 구분되지 않는다. 차이는 생성기 메모리뿐이다.
   *
   * ramp 뒤에 hold 를 둔다. 마지막 VU 가 60초에 태어나 그 응답을 받을 시간이 필요하고,
   * 시연에서 20000/20000 이 찍히는 구간이기도 하다.
   */
  return {
    executor: 'ramping-vus',
    startVUs: 0,
    stages: [
      { duration: `${RAMP}s`, target: USERS },
      { duration: `${HOLD}s`, target: USERS },
    ],
    gracefulRampDown: '0s',
    exec: 'issue',
  };
}

const issueScenario = buildScenario();

const scenarios = { coupon_issue: issueScenario };

if (!MEASURE && BROWSE_RPS > 0) {
  /*
   * 격벽 검증이다 (coupon.md 8장).
   * 선착순이 몰리는 동안 상품 조회가 멀쩡해야 전용 ASG 를 나눈 값을 한 것이다.
   * 램프보다 먼저 시작해 기준선을 잡고, 끝난 뒤까지 남아 회복을 본다.
   */
  scenarios.browse_baseline = {
    executor: 'constant-arrival-rate',
    rate: BROWSE_RPS,
    timeUnit: '1s',
    duration: `${Number(RAMP) + 40}s`,
    preAllocatedVUs: 20,
    maxVUs: 100,
    exec: 'browse',
  };
}

const issued = new Counter('coupon_issued');
const already = new Counter('coupon_already_issued');
const soldout = new Counter('coupon_soldout');
const congested = new Counter('coupon_congested');
const notIssuable = new Counter('coupon_not_issuable');
const rateLimited = new Counter('coupon_rate_limited');
const unexpected = new Counter('coupon_unexpected');
const connError = new Counter('coupon_conn_error');
const tokenExhausted = new Counter('coupon_token_exhausted');

const issueLatency = new Trend('coupon_issue_latency', true);
const browseLatency = new Trend('browse_latency', true);

export const options = {
  scenarios,
  /*
   * 합격 판정은 정확성만 본다. 처리량은 평가 대상이 아니다.
   *
   * already 가 0 이어야 하는 것은 토큰을 iterationInTest 로 고유하게 나누기 때문이다.
   * 한 건이라도 나오면 재요청이 아니라 토큰 배분이 깨진 것이다.
   */
  thresholds: MEASURE
    ? {}
    : {
        coupon_issued: ['count<=10000'],
        coupon_already_issued: ['count==0'],
        coupon_soldout: ['count>0'],
        coupon_unexpected: ['count==0'],
        coupon_conn_error: ['count==0'],
        coupon_token_exhausted: ['count==0'],
      },
};

/*
 * VU 마다 따로 갖는 상태다. k6 는 VU 마다 JS 컨텍스트를 두므로 모듈 변수가 VU 로컬이 된다.
 * vus 모드에서 이것이 1인 1매를 지킨다.
 */
let fired = false;

const VUS_MODE = MODE === 'vus' && !MEASURE;

export function issue() {
  if (VUS_MODE) {
    if (fired) {
      // 이미 쏜 사용자다. 살아만 있고 아무것도 보내지 않는다.
      sleep(1);
      return;
    }
    fired = true;
  }

  /*
   * 토큰을 무엇으로 나누는지가 모드마다 다르다.
   *
   * vus   VU 하나가 사용자 하나다. idInTest 가 1부터 고유하게 붙는다.
   * rate  VU 를 재활용하므로 VU 번호로는 안 되고 반복 번호를 쓴다.
   *       같은 토큰이 두 번 쓰이면 발급이 아니라 재요청을 측정하게 된다.
   */
  const i = VUS_MODE ? exec.vu.idInTest - 1 : exec.scenario.iterationInTest;
  if (i >= tokens.length) {
    tokenExhausted.add(1);
    return;
  }

  const res = http.post(
    `${BASE}/v1/coupons/${COUPON_ID}/issues`,
    null,
    {
      headers: { Authorization: `Bearer ${tokens[i]}` },
      tags: { path: 'coupon_issue' },
    },
  );

  issueLatency.add(res.timings.duration);

  // 200 이 두 갈래다. 뭉치면 첫 발급과 재요청이 같은 통계가 된다 (coupon.md 8장).
  if (res.status === 200) {
    let body = null;
    try {
      body = res.json();
    } catch (e) {
      unexpected.add(1);
      return;
    }
    if (body && body.alreadyIssued === true) {
      already.add(1);
    } else {
      issued.add(1);
    }
    return;
  }

  /*
   * status 0 은 HTTP 응답이 아니다. 연결이 끊겼거나 맺지 못한 것이다.
   *
   * 예상 밖 응답 코드와 뭉치면 진단이 어긋난다. 전자는 앱이 이상한 답을 준 것이고
   * 후자는 요청이 앱까지 닿지도 못한 것이라 볼 곳이 다르다.
   * ALB 연결 한도, 생성기의 포트 고갈, 서버 accept 큐가 후자의 후보다.
   */
  if (res.status === 0) {
    connError.add(1);
    return;
  }

  // 소진만 최종이고 나머지 실패는 다시 시도할 값이 있다. 그래서 나눠 센다.
  if (res.status === 409) soldout.add(1);
  else if (res.status === 503) congested.add(1);
  else if (res.status === 422) notIssuable.add(1);
  else if (res.status === 429) rateLimited.add(1);
  else unexpected.add(1);
}

export function browse() {
  const res = http.get(`${BASE}/v1/products`, { tags: { path: 'browse' } });
  browseLatency.add(res.timings.duration);
}

export function handleSummary(data) {
  const c = (n) => (data.metrics[n] ? data.metrics[n].values.count : 0);
  const total = c('coupon_issued') + c('coupon_already_issued') + c('coupon_soldout')
    + c('coupon_congested') + c('coupon_not_issuable') + c('coupon_rate_limited')
    + c('coupon_unexpected') + c('coupon_conn_error');

  const lines = [
    '',
    '=== 발급 결과 ===',
    `  발급          ${c('coupon_issued')}`,
    `  재요청        ${c('coupon_already_issued')}   (0 이어야 정상)`,
    `  소진 409      ${c('coupon_soldout')}`,
    `  혼잡 503      ${c('coupon_congested')}`,
    `  불가 422      ${c('coupon_not_issuable')}`,
    `  제한 429      ${c('coupon_rate_limited')}`,
    `  예상 밖       ${c('coupon_unexpected')}`,
    `  연결 실패     ${c('coupon_conn_error')}   (앱까지 닿지 못한 것)`,
    `  합계          ${total}`,
    '',
    '보낸 부하를 다 보냈는지는 dropped_iterations 를 본다.',
    '0 이 아니면 생성기가 못 따라간 것이라 서버 결과로 읽으면 안 된다.',
    '',
    '최종 검증은 DB 에서 한다. k6 는 자기가 보낸 요청만 센다.',
    '',
  ];

  return {
    stdout: lines.join('\n'),
    'summary.json': JSON.stringify(data, null, 2),
  };
}
