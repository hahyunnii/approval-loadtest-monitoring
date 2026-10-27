# ─────────────────────────────────────────────
# CloudWatch 알람: 사람이 대시보드를 보고 있지 않아도 문제를 알려준다
#   등급을 나눠 "행동이 필요한 것만" 시끄럽게 알린다
#     P1 긴급: 사용자가 지금 실패를 겪고 있다 → 바로 대응
#     P2 경고: 목표(SLO)를 못 지키고 있다    → 업무 시간 안에 원인 분석
#     P3 참고: 여유가 줄고 있다              → 용량 계획 (출근 피크 전에 확장 검토)
# ─────────────────────────────────────────────

# 알람을 메일로 받고 싶으면 terraform.tfvars에 alarm_email = "내 메일" (구독 확인 메일의 링크를 눌러야 함)
resource "aws_sns_topic" "alarms" {
  count = var.alarm_email == "" ? 0 : 1
  name  = "approval-loadtest-alarms"
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms[0].arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alarm_actions = aws_sns_topic.alarms[*].arn
}

# P1 긴급: 헬스체크에 실패한 서버가 생김
resource "aws_cloudwatch_metric_alarm" "unhealthy_host" {
  alarm_name          = "approval-loadtest-P1-unhealthy-host"
  alarm_description   = "[P1 긴급] 헬스체크에 실패한 앱 서버가 있습니다. 남은 서버로 버티는지 확인하고 원인 서버를 교체하세요."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  dimensions          = { TargetGroup = aws_lb_target_group.app.arn_suffix, LoadBalancer = aws_lb.app.arn_suffix }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# P1 긴급: 사용자 요청이 에러로 끝남 (ALB 5xx + 앱 서버 5xx, 1분에 10건 초과)
resource "aws_cloudwatch_metric_alarm" "errors_5xx" {
  alarm_name          = "approval-loadtest-P1-5xx"
  alarm_description   = "[P1 긴급] 1분 동안 5xx 에러가 10건을 넘었습니다. 사용자가 결재함을 못 열고 있습니다."
  comparison_operator = "GreaterThanThreshold"
  threshold           = 10
  evaluation_periods  = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  metric_query {
    id          = "total"
    expression  = "FILL(elb, 0) + FILL(target, 0)"
    label       = "5xx 합계"
    return_data = true
  }
  metric_query {
    id = "elb"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_ELB_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.app.arn_suffix }
      stat        = "Sum"
      period      = 60
    }
  }
  metric_query {
    id = "target"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      dimensions  = { LoadBalancer = aws_lb.app.arn_suffix }
      stat        = "Sum"
      period      = 60
    }
  }
}

# P2 경고: 응답시간 p99가 SLO(0.5초)를 3분 연속 넘음 (잠깐 튄 것은 무시)
resource "aws_cloudwatch_metric_alarm" "p99_slo" {
  alarm_name          = "approval-loadtest-P2-p99-slo"
  alarm_description   = "[P2 경고] 결재함 응답시간 p99가 3분 연속 0.5초를 넘었습니다. 대시보드에서 100%에 붙은 칸(병목)을 찾으세요."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = aws_lb.app.arn_suffix }
  extended_statistic  = "p99"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0.5
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}

# P3 참고: DB CPU가 5분 연속 80% 초과 (아직 장애는 아니지만 여유가 없다)
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "approval-loadtest-P3-rds-cpu"
  alarm_description   = "[P3 참고] DB CPU가 5분 연속 80%를 넘었습니다. 슬로우 쿼리·인덱스를 먼저 보고, 그다음 캐시·Read Replica·사양 증설을 검토하세요."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = aws_db_instance.db.identifier }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  treat_missing_data  = "notBreaching"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions
}
