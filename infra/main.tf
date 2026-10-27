# ─────────────────────────────────────────────
# 네트워크: 기본 VPC의 서브넷 2개 사용
# ─────────────────────────────────────────────
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
  filter {
    name   = "availability-zone"
    values = var.azs
  }
}

locals {
  subnet_ids = sort(data.aws_subnets.selected.ids)
  my_cidr    = "${var.my_ip}/32"
}

# 최신 Amazon Linux 2023 AMI
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "random_id" "suffix" {
  byte_length = 3
}

# ─────────────────────────────────────────────
# 보안 그룹: 각 계층은 바로 앞 계층만 허용
#   내 PC, 부하 발생기 → ALB(80) → 앱(8080) → RDS(3306)
# ─────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "approval-alb-sg"
  description = "ALB: HTTP from my IP and the load generator"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "app" {
  name        = "approval-app-sg"
  description = "App: 8080 from ALB only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "db" {
  name        = "approval-db-sg"
  description = "RDS: 3306 from app and load generator (for seeding)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_security_group" "loadgen" {
  name        = "approval-loadgen-sg"
  description = "Load generator: k6 web dashboard from my IP"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_me" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = local.my_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

# 인터넷용 ALB는 공인 IP로 접속되므로, 보안 그룹 참조가 아니라 부하 발생기의 공인 IP를 허용해야 한다
resource "aws_vpc_security_group_ingress_rule" "alb_from_loadgen" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "${aws_instance.loadgen.public_ip}/32"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "db_from_loadgen" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.loadgen.id
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
}

resource "aws_vpc_security_group_ingress_rule" "k6_dashboard_from_me" {
  security_group_id = aws_security_group.loadgen.id
  cidr_ipv4         = local.my_cidr
  ip_protocol       = "tcp"
  from_port         = 5665
  to_port           = 5665
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  for_each = {
    alb     = aws_security_group.alb.id
    app     = aws_security_group.app.id
    db      = aws_security_group.db.id
    loadgen = aws_security_group.loadgen.id
  }
  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# ─────────────────────────────────────────────
# S3: 앱 jar와 부하 테스트 스크립트 배포, k6 리포트 보관
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "artifacts" {
  bucket        = "approval-loadtest-${random_id.suffix.hex}"
  force_destroy = true # destroy 할 때 리포트까지 함께 삭제
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "jar" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "app/approval-app.jar"
  source = var.jar_path
  etag   = filemd5(var.jar_path)
}

locals {
  loadtest_dir   = "${path.module}/../loadtest"
  loadtest_files = fileset(local.loadtest_dir, "*")
  loadtest_md5   = md5(join(",", [for f in sort(tolist(local.loadtest_files)) : filemd5("${local.loadtest_dir}/${f}")]))
}

resource "aws_s3_object" "loadtest" {
  for_each = local.loadtest_files
  bucket   = aws_s3_bucket.artifacts.id
  key      = "loadtest/${each.value}"
  source   = "${local.loadtest_dir}/${each.value}"
  etag     = filemd5("${local.loadtest_dir}/${each.value}")
}

# ─────────────────────────────────────────────
# IAM: 역할마다 필요한 권한만 (최소 권한)
#   앱 서버:     jar 받기, CloudWatch 지표, 브라우저 접속(Session Manager)
#   부하 발생기: 스크립트 받기, 리포트 올리기, 장애 테스트(앱 서버 1대 멈추기, 헬스체크 상태 보기)
# ─────────────────────────────────────────────
locals {
  ec2_assume_role = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  managed_policies = {
    ssm        = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    cloudwatch = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  }
}

# ── 앱 서버 ──
resource "aws_iam_role" "ec2" {
  name               = "approval-app-${random_id.suffix.hex}"
  assume_role_policy = local.ec2_assume_role
}

resource "aws_iam_role_policy_attachment" "app" {
  for_each   = local.managed_policies
  role       = aws_iam_role.ec2.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "s3" {
  name = "read-jar"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = "${aws_s3_bucket.artifacts.arn}/app/*"
    }]
  })
}

resource "aws_iam_instance_profile" "ec2" {
  name = "approval-app-${random_id.suffix.hex}"
  role = aws_iam_role.ec2.name
}

# ── 부하 발생기 ──
resource "aws_iam_role" "loadgen" {
  name               = "approval-loadgen-${random_id.suffix.hex}"
  assume_role_policy = local.ec2_assume_role
}

resource "aws_iam_role_policy_attachment" "loadgen" {
  for_each   = local.managed_policies
  role       = aws_iam_role.loadgen.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "loadgen" {
  name = "loadtest"
  role = aws_iam_role.loadgen.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.artifacts.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/loadtest/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.artifacts.arn}/reports/*"
      },
      {
        # 장애 테스트: 이 실습의 앱 서버에만 명령을 보낼 수 있다
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = concat(
          ["arn:aws:ssm:${var.region}::document/AWS-RunShellScript"],
          aws_instance.app[*].arn
        )
      },
      {
        # 아래 API들은 특정 리소스로 범위를 좁힐 수 없다 (모두 조회 전용)
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "elasticloadbalancing:DescribeTargetHealth", "ec2:DescribeInstances", "cloudwatch:DescribeAlarms"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "loadgen" {
  name = "approval-loadgen-${random_id.suffix.hex}"
  role = aws_iam_role.loadgen.name
}
