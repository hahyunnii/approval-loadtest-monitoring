# ─────────────────────────────────────────────
# RDS MySQL: 결재 문서 100만 건을 넣을 DB
# ─────────────────────────────────────────────
resource "random_password" "db" {
  length  = 20
  special = false # 셸 스크립트에서 따옴표 문제가 없도록
}

resource "aws_db_subnet_group" "db" {
  name       = "approval-db-subnets-${random_id.suffix.hex}"
  subnet_ids = local.subnet_ids
}

resource "aws_db_instance" "db" {
  identifier     = "approval-db-${random_id.suffix.hex}"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"

  db_name  = "office"
  username = "admin"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false # 인터넷에서 직접 접근 불가
  multi_az               = false

  backup_retention_period = 0    # 실습용: 백업 없이 빠르게 생성
  skip_final_snapshot     = true # destroy 할 때 스냅샷 없이 삭제
  deletion_protection     = false
  apply_immediately       = true # 사양 변경(수직 확장)을 바로 적용
}
