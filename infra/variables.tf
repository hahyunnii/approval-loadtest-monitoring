variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "azs" {
  description = "사용할 가용 영역 2개 (ALB와 RDS는 2개 이상 필요)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "my_ip" {
  description = "내 PC의 공인 IP (예: 211.234.5.6). k6 웹 대시보드와 ALB 접속을 이 IP에만 허용"
  type        = string

  validation {
    condition     = can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}$", var.my_ip))
    error_message = "my_ip는 211.234.5.6 처럼 IP 주소만 적어주세요 (/32 없이)."
  }
}

variable "app_count" {
  description = "앱 서버(EC2) 개수. 수평 확장할 때 1 → 2로 바꾸고 apply"
  type        = number
  default     = 1
}

variable "app_instance_type" {
  description = "앱 서버 사양"
  type        = string
  default     = "t3.small"
}

variable "db_instance_class" {
  description = "RDS 사양. DB를 수직 확장할 때 db.t3.micro → db.t3.small 등으로 바꾸고 apply"
  type        = string
  default     = "db.t3.micro"
}

variable "loadgen_instance_type" {
  description = "부하 발생기(k6) 사양. 앱 서버와 분리해야 측정 결과를 믿을 수 있다"
  type        = string
  default     = "t3.medium"
}

variable "alarm_email" {
  description = "알람을 받을 메일 주소 (비워 두면 메일 없이 콘솔·대시보드에서만 확인)"
  type        = string
  default     = ""
}

variable "jar_path" {
  description = "빌드한 앱 jar 경로 (README의 빌드 단계 참고)"
  type        = string
  default     = "../app/target/approval-app.jar"
}
