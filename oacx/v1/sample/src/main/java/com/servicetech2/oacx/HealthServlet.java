package com.servicetech2.oacx;

import java.io.IOException;
import javax.servlet.ServletException;
import javax.servlet.annotation.WebServlet;
import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;

/**
 * oacx v1 최소 샘플 (Tomcat 9, javax.servlet).
 *
 * 배포 파이프라인(app_path/config_path/log_path 3경로 마운트 + 포트) 검증용.
 * DB 연동은 이번 단계에서 보류 -- 기동 성공 여부와 에러 로그만 확인한다.
 */
@WebServlet("/health")
public class HealthServlet extends HttpServlet {
    @Override
    protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws ServletException, IOException {
        resp.setContentType("text/plain");
        resp.getWriter().write("OK");
    }
}
