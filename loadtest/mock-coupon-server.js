// 스크립트 검증용 목 서버. 앱을 대신하지 않는다.
//
// 앱 없이 coupon-issue.js 를 끝까지 돌려 보려고 둔다.
// 토큰 배분, 응답 분류, 임계값 판정, 요약 출력이 맞는지 본다.
// 성능을 재는 용도가 아니다. 여기 응답 시간은 아무 의미가 없다.
//
//   node mock-coupon-server.js [포트] [재고]
//
// 규칙은 v4 스펙을 따른다 (coupon-v4.md).
//   처음 보는 토큰 + 재고 있음   200 { issueSeq, alreadyIssued: false }
//   이미 본 토큰                 200 { alreadyIssued: true }
//   재고 없음                    409

const http = require('http');

const PORT = Number(process.argv[2] || 18090);
const STOCK = Number(process.argv[3] || 10000);
const LATENCY_MS = Number(process.env.LATENCY_MS || 0);

let issued = 0;
const seen = new Set();
const stats = { issued: 0, already: 0, soldout: 0, unauth: 0 };

const server = http.createServer((req, res) => {
  if (!/^\/v1\/coupons\/[^/]+\/issues$/.test(req.url) || req.method !== 'POST') {
    res.writeHead(404).end();
    return;
  }

  const auth = req.headers.authorization || '';
  const token = auth.replace(/^Bearer /, '');

  const reply = () => {
    if (!token) {
      stats.unauth++;
      res.writeHead(401).end();
      return;
    }
    if (seen.has(token)) {
      stats.already++;
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ issueSeq: null, alreadyIssued: true }));
      return;
    }
    if (issued >= STOCK) {
      stats.soldout++;
      res.writeHead(409, { 'content-type': 'application/json' });
      res.end(JSON.stringify({ code: 'COUPON_SOLD_OUT' }));
      return;
    }
    seen.add(token);
    issued++;
    stats.issued++;
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ issueSeq: issued, alreadyIssued: false }));
  };

  if (LATENCY_MS > 0) setTimeout(reply, LATENCY_MS);
  else reply();
});

server.keepAliveTimeout = 65000;
server.listen(PORT, () => console.error(`mock listening ${PORT}, stock ${STOCK}`));

process.on('SIGTERM', () => {
  console.error(JSON.stringify(stats));
  process.exit(0);
});
