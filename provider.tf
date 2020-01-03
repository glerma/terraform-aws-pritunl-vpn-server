provider "aws" {
  region = var.region
  assume_role {
    role_arn     = "arn:aws:iam::${var.member_account}:role/MemberAccountAdminAccessRole"
    session_name = "terraform"
  }
}
