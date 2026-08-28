// 메모리 측정용 더미 토큰을 만든다. 실제 요청에는 쓸 수 없다.
//
// 파일을 커밋하지 않고 스크립트만 두는 이유는 크기다.
// 2만 개면 5 MB 라 저장소에 둘 것이 아니고, 어차피 재현 가능한 값이다.
//
//   node gen-dummy-tokens.js 20000 > tokens.json
//
// 실제 시험용 토큰은 앱의 서명 키로 만들어야 한다. 백엔드 쪽 스크립트가 맡는다.
// 길이를 실제 JWT 와 비슷하게 맞춘다. 그래야 메모리 측정이 유효하다.

const n = Number(process.argv[2] || 20000);
const head = 'eyJhbGciOiJIUzI1NiIsImtpZCI6ImR1bW15In0.';
const sig = 'y'.repeat(43);

const tokens = [];
for (let i = 0; i < n; i++) {
  tokens.push(head + String(i).padStart(6, '0').padEnd(180, 'x') + '.' + sig);
}
process.stdout.write(JSON.stringify(tokens));
