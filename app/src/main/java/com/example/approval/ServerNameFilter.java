package com.example.approval;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;
import org.springframework.web.filter.OncePerRequestFilter;

import java.io.IOException;

/**
 * 모든 응답에 "어느 서버가 처리했는지"를 헤더로 붙인다.
 * 부하 테스트에서 ALB가 요청을 서버들에 고르게 나눠 주는지(부하 분산) 세기 위해 사용한다.
 */
@Component
public class ServerNameFilter extends OncePerRequestFilter {

    private final String serverName;

    public ServerNameFilter(@Value("${SERVER_NAME:local}") String serverName) {
        this.serverName = serverName;
    }

    @Override
    protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response,
                                    FilterChain chain) throws ServletException, IOException {
        response.setHeader("X-Server-Name", serverName);
        chain.doFilter(request, response);
    }
}
