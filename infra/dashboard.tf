# ─────────────────────────────────────────────
# CloudWatch 대시보드: 계층별 지표를 한 화면에서
#   병목 찾기 = "어느 칸이 100%에 붙어 있나" 보기
# ─────────────────────────────────────────────
locals {
  lb  = aws_lb.app.arn_suffix
  tg  = aws_lb_target_group.app.arn_suffix
  rds = aws_db_instance.db.identifier

  app_cpu = [for i, inst in aws_instance.app :
    ["AWS/EC2", "CPUUtilization", "InstanceId", inst.id, { label = "app-${i + 1}" }]
  ]
  app_mem = [for i, inst in aws_instance.app :
    ["CWAgent", "mem_used_percent", "InstanceId", inst.id, { label = "app-${i + 1}" }]
  ]

  percent_axis = { left = { min = 0, max = 100 } }

  alarm_arns = [
    aws_cloudwatch_metric_alarm.unhealthy_host.arn,
    aws_cloudwatch_metric_alarm.errors_5xx.arn,
    aws_cloudwatch_metric_alarm.p99_slo.arn,
    aws_cloudwatch_metric_alarm.rds_cpu.arn,
  ]

  widgets = [
    {
      title   = "① 트래픽: ALB 요청 수 (1분 합계)"
      stat    = "Sum"
      metrics = [["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.lb, { label = "요청 수/분" }]]
    },
    {
      title = "② 응답시간: p50 · p99 (점선 = SLO 0.5초)"
      metrics = [
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p50", label = "p50" }],
        ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.lb, { stat = "p99", label = "p99" }]
      ]
      annotations = { horizontal = [{ value = 0.5, label = "SLO 0.5초", color = "#d62728" }] }
    },
    {
      title = "③ 에러: 5xx 개수 (1분 합계)"
      stat  = "Sum"
      metrics = [
        ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", local.lb, { label = "앱 서버 5xx" }],
        ["AWS/ApplicationELB", "HTTPCode_ELB_5XX_Count", "LoadBalancer", local.lb, { label = "ALB 5xx" }]
      ]
    },
    {
      title = "④ 정상 · 비정상 서버 수 (헬스체크)"
      stat  = "Minimum"
      metrics = [
        ["AWS/ApplicationELB", "HealthyHostCount", "TargetGroup", local.tg, "LoadBalancer", local.lb, { label = "정상 서버" }],
        ["AWS/ApplicationELB", "UnHealthyHostCount", "TargetGroup", local.tg, "LoadBalancer", local.lb, { stat = "Maximum", label = "비정상 서버", color = "#d62728" }]
      ]
    },
    {
      title   = "⑤ 앱 서버 CPU 사용률 (%)"
      metrics = local.app_cpu
      yAxis   = local.percent_axis
    },
    {
      title   = "⑥ 앱 서버 메모리 사용률 (%)"
      metrics = local.app_mem
      yAxis   = local.percent_axis
    },
    {
      title   = "⑦ RDS CPU 사용률 (%)"
      metrics = [["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.rds, { label = "RDS" }]]
      yAxis   = local.percent_axis
    },
    {
      title   = "⑧ RDS 연결 수"
      metrics = [["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", local.rds, { label = "연결 수" }]]
    },
    {
      title   = "⑨ 부하 발생기 CPU (%) — 이게 100%면 측정 자체가 한계"
      metrics = [["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.loadgen.id, { label = "k6" }]]
      yAxis   = local.percent_axis
    },
    {
      title   = "⑩ RDS 여유 메모리 (bytes)"
      metrics = [["AWS/RDS", "FreeableMemory", "DBInstanceIdentifier", local.rds, { label = "여유 메모리" }]]
    }
  ]
}

resource "aws_cloudwatch_dashboard" "loadtest" {
  dashboard_name = "approval-loadtest"

  dashboard_body = jsonencode({
    widgets = concat([{
      # 맨 위: 알람 상태 (빨간색이면 지금 문제가 있다)
      type   = "alarm"
      x      = 0
      y      = 0
      width  = 24
      height = 3
      properties = {
        title  = "⓪ 알람 상태 (P1 긴급 · P2 경고 · P3 참고)"
        alarms = local.alarm_arns
      }
      }], [for i, w in local.widgets : {
      type   = "metric"
      x      = (i % 2) * 12
      y      = 3 + floor(i / 2) * 6
      width  = 12
      height = 6
      properties = merge(
        {
          title   = w.title
          region  = var.region
          view    = "timeSeries"
          stacked = false
          period  = 60
          stat    = lookup(w, "stat", "Average")
          metrics = w.metrics
        },
        contains(keys(w), "annotations") ? { annotations = w.annotations } : {},
        contains(keys(w), "yAxis") ? { yAxis = w.yAxis } : {}
      )
    }])
  })
}
