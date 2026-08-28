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
import { Counter, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const BASE = __ENV.BASE_URL || 'http://localhost:8080';
const COUPON_ID = __ENV.COUPON_ID || '1';
const RAMP = __ENV.RAMP_SECONDS || '60';
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

/*
 * 0 에서 선형으로 올리면 60초 적분이 사용자 수가 되도록 최고 도착률을 정한다.
 *
 *   면적 = 0.5 * 60 * peak = 20000  ->  peak = 667
 *
 * JMeter 의 "스레드 2만 개를 60초에 걸쳐 시작" 과 같은 모양이다.
 * 1인 1매라 스레드 하나가 요청 하나를 보내므로 그것이 곧 이 램프다.
 */
const peakRate = Math.ceil((2 * USERS) / Number(RAMP));

const issueScenario = MEASURE
  ? {
      // VU 당 메모리를 재는 모드. 도착률 실행기로는 VU 수를 고정할 수 없다.
      executor: 'constant-vus',
      vus: Number(__ENV.MEASURE_VUS || 100),
      duration: __ENV.MEASURE_DURATION || '30s',
      exec: 'issue',
    }
  : {
      executor: 'ramping-arrival-rate',
      startRate: 0,
      timeUnit: '1s',
      stages: [{ duration: `${RAMP}s`, target: peakRate }],
      preAllocatedVUs: Number(__ENV.PRE_VUS || 500),
      maxVUs: Number(__ENV.MAX_VUS || 2000),
      exec: 'issue',
    };

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
        coupon_token_exhausted: ['count==0'],
      },
};

export function issue() {
  /*
   * 도착률 실행기는 VU 를 재활용하므로 __VU 나 __ITER 로는 고유해지지 않는다.
   * 같은 토큰이 두 번 쓰이면 두 번째는 alreadyIssued 가 되어,
   * 발급이 아니라 재요청을 측정하게 된다.
   */
  const i = exec.scenario.iterationInTest;
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
    + c('coupon_unexpected');

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
