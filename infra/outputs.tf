output "alb_url" {
  description = "결재함 API 주소 (내 PC에서 접속 확인용)"
  value       = "http://${aws_lb.app.dns_name}/health"
}

output "cloudwatch_dashboard" {
  description = "CloudWatch 대시보드"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards/dashboard/${aws_cloudwatch_dashboard.loadtest.dashboard_name}"
}

output "k6_web_dashboard" {
  description = "k6 웹 대시보드 (부하 테스트가 실행 중일 때만 열림)"
  value       = "http://${aws_instance.loadgen.public_ip}:5665"
}

output "cloudwatch_alarms" {
  description = "알람 목록 (P1 긴급 · P2 경고 · P3 참고)"
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#alarmsV2:?search=approval-loadtest"
}

output "loadgen_connect" {
  description = "부하 발생기 접속: EC2 콘솔 → 이 인스턴스 선택 → 연결 → Session Manager → 연결"
  value       = "https://${var.region}.console.aws.amazon.com/ec2/home?region=${var.region}#ConnectToInstance:instanceId=${aws_instance.loadgen.id}"
}

output "app_instance_ids" {
  description = "앱 서버 인스턴스 ID (로그 확인용)"
  value       = aws_instance.app[*].id
}

output "download_reports" {
  description = "k6 리포트를 내 PC로 받는 명령"
  value       = "aws s3 sync s3://${aws_s3_bucket.artifacts.id}/reports ./reports"
}
