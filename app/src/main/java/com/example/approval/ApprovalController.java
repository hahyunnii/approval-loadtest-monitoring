package com.example.approval;

import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Map;

/**
 * 업무시스템 결재함 API (부하 테스트용).
 *
 * - 직원 1만 명(approver_id 1~10000), 결재 문서 100만 건을 가정한다.
 * - "내 결재함" 조회 = 나에게 온 결재 문서 중 최신 20건.
 *   인덱스가 없으면 MySQL이 100만 건을 전부 읽고 정렬해야 해서 DB CPU가 병목이 된다.
 *   (approver_id, created_at) 인덱스를 만들면 필요한 20건만 바로 찾는다.
 */
@RestController
public class ApprovalController {

    private final JdbcTemplate jdbc;

    public ApprovalController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** ALB 헬스체크용. DB를 거치지 않는다 (DB가 느려도 서버가 살아 있는지 따로 판단하기 위해). */
    @GetMapping("/health")
    public String health() {
        return "ok";
    }

    /** 내 결재함: 나에게 온 결재 문서 최신 20건 (전체 요청의 95%) */
    @GetMapping("/api/approvals/inbox")
    public List<Map<String, Object>> inbox(@RequestParam int approverId) {
        return jdbc.queryForList(
                "SELECT id, drafter_id, title, status, created_at " +
                "FROM approval_docs WHERE approver_id = ? " +
                "ORDER BY created_at DESC LIMIT 20",
                approverId);
    }

    public record SubmitRequest(int drafterId, int approverId, String title) {}

    /** 결재 상신: 새 결재 문서 등록 (전체 요청의 5%) */
    @PostMapping("/api/approvals")
    public ResponseEntity<Map<String, String>> submit(@RequestBody SubmitRequest req) {
        jdbc.update(
                "INSERT INTO approval_docs (drafter_id, approver_id, title, status, created_at) " +
                "VALUES (?, ?, ?, '대기', ?)",
                req.drafterId(), req.approverId(), req.title(), LocalDateTime.now());
        return ResponseEntity.status(201).body(Map.of("result", "submitted"));
    }
}
