package com.servicetech2.verifier;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * verifier v1 최소 샘플 (JDK 8 + Spring Boot).
 *
 * 실제 배포 파이프라인(app_path/config_path/log_path 3경로 마운트 + 포트) 검증용.
 * - app_path 에는 이 JAR(verifier.jar)이 위치한다.
 * - config_path 는 SPRING_CONFIG_ADDITIONAL_LOCATION 환경변수로 지정해
 *   application.properties를 외부에서 주입받는다 (없으면 기본값 사용).
 * - log_path 는 LOGGING_FILE_PATH 환경변수로 지정한다.
 * - 포트는 SERVER_PORT 환경변수(Spring Boot 표준)로 지정한다.
 *
 * DB 연동은 이번 단계에서 보류 -- 기동 성공 여부와 에러 로그만 확인한다.
 */
@SpringBootApplication
@RestController
public class VerifierApplication {

    public static void main(String[] args) {
        SpringApplication.run(VerifierApplication.class, args);
    }

    @GetMapping("/health")
    public String health() {
        return "OK";
    }
}
