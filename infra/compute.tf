# ─────────────────────────────────────────────
# 앱 서버 (Spring Boot): app_count 만큼 생성 → 수평 확장
# ─────────────────────────────────────────────
resource "aws_instance" "app" {
  count = var.app_count

  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.app_instance_type
  subnet_id              = element(local.subnet_ids, count.index)
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name
  monitoring             = true # 세부 모니터링: 지표를 5분이 아니라 1분 간격으로

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/templates/app-user-data.sh.tftpl", {
    region      = var.region
    bucket      = aws_s3_bucket.artifacts.id
    jar_key     = aws_s3_object.jar.key
    jar_md5     = filemd5(var.jar_path)
    db_url      = "jdbc:mysql://${aws_db_instance.db.address}:3306/${aws_db_instance.db.db_name}"
    db_user     = aws_db_instance.db.username
    db_password = random_password.db.result
    server_name = "app-${count.index + 1}" # 응답 헤더 X-Server-Name (부하 분산 확인용)
  })
  user_data_replace_on_change = true # jar가 바뀌면 서버를 새로 만들어 반영

  tags = {
    Name = "approval-app-${count.index + 1}"
  }

  depends_on = [aws_iam_role_policy.s3]
}

# ─────────────────────────────────────────────
# 부하 발생기 (k6): 앱 서버와 다른 컴퓨터에서 부하를 줘야 측정을 믿을 수 있다
# ─────────────────────────────────────────────
resource "aws_instance" "loadgen" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.loadgen_instance_type
  subnet_id              = element(local.subnet_ids, 0)
  vpc_security_group_ids = [aws_security_group.loadgen.id]
  iam_instance_profile   = aws_iam_instance_profile.loadgen.name
  monitoring             = true

  metadata_options {
    http_tokens = "required"
  }

  user_data = templatefile("${path.module}/templates/loadgen-user-data.sh.tftpl", {
    region      = var.region
    bucket      = aws_s3_bucket.artifacts.id
    scripts_md5 = local.loadtest_md5
    alb_dns     = aws_lb.app.dns_name
    db_host     = aws_db_instance.db.address
    db_name     = aws_db_instance.db.db_name
    db_user     = aws_db_instance.db.username
    db_password = random_password.db.result
    tg_arn      = aws_lb_target_group.app.arn
  })
  user_data_replace_on_change = true # 스크립트가 바뀌면 부하 발생기를 새로 만들어 반영

  tags = {
    Name = "approval-loadgen"
  }

  depends_on = [aws_s3_object.loadtest, aws_iam_role_policy.loadgen]
}

# ─────────────────────────────────────────────
# ALB: 사용자 요청을 앱 서버들에 나눠 보냄
# ─────────────────────────────────────────────
resource "aws_lb" "app" {
  name               = "approval-alb-${random_id.suffix.hex}"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids
}

resource "aws_lb_target_group" "app" {
  name                 = "approval-tg-${random_id.suffix.hex}"
  port                 = 8080
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.default.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_target_group_attachment" "app" {
  count            = var.app_count
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.app[count.index].id
  port             = 8080
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
