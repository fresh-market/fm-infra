#!/bin/sh
# 이 스크립트는 SonarQube가 구동된 후 자동으로 비밀번호를 변경하고 초기 설정을 세팅합니다.

echo "Waiting for SonarQube to start..."

# 1. SonarQube 서버가 완전히 켜질 때까지 대기
while true; do
  STATUS=$(curl -s -u admin:admin http://sonarqube:9000/api/system/status | grep '"status":"UP"')
  if [ -n "$STATUS" ]; then
    echo "SonarQube is UP and running!"
    break
  fi
  echo "Still waiting for SonarQube..."
  sleep 5
done

echo "Starting Provisioning..."

# 🎯 팀 공통으로 사용할 새로운 관리자 비밀번호 (원하는 것으로 변경하세요)
NEW_PASSWORD="admin123"

# 2. 초기 비밀번호(admin)를 자동 변경 (웹 UI 접속 불필요)
echo "1. Changing default admin password..."
curl -s -X POST -u admin:admin \
  "http://sonarqube:9000/api/users/change_password?login=admin&previousPassword=admin&password=${NEW_PASSWORD}"
# (참고: 이미 변경된 상태에서 컨테이너가 재시작되면 이 단계는 에러를 내지만 스크립트는 멈추지 않고 다음으로 넘어갑니다.)

# 3. 프로젝트 자동 생성 (이제부터는 변경된 ${NEW_PASSWORD}를 사용합니다!)
echo "2. Creating project 'fresh-market'..."
curl -s -X POST -u admin:${NEW_PASSWORD} \
  "http://sonarqube:9000/api/projects/create?project=fresh-market&name=fresh-market"

# 4. 멱등성 보장: 기존 토큰이 있다면 삭제 후 새로 발급
echo "3-1. Revoking existing token if any..."
curl -s -X POST -u admin:${NEW_PASSWORD} \
  "http://sonarqube:9000/api/user_tokens/revoke?login=admin&name=market-ci-token"

echo "3-2. Generating fresh token for CI/CD..."
RESPONSE=$(curl -s -X POST -u admin:${NEW_PASSWORD} \
  "http://sonarqube:9000/api/user_tokens/generate?login=admin&name=market-ci-token")

# JSON 응답에서 token 값 추출
TOKEN=$(echo "$RESPONSE" | grep -o '"token":"[^"]*"' | cut -d'"' -f4)

# 5. 파일로 저장
if [ -n "$TOKEN" ]; then
  TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
  FILE_PATH="/sonarqube/sonar_token_${TIMESTAMP}.txt"

  echo "SonarQube CI/CD Token" > "$FILE_PATH"
  echo "Created At: $(date)" >> "$FILE_PATH"
  echo "---------------------------" >> "$FILE_PATH"
  echo "$TOKEN" >> "$FILE_PATH"

  echo "✅ Token successfully saved to $FILE_PATH"
else
  echo "❌ Failed to generate token. API Response: $RESPONSE"
fi

echo "Provisioning Completed!"
