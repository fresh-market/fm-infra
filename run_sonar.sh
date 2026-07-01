#!/bin/bash

echo "🔍 가장 최근에 생성된 SonarQube 토큰 파일을 찾는 중..."

TOKEN_FILE=$(ls -t ./sonarqube/sonar_token_*.txt 2>/dev/null | head -n 1)

if [ -z "$TOKEN_FILE" ]; then
    echo "❌ 토큰 파일을 찾을 수 없습니다."
    echo "먼저 'docker-compose up -d'를 실행하여 SonarQube와 setup 스크립트가 완료되길 기다려주세요."
    exit 1
fi

TOKEN=$(tail -n 1 "$TOKEN_FILE" | tr -d '\r\n' | xargs)

echo "✅ 토큰 추출 완료!"
echo "🚀 Spring Boot 테스트 및 SonarQube 정적 분석을 시작합니다..."

docker run --rm \
  -v "$(pwd)/fm-backend:/home/gradle/project" \
  -w /home/gradle/project \
  --network host \
  gradle:8-jdk21 \
  gradle clean test sonar \
    -Dsonar.host.url="http://localhost:9007" \
    -Dsonar.login="$TOKEN" \
    -Dsonar.projectKey="fresh-market"

echo "================================================="
echo "🎉 분석이 완료되었습니다!"
echo "👉 브라우저에서 http://localhost:9007 에 접속하여 결과를 확인하세요."
echo "================================================="
